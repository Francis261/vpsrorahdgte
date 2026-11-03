#!/usr/bin/env bash
# Hand off to the next account in the chain: update the lease, then fire a
# repository_dispatch event so the next repo's vps.yml starts and restores.
# If DRBD is enabled, the secondary is already running — skip the dispatch.
# If HANDOFF_PAT is not set, loop to self (single-repo mode).
# SELF_HANDOFF=true forces self-loop even when HANDOFF_PAT is set.
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
if [ "${DRBD_ENABLED:-false}" = "true" ]; then
  log "DRBD enabled — secondary already running, skipping handoff dispatch"
  exit 0
fi

# Determine if we should self-handoff (loop to same repo)
# Self-handoff happens when:
# 1. HANDOFF_PAT is not set (no token to call next repo), OR
# 2. SELF_HANDOFF=true is explicitly set (forces self-loop even with token)
should_self_handoff=false
if [ -z "${HANDOFF_PAT:-}" ]; then
  log "HANDOFF_PAT not set — self-handoff mode (looping to self)"
  should_self_handoff=true
elif [ "${SELF_HANDOFF:-false}" = "true" ]; then
  log "SELF_HANDOFF=true — forcing self-handoff even with HANDOFF_PAT set"
  should_self_handoff=true
fi

if [ "$should_self_handoff" = "true" ]; then
  # Self-handoff: dispatch to our own repo
  # Use GITHUB_TOKEN (available in Actions) since we're dispatching to self
  gh workflow run vps.yml --repo "$self" 2>/dev/null || \
    curl -fsS -X POST \
      -H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/$self/dispatches" \
      -d "{\"event_type\":\"handoff\",\"client_payload\":{\"from\":\"$self\",\"run_id\":\"${RUN_ID:-}\"}}"
  log "self-handoff dispatch sent to $self"
else
  # Normal handoff to next repo using HANDOFF_PAT
  curl -fsS -X POST \
    -H "Authorization: Bearer $HANDOFF_PAT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$next/dispatches" \
    -d "{\"event_type\":\"handoff\",\"client_payload\":{\"from\":\"$self\",\"run_id\":\"${RUN_ID:-}\"}}"
  log "dispatch sent to $next"
fi