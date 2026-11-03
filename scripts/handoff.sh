#!/usr/bin/env bash
# Hand off to the next account in the chain: update the lease, then fire a
# repository_dispatch event so the next repo's vps.yml starts and restores.
# If DRBD is enabled, the secondary is already running — skip the dispatch.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

storage_setup

self="$(self_repo)"
next="$(next_repo "$self")"
nextnext="$(next_repo "$next")"
: "${HANDOFF_PAT:?HANDOFF_PAT not set}"

log "handing off $self -> $next"
lease_write "$next" "$(now_iso)" "$(now_iso)" "$nextnext" "${RUN_ID:-}"

# If DRBD is enabled, the secondary VPS is already running (started by drbd-trigger)
# at the 4-hour mark. It will promote to primary when we do. No need to dispatch again.
if [ "${DRBD_ENABLED:-false}" = "true" ]; then
  log "DRBD enabled — secondary already running, skipping handoff dispatch"
else
  curl -fsS -X POST \
    -H "Authorization: Bearer $HANDOFF_PAT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$next/dispatches" \
    -d "{\"event_type\":\"handoff\",\"client_payload\":{\"from\":\"$self\",\"run_id\":\"${RUN_ID:-}\"}}"
  log "dispatch sent to $next"
fi