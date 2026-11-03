#!/usr/bin/env bash
# DRBD setup for vps-relay: replicates a host directory via loop device
# between two GitHub Actions runners using Cloudflare Zero Trust mesh.
#
# Usage:
#   drbd-setup.sh primary                    # on the current VPS (primary)
#   drbd-setup.sh secondary <primary_repo>   # on the next VPS (secondary)
#
# The script:
# 1. Creates a sparse backing file and loop device
# 2. Configures DRBD with both nodes' Cloudflare private IPs
# 3. Starts DRBD, promotes primary, formats filesystem, mounts
# 4. On secondary: waits for sync, mounts read-only initially
#
# Requires: Cloudflare tunnel with private network enabled (100.64.0.0/10)

set -euo pipefail
source "$(dirname "$0")/lib.sh"

DRBD_ROLE="${1:-primary}"
DRBD_PRIMARY_REPO="${2:-}"
DRBD_RESOURCE="vpsdata"
DRBD_DEVICE="/dev/drbd0"
DRBD_MOUNT="/mnt/drbd"
DRBD_BACKING_FILE="/var/lib/drbd-backing.img"
DRBD_SIZE_GB="${DRBD_SIZE_GB:-10}"   # size of the replicated volume
DRBD_PORT=7789                       # DRBD replication port (over CF mesh)

log() { printf '[%s] DRBD: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# Get our Cloudflare private IP (assigned to the tunnel)
get_cf_private_ip() {
  # cloudflared exposes the private IP via the metrics endpoint or we can
  # derive it from the tunnel's assigned IP. For Zero Trust private network,
  # each tunnel gets an IP in 100.64.0.0/10.
  # We'll try to get it from cloudflared's metrics or the interface.
  local ip
  # Method 1: check cloudflared metrics endpoint (if enabled)
  if ip="$(curl -s -m 5 http://127.0.0.1:43493/metrics 2>/dev/null | grep -oE 'cloudflared_tunnel_private_ip\{[^}]*\} [0-9.]+' | cut -d' ' -f2 | head -1)"; then
    [ -n "$ip" ] && echo "$ip" && return
  fi
  # Method 2: check the cloudflared interface (tun0 or similar)
  ip="$(ip -4 addr show 2>/dev/null | grep -oE '100\.[6-9][0-9]\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$ip" ] && echo "$ip" && return
  # Method 3: if we have a named tunnel, query Cloudflare API
  if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
    # Can't easily get private IP from token alone without API access
    :
  fi
  return 1
}

# Get peer's private IP from the lease (written by primary)
get_peer_private_ip() {
  local lease
  lease="$(lease_read 2>/dev/null || true)"
  if [ -n "$lease" ]; then
    echo "$lease" | jq -r '.cf_private_ip // empty' 2>/dev/null || true
  fi
}

# Write our private IP to the lease for the peer to find
write_our_private_ip() {
  local ip="$1"
  local lf=/tmp/lease-write.json
  local cur
  cur="$(lease_read 2>/dev/null || true)"
  local holder since hb next run
  holder="$(printf '%s' "$cur" | jq -r '.holder // ""')"
  since="$(printf '%s' "$cur" | jq -r '.since // ""')"
  hb="$(printf '%s' "$cur" | jq -r '.heartbeat // ""')"
  next="$(printf '%s' "$cur" | jq -r '.next // ""')"
  run="$(printf '%s' "$cur" | jq -r '.run_id // ""')"
  [ -n "$since" ] || since="$(now_iso)"
  jq -n --arg h "$holder" --arg s "$since" --arg hb "$(now_iso)" \
    --arg n "$next" --arg r "$run" --arg ip "$ip" \
    '{holder:$h,since:$s,heartbeat:$hb,next:$n,run_id:$r,cf_private_ip:$ip}' > "$lf"
  lease_upload "$lf"
}

