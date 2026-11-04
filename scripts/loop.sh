#!/usr/bin/env bash
# Main orchestrator. Holds the job alive until the handoff minute,
# then runs backup + handoff and exits cleanly.
# NOTE: No set -e — backup/handoff failures should log, not kill the VPS.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

HANDOFF_AT_MIN="$(handoff_after_min)"
# DRBD trigger window: min(60, handoff/2) minutes before handoff so even fast tests fire
DRBD_MARGIN_MIN=60; [ "$HANDOFF_AT_MIN" -lt 120 ] && DRBD_MARGIN_MIN=$(( HANDOFF_AT_MIN / 2 ))
[ "$DRBD_MARGIN_MIN" -lt 1 ] && DRBD_MARGIN_MIN=1
DRBD_TRIGGER_AT_MIN=$(( HANDOFF_AT_MIN - DRBD_MARGIN_MIN ))
[ "$DRBD_TRIGGER_AT_MIN" -lt 1 ] && DRBD_TRIGGER_AT_MIN=1
log "VPS loop active; handoff scheduled at ${HANDOFF_AT_MIN} min, DRBD trigger at ${DRBD_TRIGGER_AT_MIN} min"
START="$(now_epoch)"
DRBD_TRIGGERED=0
DRBD_DISABLED_FILE=/tmp/drbd-processed

while true; do
  ELAPSED=$(( ( $(now_epoch) - START) / 60 ))

  # Health check: verify pm2 and docker are responsive
  if [ "$ELAPSED" -gt 0 ] && [ $((ELAPSED % 5)) -eq 0 ]; then
    pm2 ping 2>/dev/null || log "WARN: pm2 not responding"
    docker info >/dev/null 2>&1 || log "WARN: docker not responding"
  fi

  # DRBD trigger at configured minute (idempotent: only fires once per run)
  if [ "${DRBD_ENABLED:-false}" = "true" ] && [ "$ELAPSED" -ge "$DRBD_TRIGGER_AT_MIN" ] && [ ! -f "$DRBD_DISABLED_FILE" ]; then
    touch "$DRBD_DISABLED_FILE"
    log "DRBD trigger time reached (${ELAPSED} min elapsed); starting secondary on next account"
    self="$(self_repo)"; next="$(next_repo "$self")"
    # Prefer explicit branch (VPS_BRANCH) so the secondary runs the same
    # branch code (e.g. vps4) instead of defaulting to main (GDrive).
    ref="${VPS_BRANCH:-}"
    dispatched=0
    if [ -n "$ref" ]; then
      if gh workflow run vps.yml --repo "$next" --ref "$ref" \
            -f drbd_mode=secondary -f drbd_primary_repo="$self" 2>/dev/null; then
        log "dispatched drbd-start to $next @ $ref"; dispatched=1
      fi
    fi
    if [ "$dispatched" = "0" ] && gh workflow run vps.yml --repo "$next" \
          -f drbd_mode=secondary -f drbd_primary_repo="$self" 2>/dev/null; then
      log "dispatched drbd-start to $next (default branch)"; dispatched=1
    fi
    if [ "$dispatched" = "0" ] && [ -n "${HANDOFF_PAT:-}" ]; then
      curl -fsS -X POST \
        -H "Authorization: Bearer $HANDOFF_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$next/dispatches" \
        -d "{\"event_type\":\"drbd-start\",\"client_payload\":{\"primary\":\"$self\",\"mode\":\"secondary\"}}" \
        && log "dispatched drbd-start to $next via repository_dispatch (lands on default branch)" && dispatched=1
    fi
    if [ "$dispatched" = "0" ]; then
      log "WARN: drbd dispatch failed (no repo-admin access)"; fi
  fi

  if [ "$ELAPSED" -ge "$HANDOFF_AT_MIN" ]; then
    log "handoff time reached (${ELAPSED} min elapsed)"
    break
  fi

  sleep 60
done

# Promote DRBD to primary if enabled (before backup so backup includes DRBD data)
if [ "${DRBD_ENABLED:-false}" = "true" ] && [ -f "$REPO_ROOT/scripts/drbd-setup.sh" ] && [ -b "/dev/drbd0" ]; then
  log "Promoting DRBD to primary for handoff..."
  if sudo -E bash "$REPO_ROOT/scripts/drbd-setup.sh" promote; then
    log "DRBD promoted successfully"
  else
    log "WARN: DRBD promotion failed (exit code $?)"
  fi
fi

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
