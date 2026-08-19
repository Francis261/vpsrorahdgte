#!/usr/bin/env bash
# Start the VPS container. Builds the image if needed, wires the Cloudflare
# tunnel config/credentials from secrets, and records a restart script so the
# loop can bring the container back if it ever dies.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if ! docker image inspect vps:latest >/dev/null 2>&1; then
  log "no vps:latest image; building from Dockerfile"
  docker build -t vps:latest "$REPO_ROOT"
fi

CF_FLAGS=""
if [ -n "${CF_TUNNEL_CREDS:-}" ]; then
  CF_UUID="$(tunnel_uuid)"
  CF_HOST="$(tunnel_hostname)"
  CF_SSH_HOST="$(tunnel_ssh_hostname)"
  WEB_PORT="$(tunnel_web_port)"
  SSH_PORT="$(tunnel_ssh_port)"
  [ -n "$CF_UUID" ] && [ -n "$CF_HOST" ] && [ -n "$CF_SSH_HOST" ] || \
    die "tunnel.uuid / tunnel.hostname / tunnel.ssh_hostname must be set in mustBackup.json when using a tunnel"
  mkdir -p /tmp/cf
  echo "$CF_TUNNEL_CREDS" > "/tmp/cf/$CF_UUID.json"
  cat > /tmp/cf/config.yml <<EOF
tunnel: $CF_UUID
credentials-file: /etc/cloudflared/$CF_UUID.json
ingress:
  - hostname: $CF_HOST
    service: http://localhost:$WEB_PORT
  - hostname: $CF_SSH_HOST
    service: ssh://localhost:$SSH_PORT
  - service: http_status:404
EOF
  CF_FLAGS="-v /tmp/cf/$CF_UUID.json:/etc/cloudflared/$CF_UUID.json:ro -v /tmp/cf/config.yml:/etc/cloudflared/config.yml:ro"
  log "cloudflared tunnel config prepared for $CF_HOST / $CF_SSH_HOST"
else
  log "CF_TUNNEL_CREDS not set; starting without tunnel"
fi

docker rm -f vps >/dev/null 2>&1 || true

# shellcheck disable=SC2086  # intentional word-splitting of CF_FLAGS
docker run -d --name vps --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 8080:8080 -p 2222:22 \
  $CF_FLAGS \
  vps:latest

cat > /tmp/vps-restart.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
docker rm -f vps >/dev/null 2>&1 || true
EOF
cat >> /tmp/vps-restart.sh <<EOF
docker run -d --name vps --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 8080:8080 -p 2222:22 \
  $CF_FLAGS \
  vps:latest
EOF
chmod +x /tmp/vps-restart.sh

log "vps container started"