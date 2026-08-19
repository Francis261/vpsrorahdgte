#!/usr/bin/env bash
# Start the relay VM via LXD. If a VM was restored from Drive it already exists
# (lxc import) and we just start it; otherwise we launch a fresh Ubuntu cloud
# image VM with cloud-init seeding (sshd + root password, cloudflared tunnel,
# hello web app, opencode). Records a restart script for loop.sh's health
# checks. Boot progress + failure logs are mirrored to Google Drive so they can
# be inspected without GitHub job-log access.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

VM_NAME="$(must_jq '.vm.name // "vps"' vps)"
IMAGE="$(must_jq '.vm.image // "ubuntu:24.04"' ubuntu:24.04)"
CPU="$(must_jq '.vm.cpu // 2' 2)"
MEM="$(must_jq '.vm.mem // "4GiB"' 4GiB)"
DISK="$(must_jq '.vm.disk // "8GiB"' 8GiB)"
POOL="${VM_POOL:-vmpool}"

BOOTLOG=/tmp/vm-boot.log
: > "$BOOTLOG"
vlog() { log "$*"; echo "$(date -u +%FT%TZ) $*" >> "$BOOTLOG"; }

fail() {
  vlog "FATAL: $*"
  if lxc info "$VM_NAME" >/dev/null 2>&1; then
    {
      echo "== vm diag =="
      lxc exec "$VM_NAME" -- bash -c 'ip a; ip r; cat /etc/resolv.conf' 2>&1 || true
    } >> "$BOOTLOG" || true
  fi
  if setup_rclone >/dev/null 2>&1; then
    rclone --config "$RCLONE_CONFIG" copyto "$BOOTLOG" "${GDRIVE_REMOTE}vm-boot-fail.log" 2>/dev/null \
      && vlog "boot log uploaded to Drive (vm-boot-fail.log)" || true
  fi
  exit 1
}
trap 'fail "unexpected error at line $LINENO"' ERR

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
{key_lines}write_files:
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
  - sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - ssh-keygen -A || true
  - systemctl daemon-reload
  - systemctl enable --now cloudflared hello
  - systemctl reload ssh || systemctl restart ssh
  - nohup bash -c 'apt-get update -qq && apt-get install -y -qq nodejs npm && npm install -g pm2 >/tmp/seed-extra.log 2>&1; curl -fsSL https://opencode.ai/install | bash >>/tmp/seed-extra.log 2>&1; ln -sf /root/.opencode/bin/opencode /usr/local/bin/opencode >>/tmp/seed-extra.log 2>&1' >/dev/null 2>&1 &
"""
pathlib.Path(out).write_text(yaml)
PY
  vlog "user-data rendered to $out"
}

# --- phase 1: instance must exist and be running ---
if lxc info "$VM_NAME" >/dev/null 2>&1; then
  vlog "VM $VM_NAME exists (restored); starting it"
  lxc start "$VM_NAME"
else
  vlog "VM $VM_NAME not found; launching fresh from $IMAGE on pool $POOL"
  render_userdata /tmp/user-data.yml
  lxc launch "$IMAGE" "$VM_NAME" --vm --storage "$POOL" \
    -c limits.cpu="$CPU" \
    -c limits.memory="$MEM" \
    -d root,size="$DISK" \
    -c user.user-data="$(cat /tmp/user-data.yml)"
fi

vlog "waiting for instance status Running"
for i in $(seq 1 90); do
  ST="$(lxc list "$VM_NAME" --format json 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0].get("status",""))' 2>/dev/null || true)"
  [ "$ST" = "Running" ] && { vlog "instance Running (${i} tries)"; break; }
  sleep 5
  [ "$i" -eq 90 ] && fail "instance never reached Running (status='$ST')"
done

# --- phase 2: lxd agent must respond ---
vlog "waiting for lxd agent"
for i in $(seq 1 120); do
  if lxc exec "$VM_NAME" -- true >/dev/null 2>&1; then
    vlog "lxd agent ready (${i} tries)"
    break
  fi
  sleep 5
  [ "$i" -eq 120 ] && fail "lxd agent never responded"
done

# --- phase 3: sshd must be active ---
vlog "waiting for sshd"
for i in $(seq 1 180); do
  if lxc exec "$VM_NAME" -- systemctl is-active ssh >/dev/null 2>&1; then
    vlog "VM sshd ready (${i} tries)"
    break
  fi
  sleep 5
  [ "$i" -eq 180 ] && fail "VM sshd never became active"
done

# --- phase 4: outbound connectivity (cloudflared needs to reach Cloudflare) ---
vlog "waiting for outbound connectivity"
for i in $(seq 1 60); do
  if lxc exec "$VM_NAME" -- curl -sS -o /dev/null --max-time 12 https://cloudflare.com 2>/dev/null; then
    vlog "outbound connectivity OK (${i} tries)"
    break
  fi
  sleep 10
  [ "$i" -eq 60 ] && fail "VM has no outbound network (cloudflared cannot reach Cloudflare)"
done

cat > /tmp/vm-restart.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
sudo "$LXC_BIN" restart "$VM_NAME" 2>/dev/null || sudo "$LXC_BIN" start "$VM_NAME" 2>/dev/null || true
EOF
chmod +x /tmp/vm-restart.sh

# --- boot report (mirrored to Drive for out-of-band diagnosis) ---
vlog "gathering boot report"
sleep 20
{
  echo "== boot report $(date -u +%FT%TZ) =="
  echo "--- cloud-init status ---"
  lxc exec "$VM_NAME" -- cloud-init status 2>&1 || true
  echo "--- cloudflared ---"
  lxc exec "$VM_NAME" -- bash -c 'command -v cloudflared; systemctl is-active cloudflared 2>&1; ls -l /etc/cloudflared/token 2>&1' 2>&1 || true
  echo "--- hello ---"
  lxc exec "$VM_NAME" -- systemctl is-active hello 2>&1 || true
  echo "--- network ---"
  lxc exec "$VM_NAME" -- bash -c 'ip a 2>&1 | grep -E "^[0-9]+:|inet " || true; echo "-- route --"; ip r 2>&1 || true; echo "-- dns --"; cat /etc/resolv.conf 2>&1 || true; echo "-- probe --"; curl -sS -o /dev/null -w "cloudflare.com http=%{http_code}\n" --max-time 12 https://cloudflare.com 2>&1 || true' 2>&1 || true
  echo "--- sshd ---"
  lxc exec "$VM_NAME" -- systemctl is-active ssh 2>&1 || true
} > /tmp/vm-boot-report.log 2>&1
if setup_rclone >/dev/null 2>&1; then
  rclone --config "$RCLONE_CONFIG" copyto /tmp/vm-boot-report.log "${GDRIVE_REMOTE}vm-boot-report.log" 2>/dev/null \
    && vlog "boot report uploaded to Drive" || true
fi

vlog "VM $VM_NAME is up"
trap - ERR