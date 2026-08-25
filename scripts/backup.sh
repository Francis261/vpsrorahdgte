#!/usr/bin/env bash
# Comprehensive host backup: Docker images + volumes + home dir + pm2 state.
# Uploads a single host-backup.tar.gz to Drive, deleting the old one first.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

setup_rclone

STAGE=/tmp/backup
rm -rf "$STAGE" && mkdir -p "$STAGE/images" "$STAGE/home"

# ── 1. PM2 process list ──────────────────────────────────────────────
if command -v pm2 &>/dev/null; then
  pm2 save 2>/dev/null || true
  PM2_DUMP="$HOME/.pm2/dump.pm2"
  if [ -f "$PM2_DUMP" ]; then
    cp "$PM2_DUMP" "$STAGE/pm2-dump"
    log "pm2 process list saved"
  fi
fi

# ── 2. Docker images (commit running containers, then save) ──────────
RUNNING_CONTAINERS="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
if [ -n "$RUNNING_CONTAINERS" ]; then
  for c in $RUNNING_CONTAINERS; do
    IMAGE_TAG="backup-${c}"
    log "committing container $c → $IMAGE_TAG"
    docker commit "$c" "$IMAGE_TAG" >/dev/null 2>&1 || { log "WARN: commit $c failed"; continue; }
    log "saving $IMAGE_TAG"
    docker save "$IMAGE_TAG" | gzip > "$STAGE/images/$c.tar.gz"
    docker rmi "$IMAGE_TAG" 2>/dev/null || true
  done
  log "docker images saved: $(ls "$STAGE/images/"*.tar.gz | wc -l)"
else
  log "no running containers to back up"
fi

# ── 3. Docker volumes ────────────────────────────────────────────────
if [ -d /var/lib/docker/volumes ]; then
  docker volume ls -q 2>/dev/null | while read -r vol; do
    [ -z "$vol" ] && continue
    log "saving volume $vol"
    docker run --rm -v "$vol":/data:ro -v "$STAGE":/backup alpine \
      tar czf "/backup/vol-${vol}.tar.gz" -C / data 2>/dev/null || log "WARN: volume $vol skipped"
  done
  log "docker volumes saved"
else
  log "no docker volumes directory"
fi

# ── 4. Home directory (excluding large dirs) ────────────────────────
log "backing up home directory"
tar -czf "$STAGE/home/home.tar.gz" \
  -C "$HOME" \
  --exclude='.nvm' --exclude='.cache' --exclude='node_modules' \
  --exclude='.npm' --exclude='.yarn' --exclude='go' \
  --exclude='.cargo' --exclude='.rustup' --exclude='.gradle' \
  --exclude='.m2' --exclude='.android' --exclude='.vscode-server' \
  --exclude='.local/share/Trash' \
  . 2>/dev/null || true
log "home directory saved ($(du -sh "$STAGE/home/home.tar.gz" | cut -f1))"

# ── 5. Metadata ──────────────────────────────────────────────────────
jq -n \
  --arg ts "$(now_iso)" \
  --arg repo "$(self_repo)" \
  --arg run "${RUN_ID:-}" \
  --arg hostname "$(hostname)" \
  --arg containers "$RUNNING_CONTAINERS" \
  '{timestamp:$ts, repo:$repo, run_id:$run, hostname:$hostname, containers:$containers}' \
  > "$STAGE/meta.json"

# ── 6. Create single tarball ────────────────────────────────────────
ARTIFACT="host-backup.tar.gz"
log "creating $ARTIFACT"
tar -czf "$STAGE/$ARTIFACT" -C "$STAGE" meta.json images/ volumes.tar.gz home/ pm2-dump 2>/dev/null || \
  tar -czf "$STAGE/$ARTIFACT" -C "$STAGE" meta.json images/ home/ pm2-dump 2>/dev/null || \
  tar -czf "$STAGE/$ARTIFACT" -C "$STAGE" meta.json home/ pm2-dump
SIZE="$(du -h "$STAGE/$ARTIFACT" | cut -f1)"
log "artifact ready: $ARTIFACT ($SIZE)"

# ── 7. Delete old backup, upload new ────────────────────────────────
rclone --config "$RCLONE_CONFIG" delete "${BACKUP_REMOTE}host-backup.tar.gz" 2>/dev/null || true
rclone --config "$RCLONE_CONFIG" copy "$STAGE/$ARTIFACT" "${BACKUP_REMOTE}"
log "uploaded $ARTIFACT"

# Clean any leftover old-format backups
rclone --config "$RCLONE_CONFIG" lsf "${BACKUP_REMOTE}" 2>/dev/null | grep -v '^host-backup.tar.gz$' | \
  grep '\.tar\.gz$' | while read -r f; do
    [ -n "$f" ] && rclone --config "$RCLONE_CONFIG" delete "${BACKUP_REMOTE}$f" && log "pruned old format: $f"
  done

log "backup complete"
