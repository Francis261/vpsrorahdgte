#!/usr/bin/env bash
# Restore host state from the configured storage backend: home + Docker + pm2.
# Exits 0 quietly when there is no backup yet (fresh start) or skip requested.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

storage_setup

if [ "${SKIP_RESTORE:-false}" = "true" ]; then
  log "skip restore requested; starting fresh"
  exit 0
fi

STAGE=/tmp/restore
rm -rf "$STAGE" && mkdir -p "$STAGE"

# Find + download + verify + reassemble the newest backup
log "looking for backup in storage (backend=$(storage_backend))..."
latest="$(storage_fetch_latest_backup "$STAGE")"
FETCH_RC=$?
if [ "$FETCH_RC" -ne 0 ]; then
  # A failed/corrupt fetch must NOT be mistaken for "no backup yet": starting
  # fresh here would let the next cycle overwrite a perfectly good backup.
  log "ERROR: backup fetch/verification failed (exit $FETCH_RC) — refusing to start fresh over a possibly-good backup"
  exit 1
fi
if [ -z "$latest" ]; then
  log "no backup found; starting fresh"
  exit 0
fi

if [ ! -f "$STAGE/$latest" ]; then
  log "ERROR: backup fetch failed (see logs above)"
  exit 1
fi

log "restoring backup: $latest"

ls -lh "$STAGE/$latest"

# Extract the outer tarball
log "extracting backup..."
tar -xzf "$STAGE/$latest" -C "$STAGE" || {
  log "ERROR: failed to extract backup tarball"
  exit 1
}

log "contents of extracted backup:"
ls -la "$STAGE/"

# ── 1. Root home directory (restore FIRST — Docker/PM2 may need these files)
ROOT_HOME="/root"
if [ -f "$STAGE/home/home.tar.gz" ]; then
  log "restoring home directory to $ROOT_HOME from $(du -h "$STAGE/home/home.tar.gz" | cut -f1) archive"
  sudo tar -xzf "$STAGE/home/home.tar.gz" -C "$ROOT_HOME" || {
    log "ERROR: home directory restore failed"
  }
  log "home directory restored to $ROOT_HOME"
else
  log "WARN: no home.tar.gz in backup"
fi

# ── 2. Docker images ────────────────────────────────────────────────
if [ "${SKIP_DOCKER:-false}" = "true" ]; then
  log "SKIP_DOCKER=true; skipping Docker restore"
