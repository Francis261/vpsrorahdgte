#!/usr/bin/env bash
# Hand off to the next account in the chain:
#   1. write the lease (the watchdog can recover from this alone)
#   2. dispatch a handoff event to the next repo
set -uo pipefail
source "$(dirname "$0")/lib.sh"
set +e

storage_setup

self="$(self_repo)"
next="$(next_repo "$self")"
nextnext="$(next_repo "$next")"
if lease_write "$next" "$(now_iso)" "$(now_iso)" "$nextnext" "${RUN_ID:-}"; then
  log "lease written for $next"
else
  log "WARN: could not write the lease for $next"
fi

dispatched=0
ref="${VPS_BRANCH:-}"

# 1. workflow_dispatch via gh — needs a token with Actions: write on $next
if [ -n "$ref" ]; then
  if gh workflow run vps.yml --repo "$next" --ref "$ref" >/dev/null 2>&1; then
    log "handoff dispatched to $next @ $ref (workflow_dispatch)"
    dispatched=1
  else
    log "WARN: gh workflow dispatch to $next @ $ref failed (token has no access to that repo?)"
  fi
fi

# 2. repository_dispatch via the PAT
if [ "$dispatched" = "0" ] && [ -n "${HANDOFF_PAT:-}" ]; then
  HTTP_CODE="$(curl -sS -o /tmp/handoff-resp.json -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $HANDOFF_PAT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$next/dispatches" \
    -d "{\"event_type\":\"handoff\",\"client_payload\":{\"from\":\"$self\",\"run_id\":\"${RUN_ID:-}\"}}" \
    2>/tmp/handoff-curl.err)"
  if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
    log "handoff dispatched to $next (repository_dispatch)"
    dispatched=1
  else
    log "WARN: handoff dispatch to $next failed (HTTP ${HTTP_CODE:-?})"
    case "$HTTP_CODE" in
      401|403)
        log "  the HANDOFF_PAT secret is invalid, expired, or lacks access to $next"
        log "  → refresh secrets.HANDOFF_PAT in this repo (fine-grained PAT: Actions: write + Workflows: write on $next)"
        ;;
      404)
        log "  repo $next was not found for this token"
        ;;
    esac
    log "  response: $(head -c 300 /tmp/handoff-resp.json 2>/dev/null | tr '\n' ' ')"
  fi
fi

if [ "$dispatched" = "0" ]; then
  log "WARN: handoff did not dispatch — lease already written, watchdog/forward will recover"
fi
