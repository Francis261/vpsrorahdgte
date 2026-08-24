#!/usr/bin/env bash
# Main orchestrator. Holds the job alive (keeping the container healthy) until
# the handoff minute, then runs backup + handoff and exits cleanly - well under
# the 360-minute hosted-runner hard cap.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

HANDOFF_AT_MIN="$(handoff_after_min)"
log "VPS loop active; handoff scheduled at ${HANDOFF_AT_MIN} min"
START="$(now_epoch)"

while true; do
  ELAPSED=$(( ( $(now_epoch) - START) / 60 ))

  if ! docker ps --format '{{.Names}}' | grep -qx vps; then
    log "WARN container 'vps' is not running"
    if [ -x /tmp/vps-restart.sh ]; then
      log "restarting container"
      bash /tmp/vps-restart.sh || log "restart failed (will retry next tick)"
    fi
  fi

  if [ "$ELAPSED" -ge "$HANDOFF_AT_MIN" ]; then
    log "handoff time reached (${ELAPSED} min elapsed)"
    break
  fi

  log "alive at ${ELAPSED} min"
  sleep 60
done

log "running backup"
bash "$REPO_ROOT/scripts/backup.sh"
log "running handoff"
bash "$REPO_ROOT/scripts/handoff.sh"
log "cycle complete; exiting cleanly"