#!/bin/bash
# Container entrypoint: sshd + cloudflared (if config mounted) + pm2, then hold.
set -e

if [ -f /etc/ssh/sshd_config ]; then
  # Restored images may predate password auth being enabled; force it on.
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/; s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
  printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/99-relay-auth.conf 2>/dev/null || true
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