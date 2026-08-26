#!/usr/bin/env bash
# Hand off to the next account in the chain: update the lease, then fire a
# repository_dispatch event so the next repo's vps.yml starts and restores.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

setup_rclone

self="$(self_repo)"
next="$(next_repo "$self")"
nextnext="$(next_repo "$next")"
: "${HANDOFF_PAT:?HANDOFF_PAT not set}"

log "handing off $self -> $next"
lease_write "$next" "$(now_iso)" "$(now_iso)" "$nextnext" "${RUN_ID:-}"

curl -fsS -X POST \
  -H "Authorization: Bearer $HANDOFF_PAT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$next/dispatches" \
  -d "{\"event_type\":\"handoff\",\"client_payload\":{\"from\":\"$self\",\"run_id\":\"${RUN_ID:-}\"}}"

log "dispatch sent to $next"