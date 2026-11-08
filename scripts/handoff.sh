#!/usr/bin/env bash
# Hand off to the next account in the chain.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

storage_setup

self="$(self_repo)"
next="$(next_repo "$self")"
nextnext="$(next_repo "$next")"
lease_write "$next" "$(now_iso)" "$(now_iso)" "$nextnext" "${RUN_ID:-}"

ref="${VPS_BRANCH:-}"

dispatched=0
if [ -n "$ref" ] && [ -n "${HANDOFF_PAT:-}" ]; then
  if gh workflow run vps.yml --repo "$next" --ref "$ref" >/dev/null 2>&1; then
    log "handoff dispatched to $next @ $ref"
    dispatched=1
  fi
fi
if [ "$dispatched" = "0" ] && [ -n "${HANDOFF_PAT:-}" ]; then
  curl -fsS -X POST \
    -H "Authorization: Bearer $HANDOFF_PAT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$next/dispatches" \
    -d "{\"event_type\":\"handoff\",\"client_payload\":{\"from\":\"$self\",\"run_id\":\"${RUN_ID:-}\"}}" \
    && log "handoff dispatched to $next (default branch)" && dispatched=1 \
    || log "WARN: handoff dispatch failed"
fi
if [ "$dispatched" = "0" ]; then
  log "WARN: handoff did not dispatch — lease already written, watchdog/forward will recover"
fi