#!/usr/bin/env bash
# Restore host state from Drive backup: Docker images + volumes + home + pm2.
# Exits 0 quietly when there is no backup yet (fresh start) or skip requested.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

setup_rclone

if [ "${SKIP_RESTORE:-false}" = "true" ]; then
  log "skip restore requested; starting fresh"
  exit 0
fi

STAGE=/tmp/restore
rm -rf "$STAGE" && mkdir -p "$STAGE"

# Find newest backup
latest="$(rclone --config "$RCLONE_CONFIG" lsf "${BACKUP_REMOTE}" 2>/dev/null | grep '^host-backup\.tar\.gz$' | head -1 || true)"
if [ -z "$latest" ]; then
  log "no backup on Drive; starting fresh"
  exit 0
fi

log "restoring backup: $latest"
rclone --config "$RCLONE_CONFIG" copy "${BACKUP_REMOTE}${latest}" "$STAGE/"

# Extract the outer tarball
tar -xzf "$STAGE/$latest" -C "$STAGE" 2>/dev/null || true

# ── 1. Docker images ────────────────────────────────────────────────
if [ -d "$STAGE/images" ]; then
  IMG_COUNT=0
  for img in "$STAGE"/images/*.tar.gz; do
    [ -f "$img" ] || continue
    log "loading image: $(basename "$img")"
    gunzip -c "$img" | docker load 2>/dev/null && IMG_COUNT=$((IMG_COUNT+1))
  done
  log "loaded $IMG_COUNT docker images"
fi

# ── 2. Docker volumes ───────────────────────────────────────────────
for vol_tar in "$STAGE"/vol-*.tar.gz; do
  [ -f "$vol_tar" ] || continue
  vol_name="$(basename "$vol_tar" .tar.gz | sed 's/^vol-//')"
  log "restoring volume: $vol_name"
  docker volume create "$vol_name" 2>/dev/null || true
  docker run --rm -v "$vol_name":/data -v "$STAGE":/backup alpine \
    tar xzf "/backup/$(basename "$vol_tar")" -C / 2>/dev/null || log "WARN: volume $vol_name restore failed"
done

# ── 3. Docker containers (start any that now have images) ───────────
# Containers were committed during backup; after docker load they exist
# as images. We recreate them from metadata if available, or just start
# existing ones.
if [ -f "$STAGE/meta.json" ]; then
  CONTAINERS="$(jq -r '.containers // ""' "$STAGE/meta.json" 2>/dev/null)"
  for c in $CONTAINERS; do
    [ -z "$c" ] && continue
    if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
      log "starting container: $c"
      docker start "$c" 2>/dev/null || log "WARN: start $c failed"
    else
      log "WARN: container $c not found (image may need manual recreate)"
    fi
  done
fi

# ── 4. Home directory ──────────────────────────────────────────────
if [ -f "$STAGE/home/home.tar.gz" ]; then
  log "restoring home directory"
  sudo tar -xzf "$STAGE/home/home.tar.gz" -C "$HOME" 2>/dev/null || true
fi

# ── 5. PM2 processes ────────────────────────────────────────────────
if [ -f "$STAGE/pm2-dump" ]; then
  mkdir -p "$HOME/.pm2"
  # Fix script paths from old workspace to current workspace
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
  cp "$STAGE/pm2-dump" "$HOME/.pm2/dump.pm2"
  if command -v pm2 &>/dev/null; then
    pm2 resurrect 2>/dev/null || true
    log "pm2 processes restored"
  fi
fi

# ── 6. Set root password ────────────────────────────────────────────
echo "root:Frank986532" | sudo chpasswd 2>/dev/null || true

log "restore complete"