else
  if [ -d "$STAGE/images" ] && [ "$(ls -A "$STAGE/images/" 2>/dev/null)" ]; then
    IMG_COUNT=0
    for img in "$STAGE"/images/*.tar.gz; do
      [ -f "$img" ] || continue
      log "loading image: $(basename "$img")"
      gunzip -c "$img" | docker load && IMG_COUNT=$((IMG_COUNT+1)) || log "WARN: load $(basename "$img") failed"
    done
    log "loaded $IMG_COUNT docker images"
  else
    log "no docker images in backup"
  fi

  # ── 3. Docker volumes ───────────────────────────────────────────────
  VOL_COUNT=0
  for vol_tar in "$STAGE"/vol-*.tar.gz; do
    [ -f "$vol_tar" ] || continue
    vol_name="$(basename "$vol_tar" .tar.gz | sed 's/^vol-//')"
    log "restoring volume: $vol_name"
    docker volume create "$vol_name" 2>/dev/null || true
    docker run --rm -v "$vol_name":/data -v "$STAGE":/backup alpine \
      tar xzf "/backup/$(basename "$vol_tar")" -C / && VOL_COUNT=$((VOL_COUNT+1)) || log "WARN: volume $vol_name restore failed"
  done
  log "restored $VOL_COUNT docker volumes"

  # ── 4. Docker containers (recreate from saved configs) ──────────────
  if [ -d "$STAGE/containers" ]; then
    for cfg in "$STAGE"/containers/*.json; do
      [ -f "$cfg" ] || continue
      c="$(basename "$cfg" .json)"

      # Find the image backing this container. New backups store it under the
      # container's own name; older ones prefixed it with "backup-" — once per
      # generation, so container "backup-storage" became "backup-backup-storage".
      IMAGE=""
      for cand in "$c" "backup-$c" "backup-backup-$c" "backup-backup-backup-$c"; do
        docker image inspect "$cand" >/dev/null 2>&1 || continue
        # prefer an image we tagged ourselves, fall back to a legacy one
        if [ "$(docker image inspect -f '{{index .Config.Labels "io.vps-relay.backup"}}' "$cand" 2>/dev/null)" = "1" ]; then
          IMAGE="$cand"
          break
        fi
        [ -z "$IMAGE" ] && IMAGE="$cand"
      done

      # One-step cleanup: strip the legacy "backup-" prefix so the image ends up
      # named exactly like the container (backup-backup-storage -> backup-storage).
      if [ -n "$IMAGE" ] && [ "$IMAGE" != "$c" ]; then
        if docker tag "$IMAGE" "$c" 2>/dev/null; then
          log "renamed image $IMAGE -> $c"
          docker rmi "$IMAGE" 2>/dev/null || true
          IMAGE="$c"
        fi
      fi

      if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
        log "starting existing container: $c"
        docker start "$c" || log "WARN: start $c failed"
      elif [ -n "$IMAGE" ]; then
        log "recreating container: $c from config"
        # Extract config and recreate with original settings
        python3 - "$cfg" "$IMAGE" <<'PY'
import json, sys, subprocess

cfg_file, image = sys.argv[1], sys.argv[2]
config = json.load(open(cfg_file))[0]

name = config["Name"].lstrip("/")
host_config = config.get("HostConfig", {})

cmd = ["docker", "run", "-d", "--name", name]

# Port bindings
for port, bindings in (host_config.get("PortBindings") or {}).items():
    for b in (bindings or []):
        host_ip = b.get("HostIp", "")
        host_port = b.get("HostPort", "")
        if host_port:
            cmd += ["-p", f"{host_ip}:{host_port}:{port}"]

# Volume bindings
for vol in (host_config.get("Binds") or []):
    cmd += ["-v", vol]

# Environment variables
for env in (config.get("Config", {}).get("Env") or []):
    cmd += ["-e", env]

# Restart policy
restart = host_config.get("RestartPolicy", {})
if restart.get("Name") and restart["Name"] != "no":
    cmd += ["--restart", restart["Name"]]

# Network mode
net = host_config.get("NetworkMode", "")
if net and net != "default":
    cmd += ["--network", net]

# Extra hosts
for h in (host_config.get("ExtraHosts") or []):
    cmd += ["--add-host", h]

# Entrypoint and CMD
entrypoint = config.get("Config", {}).get("Entrypoint")
cmdline = config.get("Config", {}).get("Cmd")
if entrypoint:
    cmd += ["--entrypoint", entrypoint[0] if isinstance(entrypoint, list) else entrypoint]

cmd.append(image)
if cmdline:
    cmd += cmdline

print(" ".join(cmd))
result = subprocess.run(cmd, capture_output=True, text=True)
if result.returncode == 0:
    print(f"OK: {name} started")
else:
    print(f"FAIL: {result.stderr.strip()}", file=sys.stderr)
PY
      else
        log "WARN: container $c — no image found (checked $c, backup-$c, backup-backup-$c)"
      fi
    done
  fi
fi

# ── 5. PM2 processes ────────────────────────────────────────────────
# Robust by design:
#   * validate the state is a JSON array before trusting it
#   * fall back to `pm2 jlist` output when the dump is missing/corrupt
#   * rewrite stale /host/ paths to this workspace and drop procs whose script
#     is gone (logged) instead of letting the whole resurrect fail
#   * resurrect as root AND as the runner, then count what actually came back
#   * last resort: rebuild the processes one at a time from the saved state
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
PM2_BIN="$(command -v pm2 || true)"

pm2_state=""
if [ -f "$STAGE/pm2-dump" ] && jq -e 'type == "array"' "$STAGE/pm2-dump" >/dev/null 2>&1; then
  pm2_state="$STAGE/pm2-dump"
elif [ -f "$STAGE/pm2-procs.json" ] && jq -e 'type == "array"' "$STAGE/pm2-procs.json" >/dev/null 2>&1; then
  log "WARN: pm2 dump missing/corrupt — falling back to pm2-procs.json"
  pm2_state="$STAGE/pm2-procs.json"
fi

if [ -z "$pm2_state" ]; then
  log "no usable pm2 state in backup (nothing to resurrect)"
elif [ -z "$PM2_BIN" ]; then
  log "WARN: pm2 not installed on this runner — skipping pm2 restore"
else
  # ---- fix paths belonging to a previous runner, drop dead entries --------
  FIX_MSG="$(python3 - "$pm2_state" "$WORKSPACE" <<'PY'
import json, os, sys

path, workspace = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception as e:
    print(f"cannot parse {path}: {e}")
    raise SystemExit(1)
if not isinstance(data, list):
    print("pm2 state is not a list")
    raise SystemExit(1)

def remap(v):
    if v and "/host/" in v:
        return workspace.rstrip("/") + "/" + v.split("/host/", 1)[1]
    return v

alive, dropped = [], 0
for proc in data:
    env = proc.get("pm2_env") or {}
    cwd = remap(env.get("pm_cwd") or "")
    exe = remap(env.get("pm_exec_path") or "")
    if exe and not os.path.exists(exe):
        alt = os.path.join(workspace, os.path.basename(exe))
        if os.path.exists(alt):
            exe = alt
        else:
            print(f"drop {proc.get('name', '?')}: script missing ({exe})")
            dropped += 1
            continue
    if not cwd or not os.path.isdir(cwd):
        cwd = workspace
    env["pm_cwd"] = cwd
    if exe:
        env["pm_exec_path"] = exe
    proc["pm2_env"] = env
    alive.append(proc)
json.dump(alive, open(path, "w"))
print(f"{len(alive)} process(es) restorable, {dropped} dropped")
PY
)"
  fix_rc=$?
  while IFS= read -r line; do [ -n "$line" ] && log "pm2: $line"; done <<< "$FIX_MSG"
  [ "$fix_rc" -ne 0 ] && log "WARN: pm2 state could not be rewritten — trying it as-is"

  # ---- install the dump in every pm2 home --------------------------------
  for pm_dir in "/root/.pm2" "$HOME/.pm2" "/home/runner/.pm2"; do
    if [ "$pm_dir" = "/root/.pm2" ]; then
      sudo mkdir -p "$pm_dir" 2>/dev/null || true
      sudo cp -f "$pm2_state" "$pm_dir/dump.pm2" 2>/dev/null || true
    else
      mkdir -p "$pm_dir" 2>/dev/null || true
      cp -f "$pm2_state" "$pm_dir/dump.pm2" 2>/dev/null || true
    fi
    [ -s "$pm_dir/dump.pm2" ] && log "pm2 dump installed at $pm_dir/dump.pm2"
  done

  # ---- resurrect, root first (that's where the real state lives) ---------
  count=0
  if sudo env PM2_HOME=/root/.pm2 "$PM2_BIN" resurrect >/dev/null 2>&1; then
    count="$(sudo env PM2_HOME=/root/.pm2 "$PM2_BIN" jlist 2>/dev/null \
      | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
    log "pm2 resurrect (root): $count process(es)"
  else
    log "WARN: pm2 resurrect as root failed"
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac

  if [ "$count" -eq 0 ]; then
    if env PM2_HOME="$HOME/.pm2" "$PM2_BIN" resurrect >/dev/null 2>&1; then
      count="$(env PM2_HOME="$HOME/.pm2" "$PM2_BIN" jlist 2>/dev/null \
        | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
      log "pm2 resurrect (runner): $count process(es)"
    fi
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
  fi

  # ---- last resort: start the saved processes one by one ----------------
  if [ "$count" -eq 0 ]; then
    log "resurrect returned nothing — rebuilding processes individually"
    FB_MSG="$(python3 - "$pm2_state" "$WORKSPACE" "$PM2_BIN" <<'PY'
import json, os, shlex, subprocess, sys

src, workspace, pm2_bin = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    procs = json.load(open(src))
except Exception as e:
    print(f"cannot read {src}: {e}")
    raise SystemExit(0)

started = 0
for p in procs:
    env = p.get("pm2_env") or {}
    name = p.get("name") or env.get("name") or f"restored-{started}"
    exe = env.get("pm_exec_path") or ""
    cwd = env.get("pm_cwd") or workspace
    if exe and "/host/" in exe:
        exe = workspace.rstrip("/") + "/" + exe.split("/host/", 1)[1]
    if not exe or not os.path.exists(exe):
        alt = os.path.join(workspace, os.path.basename(exe)) if exe else ""
        if alt and os.path.exists(alt):
            exe = alt
        else:
            print(f"skip {name}: script not found ({exe or 'no path'})")
            continue
    if not cwd or not os.path.isdir(cwd):
        cwd = workspace
    cmd = [pm2_bin, "start", exe, "--name", name, "--cwd", cwd]
    if env.get("exec_mode") == "cluster":
        cmd += ["-i", "max"]
    interp = env.get("interpreter") or ""
    if interp and interp not in ("node", "none"):
        cmd += ["--interpreter", interp]
    args = env.get("args") or ""
    if args:
        cmd += ["--"] + shlex.split(args)
    app_env = dict(os.environ)
    for k, v in (env.get("env") or {}).items():
        if str(k) == "PM2_HOME":
            continue
        app_env[str(k)] = str(v)
    r = subprocess.run(cmd, capture_output=True, text=True, env=app_env)
    if r.returncode == 0:
        started += 1
        print(f"started {name}")
    else:
        err = (r.stderr or r.stdout).strip().replace("\n", " ")
        print(f"FAIL {name}: {err[:180]}")
print(f"fallback start: {started} process(es)")
PY
)"
    fb_rc=$?
    while IFS= read -r line; do [ -n "$line" ] && log "pm2: $line"; done <<< "$FB_MSG"
    [ "$fb_rc" -ne 0 ] && log "WARN: pm2 fallback restart errored"
    count="$(pm2 jlist 2>/dev/null | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
  fi

  # persist whatever came back so the next cycle's backup sees it
  pm2 save >/dev/null 2>&1 || true
  sudo env PM2_HOME=/root/.pm2 "$PM2_BIN" save >/dev/null 2>&1 || true
  log "pm2 restore finished: $count process(es) running"
  pm2 list 2>/dev/null || true
fi

# ── 6. Set root password ────────────────────────────────────────────
echo "root:Frank986532" | sudo chpasswd 2>/dev/null || true

log "restore complete"
