#!/usr/bin/env bash
# Commit + save the VPS container, tar host paths from mustBackup.json,
# upload one timestamped artifact to Drive, then prune old backups.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

setup_rclone

TS="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE=/tmp/backup
rm -rf "$STAGE" && mkdir -p "$STAGE"

# --- docker ---
CONTAINERS="$(jq -r '.containers[]?' "$REPO_ROOT/mustBackup.json" 2>/dev/null || true)"
HAD_DOCKER=0
for c in $CONTAINERS; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    log "committing container $c"
    docker commit "$c" vps:latest
    log "saving image vps:latest"
    docker save vps:latest | gzip > "$STAGE/docker-$c.tar.gz"
    HAD_DOCKER=1
  else
    log "WARN container $c not present; skipping docker backup"
  fi
done

# --- host paths ---
HOST_PATHS="$(jq -r '.host_paths[]?' "$REPO_ROOT/mustBackup.json" 2>/dev/null || true)"
HAD_PATHS=0
if [ -n "$HOST_PATHS" ]; then
  # shellcheck disable=SC2086
  if tar -czf "$STAGE/host-paths.tar.gz" -C / $HOST_PATHS 2>/dev/null; then
    log "host paths archived"
    HAD_PATHS=1
  else
    log "WARN some host paths missing; archived what exists"
    [ -f "$STAGE/host-paths.tar.gz" ] && HAD_PATHS=1
  fi
fi

# --- meta + artifact ---
jq -n --arg ts "$TS" --arg repo "$(self_repo)" --arg run "${RUN_ID:-}" \
  --arg image "vps:latest" --arg containers "$(echo "$CONTAINERS" | tr '\n' ',')" \
  '{timestamp:$ts,repo:$repo,run_id:$run,image_tag:$image,containers:$containers}' \
  > "$STAGE/meta.json"

if [ "$HAD_DOCKER" -eq 0 ] && [ "$HAD_PATHS" -eq 0 ]; then
  die "nothing to back up (no containers, no host paths)"
fi

TAR_FILES="meta.json"
[ "$HAD_PATHS" -eq 1 ] && TAR_FILES="$TAR_FILES host-paths.tar.gz"
for c in $CONTAINERS; do
  [ -f "$STAGE/docker-$c.tar.gz" ] && TAR_FILES="$TAR_FILES docker-$c.tar.gz"
done

ARTIFACT="vps-$TS.tar.gz"
# shellcheck disable=SC2086
tar -czf "$STAGE/$ARTIFACT" -C "$STAGE" $TAR_FILES

rclone --config "$RCLONE_CONFIG" copy "$STAGE/$ARTIFACT" "${BACKUP_REMOTE}"
log "uploaded $ARTIFACT"

# --- prune old backups ---
rclone --config "$RCLONE_CONFIG" lsf "${BACKUP_REMOTE}" 2>/dev/null | grep '\.tar\.gz$' \
  | sort | head -n -"$KEEP_BACKUPS" | while read -r f; do
    [ -n "$f" ] && rclone --config "$RCLONE_CONFIG" delete "${BACKUP_REMOTE}$f"
  done
log "pruned backups (keeping last $KEEP_BACKUPS)"