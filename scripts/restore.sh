#!/usr/bin/env bash
# Pull the newest backup from Drive, load the docker image, restore host paths.
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

latest="$(rclone --config "$RCLONE_CONFIG" lsf "${BACKUP_REMOTE}" 2>/dev/null | grep '\.tar\.gz$' | sort | tail -1 || true)"
if [ -z "$latest" ]; then
  log "no backup on Drive; starting fresh"
  exit 0
fi

log "restoring newest backup: $latest"
rclone --config "$RCLONE_CONFIG" copy "${BACKUP_REMOTE}${latest}" "$STAGE/"
tar -xzf "$STAGE/$latest" -C "$STAGE"

IMG_TAR="$(ls "$STAGE"/docker-*.tar.gz 2>/dev/null | head -1 || true)"
if [ -n "$IMG_TAR" ]; then
  log "loading docker image: $IMG_TAR"
  docker load -i "$IMG_TAR"
fi

if [ -f "$STAGE/host-paths.tar.gz" ]; then
  log "restoring host paths"
  sudo tar -xzf "$STAGE/host-paths.tar.gz" -C /
fi

log "restore complete"