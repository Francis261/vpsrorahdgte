#!/usr/bin/env bash
# Background heartbeat: refresh the lease every few minutes so the watchdogs
# know the chain is alive. Also auto-restarts cloudflared and sshd if they die.
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

  # Auto-restart cloudflared if dead
  if ! pgrep -f 'cloudflared tunnel' >/dev/null 2>&1; then
    log "WARN: cloudflared dead, restarting..."
    if [ -f /tmp/cf/token ]; then
      nohup cloudflared tunnel run --token "$(cat /tmp/cf/token)" \
        >/tmp/cloudflared.log 2>&1 &
      log "cloudflared restarted (pid $!)"
    fi
  fi

  # Auto-restart sshd if dead
  if ! pgrep -f 'sshd' >/dev/null 2>&1; then
    log "WARN: sshd dead, restarting..."
    sudo /usr/sbin/sshd 2>/dev/null || true
  fi

  sleep $((HEARTBEAT_INTERVAL_MIN * 60))
done