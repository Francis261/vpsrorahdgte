#!/usr/bin/env bash
# Export the relay VM (own kernel) to a gzipped LXD backup and upload it to
# Drive, then prune old backups. The VM is stopped briefly for a consistent
# export (this happens right before handoff, so any tunnel blip is fine).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

setup_rclone

TS="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE=/tmp/backup
rm -rf "$STAGE" && mkdir -p "$STAGE"

VM_NAME="$(must_jq '.vm.name // "vps"' vps)"
ARTIFACT="vm-$TS.tar.gz"

log "stopping VM $VM_NAME for consistent export"
lxc stop "$VM_NAME" --timeout 30 || true

log "exporting VM $VM_NAME"
lxc export "$VM_NAME" "$STAGE/$ARTIFACT" --compression gzip

log "restarting VM $VM_NAME"
lxc start "$VM_NAME" || true

jq -n --arg ts "$TS" --arg repo "$(self_repo)" --arg run "${RUN_ID:-}" --arg vm "$VM_NAME" \
  '{timestamp:$ts,repo:$repo,run_id:$run,vm:$vm}' > "$STAGE/meta.json"

rclone --config "$RCLONE_CONFIG" copy "$STAGE/$ARTIFACT" "${BACKUP_REMOTE}"
log "uploaded $ARTIFACT"

rclone --config "$RCLONE_CONFIG" lsf "${BACKUP_REMOTE}" 2>/dev/null | grep '^vm-.*\.tar\.gz$' \
  | sort | head -n -"$KEEP_BACKUPS" | while read -r f; do
    [ -n "$f" ] && rclone --config "$RCLONE_CONFIG" delete "${BACKUP_REMOTE}$f"
  done
log "pruned backups (keeping last $KEEP_BACKUPS)"