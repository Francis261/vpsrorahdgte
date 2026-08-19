#!/usr/bin/env bash
# Background heartbeat: refresh the lease every few minutes so the watchdogs
# know the chain is alive. Run with nohup, not directly blocking.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

setup_rclone
holder="${1:-$(self_repo)}"
run_id="${2:-}"

while true; do
  if lease_touch "$holder" "$run_id"; then
    log "heartbeat refreshed"
  else
    log "WARN heartbeat refresh failed"
  fi
  sleep $((HEARTBEAT_INTERVAL_MIN * 60))
done