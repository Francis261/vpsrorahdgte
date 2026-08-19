#!/usr/bin/env bash
# Pull the newest VM backup from Drive and import it into LXD (creates the
# instance that vm.sh then starts). Exits 0 quietly when there is no backup
# yet (fresh start) or a skip is requested.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

setup_rclone

if [ "${SKIP_RESTORE:-false}" = "true" ]; then
  log "skip restore requested; starting fresh"
  exit 0
fi

STAGE=/tmp/restore
rm -rf "$STAGE" && mkdir -p "$STAGE"

latest="$(rclone --config "$RCLONE_CONFIG" lsf "${BACKUP_REMOTE}" 2>/dev/null | grep '^vm-.*\.tar\.gz$' | sort | tail -1 || true)"
if [ -z "$latest" ]; then
  log "no VM backup on Drive; starting fresh"
  exit 0
fi

log "restoring newest backup: $latest"
rclone --config "$RCLONE_CONFIG" copy "${BACKUP_REMOTE}${latest}" "$STAGE/"
lxc import "$STAGE/$latest" || die "lxc import failed for $latest"
log "restore complete"