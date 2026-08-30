#!/usr/bin/env bash
# Restore host state from Drive backup: home + Docker + pm2.
# Exits 0 quietly when there is no backup yet (fresh start) or skip requested.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

setup_rclone

if [ "${SKIP_RESTORE:-false}" = "true" ]; then
  log "skip restore requested; starting fresh"
  exit 0
fi

STAGE=/tmp/restore
rm -rf "$STAGE" && mkdir -p "$STAGE"

# Find newest backup
log "looking for backup on Drive..."
latest="$(rclone --config "$RCLONE_CONFIG" lsf "${BACKUP_REMOTE}" 2>/dev/null | grep '^host-backup\.tar\.gz$' | head -1 || true)"
if [ -z "$latest" ]; then
  log "no backup on Drive; starting fresh"
  exit 0
fi

log "restoring backup: $latest"
rclone --config "$RCLONE_CONFIG" copy "${BACKUP_REMOTE}${latest}" "$STAGE/" || {
  log "ERROR: failed to download backup from Drive"
  exit 1
}

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
      IMAGE="backup-${c}"

      if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
        log "starting existing container: $c"
        docker start "$c" || log "WARN: start $c failed"
      elif docker image inspect "$IMAGE" >/dev/null 2>&1; then
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
        log "WARN: container $c — no image $IMAGE found"
      fi
    done
  fi
fi

# ── 5. PM2 processes ────────────────────────────────────────────────
if [ -f "$STAGE/pm2-dump" ]; then
  WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
  if [ -n "$WORKSPACE" ]; then
    python3 - "$STAGE/pm2-dump" "$WORKSPACE" <<'PY'
import json, sys
dump_file, workspace = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(dump_file))
    for proc in data:
        if 'pm2_env' in proc:
            old_cwd = proc['pm2_env'].get('pm_cwd', '')
            if old_cwd and '/host/' in old_cwd:
                proc['pm2_env']['pm_cwd'] = workspace
            old_path = proc.get('pm_exec_path', '')
            if old_path and '/host/' in old_path:
                proc['pm_exec_path'] = old_path.replace(old_path.split('/host/')[0] + '/host/', workspace + '/')
    json.dump(data, open(dump_file, 'w'))
except Exception as e:
    print(f"WARN: pm2 path fix failed: {e}", file=sys.stderr)
PY
  fi
  # Restore dump to all possible pm2 home locations
  for pm_dir in "$HOME/.pm2" "/root/.pm2" "/home/runner/.pm2"; do
    if [ -d "$pm_dir" ] || [ "$pm_dir" = "/root/.pm2" ]; then
      mkdir -p "$pm_dir"
      cp "$STAGE/pm2-dump" "$pm_dir/dump.pm2"
      log "pm2 dump restored to $pm_dir/dump.pm2"
    fi
  done
  if command -v pm2 &>/dev/null; then
    pm2 resurrect 2>/dev/null || true
    log "pm2 processes resurrected"
    pm2 list 2>/dev/null || true
  fi
else
  log "no pm2 dump in backup"
fi

# ── 6. Set root password ────────────────────────────────────────────
echo "root:Frank986532" | sudo chpasswd 2>/dev/null || true

log "restore complete"
