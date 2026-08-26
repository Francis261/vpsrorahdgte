#!/usr/bin/env bash
# Main orchestrator. Holds the job alive until the handoff minute,
# then runs backup + handoff and exits cleanly.
# NOTE: No set -e — backup/handoff failures should log, not kill the VPS.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

HANDOFF_AT_MIN="$(handoff_after_min)"
log "VPS loop active; handoff scheduled at ${HANDOFF_AT_MIN} min"
START="$(now_epoch)"

while true; do
  ELAPSED=$(( ( $(now_epoch) - START) / 60 ))

  # Health check: verify pm2 and docker are responsive
  if [ "$ELAPSED" -gt 0 ] && [ $((ELAPSED % 5)) -eq 0 ]; then
    pm2 ping 2>/dev/null || log "WARN: pm2 not responding"
    docker info >/dev/null 2>&1 || log "WARN: docker not responding"
  fi

  if [ "$ELAPSED" -ge "$HANDOFF_AT_MIN" ]; then
    log "handoff time reached (${ELAPSED} min elapsed)"
    break
  fi

  sleep 60
done

log "running backup"
if bash "$REPO_ROOT/scripts/backup.sh"; then
  log "backup succeeded"
else
  log "WARN: backup failed (exit code $?)"
fi

log "running handoff"
if bash "$REPO_ROOT/scripts/handoff.sh"; then
  log "handoff succeeded"
else
  log "WARN: handoff failed (exit code $?)"
fi

log "cycle complete; exiting cleanly"
