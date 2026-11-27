#!/usr/bin/env bash
# Main orchestrator. Holds the job alive until the handoff minute,
# then runs backup + handoff and exits cleanly.
#
# The hold is capped by the job's own deadline: the GitHub job is killed hard
# at JOB_START_EPOCH + JOB_TIMEOUT_MIN, so the hold must give the backup its
# reserved slice (BACKUP_BUDGET_MIN) or the cycle would die mid-backup.
# NOTE: No set -e — backup/handoff failures should log, not kill the VPS.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
set +e

HANDOFF_AT_MIN="$(handoff_after_min)"
START="$(now_epoch)"
JOB_DEADLINE="$(job_deadline_epoch)"

# Hold end = start of hold + configured hold, but never later than
# "deadline minus the backup budget".
HOLD_UNTIL=$(( START + HANDOFF_AT_MIN * 60 ))
RESERVE_UNTIL=$(( JOB_DEADLINE - BACKUP_BUDGET_MIN * 60 ))
if [ "$RESERVE_UNTIL" -lt "$HOLD_UNTIL" ]; then
  HOLD_UNTIL="$RESERVE_UNTIL"
  if [ "$HOLD_UNTIL" -le "$START" ]; then
    log "WARN: no time left for the hold — backing up immediately"
    HOLD_UNTIL="$START"
  else
    log "hold shortened to $(( (HOLD_UNTIL - START) / 60 )) min (deadline reserves ${BACKUP_BUDGET_MIN} min for backup)"
  fi
fi

log "VPS loop active; handoff scheduled at ${HANDOFF_AT_MIN} min"

while true; do
  NOW="$(now_epoch)"
  ELAPSED=$(( (NOW - START) / 60 ))

  # Health check: verify pm2 and docker are responsive (bounded — a hung
  # daemon must not stall the hold/backup loop itself)
  if [ "$ELAPSED" -gt 0 ] && [ $((ELAPSED % 5)) -eq 0 ]; then
    timeout 30 pm2 ping >/dev/null 2>&1 || log "WARN: pm2 not responding"
    timeout 30 docker info >/dev/null 2>&1 || log "WARN: docker not responding"
  fi

  if [ "$NOW" -ge "$HOLD_UNTIL" ]; then
    log "handoff time reached (${ELAPSED} min elapsed)"
    break
  fi

  sleep 60
done

LEFT=$(( JOB_DEADLINE - $(now_epoch) ))
log "running backup (deadline in $(( LEFT / 60 )) min)"
BACKUP_DEADLINE_EPOCH="$JOB_DEADLINE" bash "$REPO_ROOT/scripts/backup.sh"
rc=$?
if [ "$rc" -eq 0 ]; then
  log "backup succeeded"
else
  log "WARN: backup failed (exit code $rc)"
fi

log "running handoff"
bash "$REPO_ROOT/scripts/handoff.sh"
rc=$?
if [ "$rc" -eq 0 ]; then
  log "handoff succeeded"
else
  log "WARN: handoff failed (exit code $rc)"
fi

log "cycle complete; exiting cleanly"