# Install DRBD packages
install_drbd() {
  if command -v drbdadm >/dev/null 2>&1; then
    log "DRBD already installed"
    return
  fi
  log "Installing DRBD..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq drbd-utils >/dev/null
  modprobe drbd || true
  log "DRBD installed"
}

# Create backing file and loop device
setup_backing_file() {
  if [ -b "$(losetup -j "$DRBD_BACKING_FILE" 2>/dev/null | cut -d: -f1 | head -1)" ]; then
    log "Backing file already attached"
    return
  fi
  log "Creating $DRBD_SIZE_GB GB sparse backing file at $DRBD_BACKING_FILE"
  mkdir -p "$(dirname "$DRBD_BACKING_FILE")"
  truncate -s "${DRBD_SIZE_GB}G" "$DRBD_BACKING_FILE"
  local loopdev
  loopdev="$(losetup -f --show "$DRBD_BACKING_FILE")"
  log "Attached backing file to $loopdev"
}

# Generate DRBD config
generate_drbd_config() {
  local my_ip="$1"
  local peer_ip="$2"
  local my_role="$3"  # primary or secondary

  cat > /etc/drbd.d/${DRBD_RESOURCE}.res <<EOF
resource ${DRBD_RESOURCE} {
  device    ${DRBD_DEVICE};
  disk      $(losetup -j "$DRBD_BACKING_FILE" | cut -d: -f1 | head -1);
  meta-disk internal;

  on $(hostname) {
    address   ${my_ip}:${DRBD_PORT};
    node-id   0;
  }
  on ${DRBD_PRIMARY_REPO//\//-} {
    address   ${peer_ip}:${DRBD_PORT};
    node-id   1;
  }

  connection {
    host $(hostname) port ${DRBD_PORT};
    host ${DRBD_PRIMARY_REPO//\//-} port ${DRBD_PORT};
  }

  net {
    protocol C;
    timeout 60;
    connect-int 10;
    ping-int 10;
    ping-timeout 100;
  }
  disk {
    resync-rate 100M;
    c-plan-ahead 20;
  }
}
EOF
  log "Generated DRBD config: my_ip=$my_ip peer_ip=$peer_ip role=$my_role"
}

# Primary node setup
setup_primary() {
  local my_ip
  my_ip="$(get_cf_private_ip)" || die "Cannot determine Cloudflare private IP"
  log "Primary node private IP: $my_ip"

  # Write our IP to lease for secondary to find
  write_our_private_ip "$my_ip"

  # Wait for secondary to appear in lease (with timeout)
  log "Waiting for secondary to register..."
  local peer_ip=""
  for i in {1..60}; do
    peer_ip="$(get_peer_private_ip)"
    [ -n "$peer_ip" ] && [ "$peer_ip" != "null" ] && break
    sleep 5
  done
  [ -n "$peer_ip" ] && [ "$peer_ip" != "null" ] || die "Secondary did not register private IP in time"

  log "Secondary private IP: $peer_ip"
  generate_drbd_config "$my_ip" "$peer_ip" "primary"

  # Initialize DRBD metadata
  drbdadm create-md "${DRBD_RESOURCE}" || die "create-md failed"
  drbdadm up "${DRBD_RESOURCE}" || die "drbdadm up failed"

  # Promote to primary (force if needed)
  drbdadm primary --force "${DRBD_RESOURCE}" || die "primary promotion failed"

  # Wait for sync to start (we're primary, so we're the source)
  log "Waiting for DRBD sync to start..."
  local state
  for i in {1..30}; do
    state="$(drbdadm status "${DRBD_RESOURCE}" 2>/dev/null | grep -oE 'SyncSource|UpToDate' | head -1 || true)"
    [ -n "$state" ] && break
    sleep 2
  done

  # Format filesystem (only on first run - check if already formatted)
  if ! blkid "${DRBD_DEVICE}" >/dev/null 2>&1; then
    log "Formatting DRBD device with ext4"
    mkfs.ext4 -F "${DRBD_DEVICE}" || die "mkfs failed"
  fi

  # Mount
  mkdir -p "${DRBD_MOUNT}"
  mount "${DRBD_DEVICE}" "${DRBD_MOUNT}" || die "mount failed"
  log "DRBD primary ready at ${DRBD_MOUNT}"
}

# Secondary node setup
setup_secondary() {
  if [ -z "$DRBD_PRIMARY_REPO" ]; then
    die "DRBD_PRIMARY_REPO not set for secondary mode"
  fi

  local my_ip peer_ip
  my_ip="$(get_cf_private_ip)" || die "Cannot determine Cloudflare private IP"
  log "Secondary node private IP: $my_ip"

  # Get primary's private IP from lease (primary writes it)
  log "Reading primary's private IP from lease..."
  peer_ip="$(get_peer_private_ip)"
  [ -n "$peer_ip" ] && [ "$peer_ip" != "null" ] || die "Primary private IP not found in lease"

  log "Primary private IP: $peer_ip"
  generate_drbd_config "$my_ip" "$peer_ip" "secondary"

  # Initialize DRBD metadata
  drbdadm create-md "${DRBD_RESOURCE}" || die "create-md failed"
  drbdadm up "${DRBD_RESOURCE}" || die "drbdadm up failed"

  # Wait for connection and sync
  log "Waiting for DRBD connection to primary..."
  for i in {1..120}; do
    local conn_state
    conn_state="$(drbdadm status "${DRBD_RESOURCE}" 2>/dev/null | grep -oE 'Connected|WFConnection' | head -1 || true)"
    [ "$conn_state" = "Connected" ] && break
    sleep 5
  done

  log "Connected to primary. Waiting for sync..."
  for i in {1..600}; do  # up to 50 min for 10GB at 100M/s
    local disk_state
    disk_state="$(drbdadm status "${DRBD_RESOURCE}" 2>/dev/null | grep -oE 'UpToDate|SyncTarget' | head -1 || true)"
    [ "$disk_state" = "UpToDate" ] && break
    [ "$disk_state" = "SyncTarget" ] && log "Syncing... ($(drbdadm status "${DRBD_RESOURCE}" | grep -oE '[0-9]+%' | head -1))"
    sleep 5
  done

  # Mount read-only initially (will be promoted on handoff)
  mkdir -p "${DRBD_MOUNT}"
  mount -o ro "${DRBD_DEVICE}" "${DRBD_MOUNT}" || die "mount failed"
  log "DRBD secondary ready at ${DRBD_MOUNT} (read-only, synced)"

  # Update lease to show secondary is ready (prevents watchdog from booting new primary)
  local lf=/tmp/lease-write.json
  jq -n --arg h "$(self_repo)" --arg s "$(now_iso)" --arg hb "$(now_iso)" \
    --arg n "$(next_repo "$(self_repo)")" --arg r "${RUN_ID:-}" \
    '{holder:$h,since:$s,heartbeat:$hb,next:$n,run_id:$r,drbd_secondary:true}' > "$lf"
  lease_upload "$lf"
  log "Lease updated: DRBD secondary ready on $(self_repo)"
}

# Promote secondary to primary (called during handoff)
promote_to_primary() {
  log "Promoting DRBD secondary to primary..."
  drbdadm primary "${DRBD_RESOURCE}" || die "promotion failed"
  # Remount read-write
  mount -o remount,rw "${DRBD_MOUNT}" || die "remount rw failed"
  log "DRBD promoted to primary, mounted read-write at ${DRBD_MOUNT}"
}

# Main
case "$DRBD_ROLE" in
  primary)
    install_drbd
    setup_backing_file
    setup_primary
    ;;
  secondary)
    install_drbd
    setup_backing_file
    setup_secondary
    ;;
  promote)
    promote_to_primary
    ;;
  *)
    echo "Usage: $0 {primary|secondary <primary_repo>|promote}" >&2
    exit 1
    ;;
esac