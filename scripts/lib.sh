#!/usr/bin/env bash
# Shared helpers for the relay-VPS scripts. Source me, do not execute.
#
# NOTE: never enable `set -e` in this file. It is sourced by scripts that
# deliberately run *without* errexit (backup.sh, loop.sh, handoff.sh,
# restore.sh) so that a failing step is logged and the cycle continues.
# A sourced `set -e` leaks into the caller and aborts the whole script on
# the first non-zero command — that is exactly how backups died silently at
# the `tar` step (tar exits 1 on "file changed as we read it").
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- configurable env (defaults sensible for GitHub Actions) ---
: "${RCLONE_CONFIG:=/tmp/rclone.conf}"
: "${STORAGE_BACKEND:=auto}"      # auto | minio | ghrelease (auto = ghrelease iff STORAGE_REPO_PAT is set)
: "${HOLD_TIMEOUT_MIN:=45}"
: "${HEARTBEAT_INTERVAL_MIN:=5}"
: "${KEEP_BACKUPS:=1}"

# --- job time budget ---
# JOB_TIMEOUT_MIN must match the workflow's timeout-minutes; the job is killed
# hard at JOB_START_EPOCH + JOB_TIMEOUT_MIN. BACKUP_BUDGET_MIN is the slice
# of the window reserved for backup + upload — the hold yields to it.
: "${JOB_TIMEOUT_MIN:=360}"
: "${BACKUP_BUDGET_MIN:=45}"
: "${HOME_TAR_MB_S:=12}"           # conservative throughput estimate for the home tar
: "${JOB_START_EPOCH:=0}"         # job start time, exported by the workflow

# minio backend
: "${S3_REMOTE:=minio:}"          # rclone remote name created by minio_setup
: "${S3_BUCKET:=vps-relay}"       # bucket that holds backups + the lease
: "${BUCKET_ROOT:=${S3_REMOTE}${S3_BUCKET}/}"
: "${BACKUP_REMOTE:=${BUCKET_ROOT}backups/}"
: "${LEASE_PATH:=lease.json}"

# ghrelease backend (chunked GitHub release assets on a private repo)
: "${STORAGE_REPO:=}"             # owner/name of the private backup repo
: "${STORAGE_REPO_PAT:=}"         # fine-grained PAT, Contents: Read and write, scoped to STORAGE_REPO
: "${CHUNK_BYTES:=1610612736}"    # 1.5 GiB per chunk (GitHub caps release assets at 2 GiB)
: "${MAX_CHUNKS:=998}"            # GitHub allows 1000 assets per release
: "${MAX_BACKUP_GB:=50}"          # refuse to upload anything bigger than this
: "${BACKUP_TAG_PREFIX:=b-}"
: "${STATE_TAG:=state}"           # permanent release whose body holds the lease
: "${STORAGE_KEEP_DRAFT_HOURS:=2}" # GC orphan drafts left by a killed upload

# storage backends live next to us
source "$(dirname "${BASH_SOURCE[0]}")/storage.sh"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

now_epoch() { date +%s; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- job deadline ---
# The workflow exports JOB_START_EPOCH in its first step; the job is killed
# hard at JOB_START_EPOCH + JOB_TIMEOUT_MIN. Everything that must finish
# (backup + upload + handoff) is planned backwards from that moment.
job_deadline_epoch() {
  local start="${JOB_START_EPOCH:-0}"
  case "$start" in ''|*[!0-9]*) start=0 ;; esac
  [ "$start" -gt 0 ] || start="$(now_epoch)"
  echo $(( start + JOB_TIMEOUT_MIN * 60 ))
}

# Seconds left until the deadline (huge number when there is no deadline).
time_left_sec() {
  local deadline="${1:-0}"
  case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac
  if [ "$deadline" -le 0 ]; then echo 9999999; return 0; fi
  echo $(( deadline - $(now_epoch) ))
}

self_repo() { echo "${GITHUB_REPOSITORY:-unknown/unknown}"; }

# --- mustBackup.json helpers (v2) ---
must_jq() { jq -r "$1" "$REPO_ROOT/mustBackup.json" 2>/dev/null || echo "$2"; }
handoff_after_min()     { must_jq '.handoff_after_min // 270' 270; }
tunnel_hostname()       { must_jq '.tunnel.hostname // ""' ""; }
tunnel_host_hostname()  { must_jq '.tunnel.host_hostname // ""' ""; }
tunnel_uuid()           { must_jq '.tunnel.tunnel_uuid // ""' ""; }

# Backup exclusion list — JSON array (mustBackup.json) + always-on built-ins.
# Built-ins cover the volatile/huge dirs that must never be archived (npm and
# pm2 logs change while tar reads them, which makes tar exit 1).
backup_home_excludes() {
  {
    jq -r '.backup.home_exclude[]? // empty' "$REPO_ROOT/mustBackup.json" 2>/dev/null
    printf '%s\n' \
      .cache .npm .yarn node_modules .nvm go .cargo .rustup .gradle .m2 .android \
      .vscode-server .vscode .config/Code .local/share/Trash .local/share/pnpm \
      .local/share/flatpak .ansible/collections .azure .dotnet .ghcup \
      .pm2/logs .pm2/pm2.log
  } | sort -u | while IFS= read -r pat; do
      [ -n "$pat" ] && echo "--exclude=$pat"
    done
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

# --- lease (backend decides where it lives: bucket root or a 'state' release body) ---
lease_read() { case "$(storage_backend)" in
  ghrelease) ghrelease_lease_read ;;
  minio)     minio_lease_read ;;
esac; }

lease_write() {
  local lf=/tmp/lease-write.json
  jq -n --arg h "$1" --arg s "$2" --arg hb "$3" --arg n "$4" --arg r "$5" \
    '{holder:$h,since:$s,heartbeat:$hb,next:$n,run_id:$r}' > "$lf"
  case "$(storage_backend)" in
    ghrelease) ghrelease_lease_write "$lf" ;;
    minio)     minio_lease_write "$lf" ;;
  esac
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
