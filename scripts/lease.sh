#!/usr/bin/env bash
# Manual lease CLI: read / acquire / touch / inspect (mostly for debugging).
# Usage: scripts/lease.sh {read|acquire <holder> [run_id]|touch <holder> [run_id]}
set -euo pipefail
source "$(dirname "$0")/lib.sh"

cmd="${1:-read}"
setup_rclone

case "$cmd" in
  read)
    c="$(lease_read || true)"
    [ -n "$c" ] && echo "$c" || echo "no lease on Drive"
    ;;
  acquire)
    holder="${2:?usage: acquire <holder> [run_id]}"
    run_id="${3:-}"
    age="$(lease_age_min)"
    curholder="$(lease_holder)"
    if [ "$age" -le "$HOLD_TIMEOUT_MIN" ] && [ -n "$curholder" ] && [ "$curholder" != "$holder" ]; then
      die "lease held by $curholder (age ${age}min); refusing to acquire"
    fi
    lease_write "$holder" "$(now_iso)" "$(now_iso)" "" "$run_id"
    log "lease acquired by $holder"
    ;;
  touch)
    holder="${2:?usage: touch <holder> [run_id]}"
    lease_touch "$holder" "${3:-}"
    log "lease refreshed for $holder"
    ;;
  inspect)
    echo "holder: $(lease_holder)"
    echo "age_min: $(lease_age_min)"
    ;;
  *)
    echo "usage: $0 {read|acquire|touch|inspect}" >&2
    exit 2
    ;;
esac