#!/usr/bin/env bash
# Shared helpers for the relay-VPS scripts. Source me, do not execute.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- configurable env (defaults sensible for GitHub Actions) ---
: "${RCLONE_CONFIG:=/tmp/rclone.conf}"
: "${GDRIVE_SA_FILE:=/tmp/gdrive-sa.json}"
: "${GDRIVE_REMOTE:=gdrive:}"
: "${BACKUP_REMOTE:=${GDRIVE_REMOTE}backups/}"
: "${LEASE_PATH:=lease.json}"
: "${HOLD_TIMEOUT_MIN:=45}"
: "${HEARTBEAT_INTERVAL_MIN:=5}"
: "${KEEP_BACKUPS:=5}"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

now_epoch() { date +%s; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

self_repo() { echo "${GITHUB_REPOSITORY:-unknown/unknown}"; }

# --- mustBackup.json helpers ---
must_jq() { jq -r "$1" "$REPO_ROOT/mustBackup.json" 2>/dev/null || echo "$2"; }
handoff_after_min()     { must_jq '.handoff_after_min // 300' 300; }
tunnel_hostname()       { must_jq '.tunnel.hostname // ""' ""; }
tunnel_ssh_hostname()   { must_jq '.tunnel.ssh_hostname // ""' ""; }
tunnel_uuid()           { must_jq '.tunnel.tunnel_uuid // ""' ""; }
tunnel_web_port()       { must_jq '.tunnel.web_port // 8080' 8080; }
tunnel_ssh_port()       { must_jq '.tunnel.ssh_port // 22' 22; }

# --- chain.json ---
# Given the current repo ("owner/repo"), return the next "owner/repo" in the chain.
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

# --- rclone ---
setup_rclone() {
  if [ -n "${GDRIVE_SERVICE_ACCOUNT_JSON:-}" ]; then
    echo "$GDRIVE_SERVICE_ACCOUNT_JSON" > "$GDRIVE_SA_FILE"
  fi
  [ -f "$GDRIVE_SA_FILE" ] || die "service account file missing at $GDRIVE_SA_FILE (set GDRIVE_SERVICE_ACCOUNT_JSON secret)"
  : "${DRIVE_FOLDER_ID:?DRIVE_FOLDER_ID not set (secret)}"
  cat > "$RCLONE_CONFIG" <<EOF
[gdrive]
type = drive
service_account_file = $GDRIVE_SA_FILE
scope = drive
root_folder_id = $DRIVE_FOLDER_ID
EOF
}

# --- lease (lease.json lives in the shared Drive folder) ---
lease_read() {
  local lf=/tmp/lease/lease.json
  rm -rf /tmp/lease && mkdir -p /tmp/lease
  if rclone --config "$RCLONE_CONFIG" copy "${GDRIVE_REMOTE}${LEASE_PATH}" /tmp/lease/ >/dev/null 2>&1; then
    [ -f "$lf" ] && cat "$lf"
  fi
}

lease_upload() { rclone --config "$RCLONE_CONFIG" moveto "$1" "${GDRIVE_REMOTE}${LEASE_PATH}"; }

# lease_write <holder> <since> <heartbeat> <next> <run_id>
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
  # $1 holder, $2 run_id - refresh heartbeat, preserving since/next
  local holder="$1" run_id="${2:-}" cur since next
  cur="$(lease_read || true)"
  since="$(printf '%s' "$cur" | jq -r '.since // ""')"
  next="$(printf '%s' "$cur" | jq -r '.next // ""')"
  [ -n "$since" ] || since="$(now_iso)"
  lease_write "$holder" "$since" "$(now_iso)" "$next" "$run_id"
}