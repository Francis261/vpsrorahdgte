#!/bin/bash
# Container entrypoint: sshd + cloudflared (if config mounted) + pm2, then hold.
set -e

if [ -f /etc/ssh/sshd_config ]; then
  echo 'root:Frank986532' | chpasswd
  /usr/sbin/sshd
  echo "[entrypoint] sshd started (root password auth enabled)"
fi

if [ -f /etc/cloudflared/token ]; then
  TOKEN="$(cat /etc/cloudflared/token)"
  (cloudflared tunnel run --token "$TOKEN" >/tmp/cloudflared.log 2>&1 &)
  echo "[entrypoint] cloudflared (token) started"
elif [ -f /etc/cloudflared/config.yml ]; then
  (cloudflared tunnel --config /etc/cloudflared/config.yml run >/tmp/cloudflared.log 2>&1 &)
  echo "[entrypoint] cloudflared started"
fi

if [ -f /root/.pm2/dump.pm2 ]; then
  pm2 resurrect || true
fi
if [ -f /app/services/ecosystem.config.js ]; then
  pm2 start /app/services/ecosystem.config.js || true
fi
pm2 save >/dev/null 2>&1 || true

echo "[entrypoint] holding open"
exec tail -f /dev/null