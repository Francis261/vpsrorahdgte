#!/usr/bin/env bash
# Watchdog: if the Drive lease is stale (holder died, missed handoff, account
# hit the 6h kill, etc.) and this repo has no run in progress, acquire the
# lease and boot our own vps.yml. Runs from watchdog.yml on a schedule.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

setup_rclone

self="$(self_repo)"
age="$(lease_age_min)"
holder="$(lease_holder)"
log "lease holder='$holder' age=${age}min (timeout ${HOLD_TIMEOUT_MIN}min)"

if [ "$age" -le "$HOLD_TIMEOUT_MIN" ]; then
  log "lease fresh; chain healthy"
  exit 0
fi

if gh run list --workflow=vps.yml --status=in_progress --json databaseId --jq 'length' 2>/dev/null | grep -q '[1-9]'; then
  log "vps.yml already in progress here; skipping recovery"
  exit 0
fi

log "lease stale; acquiring and booting self"
lease_write "$self" "$(now_iso)" "$(now_iso)" "" "${RUN_ID:-}"
gh workflow run vps.yml --repo "$self" 2>/dev/null || \
  curl -fsS -X POST \
    -H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$self/actions/workflows/vps.yml/dispatches" \
    -d '{"ref":"main"}'
log "vps.yml booted on $self"