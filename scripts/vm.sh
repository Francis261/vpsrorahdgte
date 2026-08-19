#!/usr/bin/env bash
# Start the relay VM via LXD. If a VM was restored from Drive it already exists
# (lxc import) and we just start it; otherwise we launch a fresh Ubuntu cloud
# image VM with cloud-init seeding (sshd + root password, cloudflared tunnel,
# hello web app, opencode). Records a restart script for loop.sh's health
# checks so the VM can be brought back if it ever dies.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

VM_NAME="$(must_jq '.vm.name // "vps"' vps)"
IMAGE="$(must_jq '.vm.image // "ubuntu:24.04"' ubuntu:24.04)"
CPU="$(must_jq '.vm.cpu // 2' 2)"
MEM="$(must_jq '.vm.mem // "4GiB"' 4GiB)"
DISK="$(must_jq '.vm.disk // "8GiB"' 8GiB)"

: "${CF_TUNNEL_TOKEN:?CF_TUNNEL_TOKEN not set (secret) - required to seed cloudflared}"

render_userdata() {
  local out="$1"
  python3 - "$REPO_ROOT" "$out" <<'PY'
import os, pathlib, sys

root, out = pathlib.Path(sys.argv[1]), sys.argv[2]

def rd(p):
    return (root / p).read_text()

def blk(s):
    return "content: |\n" + "\n".join("      " + ln for ln in s.rstrip("\n").split("\n"))

keys = [ln.strip() for ln in rd("services/seed/authorized_keys").splitlines()
        if ln.strip() and not ln.strip().startswith("#")]

token = os.environ.get("CF_TUNNEL_TOKEN", "")
if not token:
    sys.exit("CF_TUNNEL_TOKEN not set; cannot seed cloudflared")

key_lines = "".join(f"      - {k}\n" for k in keys) or "      []\n"

yaml = f"""#cloud-config
ssh_pwauth: true
disable_root: false
users:
  - name: root
    plain_text_passwd: Frank986532
    lock_passwd: false
    ssh_authorized_keys:
{key_lines}package_update: true
packages:
  - curl
  - jq
  - openssh-server
  - nodejs
  - npm
write_files:
  - path: /etc/cloudflared/token
    content: '{token}'
    permissions: '0600'
  - path: /etc/systemd/system/cloudflared.service
    content: |
      [Unit]
      Description=Cloudflare Tunnel
      After=network-online.target
      Wants=network-online.target
      [Service]
      ExecStart=/bin/bash -c 'exec /usr/local/bin/cloudflared tunnel run --token "$(cat /etc/cloudflared/token)"'
      Restart=always
      RestartSec=5
      [Install]
      WantedBy=multi-user.target
  - path: /etc/systemd/system/hello.service
    content: |
      [Unit]
      Description=vps hello web app
      After=network.target
      [Service]
      ExecStart=/usr/bin/node /app/services/hello/server.js
      Restart=always
      RestartSec=3
      [Install]
      WantedBy=multi-user.target
  - path: /app/services/hello/server.js
    {blk(rd("services/hello/server.js"))}
  - path: /root/.bashrc
    {blk(rd("services/seed/bashrc"))}
  - path: /root/.config/opencode/opencode.json
    {blk(rd("services/seed/opencode.json"))}
  - path: /root/.ssh/authorized_keys
    {blk(rd("services/seed/authorized_keys"))}
    permissions: '0600'
runcmd:
  - mkdir -p /etc/cloudflared /app/services/hello /root/.config/opencode /root/.ssh
  - curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
  - chmod 755 /usr/local/bin/cloudflared
  - npm install -g pm2
  - curl -fsSL https://opencode.ai/install | bash
  - ln -sf /root/.opencode/bin/opencode /usr/local/bin/opencode
  - sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - ssh-keygen -A || true
  - systemctl daemon-reload
  - systemctl enable --now cloudflared hello
  - systemctl reload ssh || systemctl restart ssh
"""
pathlib.Path(out).write_text(yaml)
PY
  log "user-data rendered to $out"
}

if lxc info "$VM_NAME" >/dev/null 2>&1; then
  log "VM $VM_NAME exists (restored); starting it"
  lxc start "$VM_NAME"
else
  log "VM $VM_NAME not found; launching fresh from $IMAGE"
  render_userdata /tmp/user-data.yml
  lxc launch "$IMAGE" "$VM_NAME" --vm \
    -c limits.cpu="$CPU" \
    -c limits.memory="$MEM" \
    -d root,size="$DISK" \
    -c user.user-data="$(cat /tmp/user-data.yml)"
fi

log "waiting for VM sshd to come up"
for i in $(seq 1 120); do
  if lxc exec "$VM_NAME" -- systemctl is-active ssh >/dev/null 2>&1; then
    log "VM sshd ready after ${i} tries"
    break
  fi
  sleep 5
  [ "$i" -eq 120 ] && die "VM $VM_NAME failed to become ready in time"
done

cat > /tmp/vm-restart.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
sudo "$LXC_BIN" restart "$VM_NAME" 2>/dev/null || sudo "$LXC_BIN" start "$VM_NAME" 2>/dev/null || true
EOF
chmod +x /tmp/vm-restart.sh

log "VM $VM_NAME is up"