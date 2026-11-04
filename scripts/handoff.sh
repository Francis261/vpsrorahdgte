#!/usr/bin/env bash
# Hand off to the next account in the chain: update the lease, then fire a
# repository_dispatch event (or self-workflow dispatch) so the next stage starts.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

storage_setup

self="$(self_repo)"
next="$(next_repo "$self")"
nextnext="$(next_repo "$next")"

log "handing off $self -> $next"
lease_write "$next" "$(now_iso)" "$(now_iso)" "$nextnext" "${RUN_ID:-}"

# If DRBD is enabled, the secondary VPS is already running (started by drbd-trigger)
# at the 4-hour mark. It will promote to primary when we do. No need to dispatch again.
if [ "${DRBD_ENABLED:-false}" = "true" ] && [ "$next" != "$self" ]; then
  log "DRBD enabled — secondary already running, skipping handoff dispatch"
  exit 0
fi

# Determine if we should self-handoff (loop to same repo)
should_self_handoff=false
if [ -z "${HANDOFF_PAT:-}" ]; then
  log "HANDOFF_PAT not set — self-handoff mode (looping to self)"
  should_self_handoff=true
elif [ "$next" = "$self" ]; then
  log "Single-repo chain — self-handoff (looping to self)"
  should_self_handoff=true
elif [ "${SELF_HANDOFF:-false}" = "true" ]; then
  log "SELF_HANDOFF=true — forcing self-loop even with HANDOFF_PAT set"
  should_self_handoff=true
fi

ref="${VPS_BRANCH:-}"

dispatched=0
if [ "$should_self_handoff" = "true" ]; then
  if [ -n "$ref" ]; then
    gh workflow run vps.yml --repo "$self" --ref "$ref" 2>/dev/null && log "self-handoff dispatched to $self @ $ref" && dispatched=1
  else
    gh workflow run vps.yml --repo "$self" 2>/dev/null && log "self-handoff dispatched to $self" && dispatched=1
  fi
  if [ "$dispatched" = "0" ]; then
    log "WARN: gh workflow dispatch for handoff failed (will retry via cron/loop)"
  fi
else
  if [ -n "$ref" ]; then
    if gh workflow run vps.yml --repo "$next" --ref "$ref" 2>/dev/null; then
      log "handoff dispatched to $next @ $ref"; dispatched=1
    fi
  fi
  if [ "$dispatched" = "0" ] && [ -n "${HANDOFF_PAT:-}" ]; then
    curl -fsS -X POST \
      -H "Authorization: Bearer $HANDOFF_PAT" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/$next/dispatches" \
      -d "{\"event_type\":\"handoff\",\"client_payload\":{\"from\":\"$self\",\"run_id\":\"${RUN_ID:-}\"}}" \
      && log "handoff dispatched to $next (default branch)" && dispatched=1
  fi
  [ "$dispatched" = "0" ] && log "WARN: handoff dispatch failed"
fi