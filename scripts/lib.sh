#!/usr/bin/env bash
# Shared helpers for the relay-VPS scripts. Source me, do not execute.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- configurable env (defaults sensible for GitHub Actions) ---
: "${RCLONE_CONFIG:=/tmp/rclone.conf}"
: "${S3_REMOTE:=minio:}"          # rclone remote name created by setup_rclone
: "${S3_BUCKET:=vps-relay}"       # bucket that holds backups + the lease
: "${BUCKET_ROOT:=${S3_REMOTE}${S3_BUCKET}/}"
: "${BACKUP_REMOTE:=${BUCKET_ROOT}backups/}"
: "${LEASE_PATH:=lease.json}"
: "${HOLD_TIMEOUT_MIN:=45}"
: "${HEARTBEAT_INTERVAL_MIN:=5}"
: "${KEEP_BACKUPS:=1}"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

now_epoch() { date +%s; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

self_repo() { echo "${GITHUB_REPOSITORY:-unknown/unknown}"; }

# --- mustBackup.json helpers (v2) ---
must_jq() { jq -r "$1" "$REPO_ROOT/mustBackup.json" 2>/dev/null || echo "$2"; }
handoff_after_min()     { must_jq '.handoff_after_min // 300' 300; }
tunnel_hostname()       { must_jq '.tunnel.hostname // ""' ""; }
tunnel_host_hostname()  { must_jq '.tunnel.host_hostname // ""' ""; }
tunnel_uuid()           { must_jq '.tunnel.tunnel_uuid // ""' ""; }

# Backup exclusion list — converts JSON array to newline-separated for tar --exclude
backup_home_excludes() {
  jq -r '.backup.home_exclude[]? // empty' "$REPO_ROOT/mustBackup.json" 2>/dev/null | \
    while IFS= read -r pat; do [ -n "$pat" ] && echo "--exclude=$pat"; done
}

# --- chain.json ---
next_repo() {
  local self="$1"
  [ -f "$REPO_ROOT/chain.json" ] || die "chain.json not found"
  local n i owner repo idx=-1
  n="$(jq 'length' "$REPO_ROOT/chain.json")"
  [ "$n" -gt 0 ] || die "chain.json is empty"
  for ((i = 0; i < n; i++)); do
    owner="$(jq -r ".[$i].owner" "$REPO_ROOT/chain.json")"
    repo="$(jq -r ".[$i].repo" "$REPO_ROOT/chain.json")"
    if [ "$owner/$repo" = "$self" ] || [ "$owner" = "$self" ]; then
      idx=$i
      break
    fi
  done
  [ "$idx" -ge 0 ] || idx=0
  local next=$(( (idx + 1) % n ))
  jq -r ".[$next].owner + \"/\" + .[$next].repo" "$REPO_ROOT/chain.json"
}

# --- rclone (MinIO / S3-compatible endpoint) ---
setup_rclone() {
  : "${S3_ENDPOINT:?S3_ENDPOINT not set (secret) — e.g. http://161.97.113.70:9000}"
  : "${S3_ACCESS_KEY_ID:?S3_ACCESS_KEY_ID not set (secret)}"
  : "${S3_SECRET_ACCESS_KEY:?S3_SECRET_ACCESS_KEY not set (secret)}"

  local endpoint="$S3_ENDPOINT"
  case "$endpoint" in
    http://*|https://*) ;;            # rclone accepts a scheme in endpoint
    *) endpoint="http://${endpoint}"  # bare host[:port] defaults to plain HTTP for self-hosted MinIO
       ;;
  esac

  cat > "$RCLONE_CONFIG" <<EOF
[minio]
type = s3
provider = Minio
endpoint = $endpoint
access_key_id = $S3_ACCESS_KEY_ID
secret_access_key = $S3_SECRET_ACCESS_KEY
acl = private
EOF
  chmod 600 "$RCLONE_CONFIG" 2>/dev/null || true

  # Make sure the bucket exists (the relay key is scoped to it and may not be
  # allowed to list other buckets). Harmless if it already does.
  rclone --config "$RCLONE_CONFIG" mkdir "${S3_REMOTE}${S3_BUCKET}" >/dev/null 2>&1 || true
}

# --- lease (lease.json lives in the shared MinIO bucket) ---
lease_read() {
  local lf=/tmp/lease/lease.json
  rm -rf /tmp/lease && mkdir -p /tmp/lease
  if rclone --config "$RCLONE_CONFIG" copy "${BUCKET_ROOT}${LEASE_PATH}" /tmp/lease/ >/dev/null 2>&1; then
    [ -f "$lf" ] && cat "$lf"
  fi
}

lease_upload() { rclone --config "$RCLONE_CONFIG" moveto "$1" "${BUCKET_ROOT}${LEASE_PATH}"; }

lease_write() {
  local lf=/tmp/lease-write.json
  jq -n --arg h "$1" --arg s "$2" --arg hb "$3" --arg n "$4" --arg r "$5" \
    '{holder:$h,since:$s,heartbeat:$hb,next:$n,run_id:$r}' > "$lf"
  lease_upload "$lf"
}

lease_holder() { local c; c="$(lease_read || true)"; printf '%s' "$c" | jq -r '.holder // ""'; }
lease_age_min() {
  local c hb hb_epoch
  c="$(lease_read || true)"
  [ -n "$c" ] || { echo 9999; return; }
  hb="$(printf '%s' "$c" | jq -r '.heartbeat // ""')"
  [ -n "$hb" ] || { echo 9999; return; }
  hb_epoch="$(date -u -d "$hb" +%s 2>/dev/null || echo 0)"
  [ -n "$hb_epoch" ] && [ "$hb_epoch" -gt 0 ] || { echo 9999; return; }
  echo $(( ( $(now_epoch) - hb_epoch) / 60 ))
}

lease_touch() {
  local holder="$1" run_id="${2:-}" cur since next
  cur="$(lease_read || true)"
  since="$(printf '%s' "$cur" | jq -r '.since // ""')"
  next="$(printf '%s' "$cur" | jq -r '.next // ""')"
  [ -n "$since" ] || since="$(now_iso)"
  lease_write "$holder" "$since" "$(now_iso)" "$next" "$run_id"
}
