#!/usr/bin/env bash
# Storage backends for the relay.
#
#   minio      -> rclone against any S3-compatible endpoint (MinIO, AWS, ...)
#   ghrelease  -> chunked backup uploaded as assets of a GitHub release on a
#                 private storage repo, reassembled on the next round
#   auto       -> ghrelease when STORAGE_REPO_PAT is set, else minio
#
# Sourced by scripts/lib.sh — do not execute.

# ---------- dispatch -------------------------------------------------------
storage_backend() {
  case "${STORAGE_BACKEND:-auto}" in
    minio|ghrelease) echo "${STORAGE_BACKEND}" ;;
    auto)            if [ -n "${STORAGE_REPO_PAT:-}" ]; then echo ghrelease; else echo minio; fi ;;
    *)               die "unknown STORAGE_BACKEND='${STORAGE_BACKEND}' (use auto|minio|ghrelease)" ;;
  esac
}

storage_setup() { case "$(storage_backend)" in
  ghrelease) ghrelease_setup ;;
  minio)     minio_setup ;;
esac; }

# $1 = local tarball to upload (atomic: new backup is verified+published before the old one is deleted)
storage_put_backup() { case "$(storage_backend)" in
  ghrelease) ghrelease_put_backup "$1" ;;
  minio)     minio_put_backup "$1" ;;
esac; }

# $1 = destination dir. Echoes the assembled/verified backup filename, or nothing if no backup exists.
storage_fetch_latest_backup() { case "$(storage_backend)" in
  ghrelease) ghrelease_fetch_latest_backup "$1" ;;
  minio)     minio_fetch_latest_backup "$1" ;;
esac; }

# ============================================================================
# minio / rclone (S3-compatible)
# ============================================================================
minio_setup() {
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

minio_put_backup() {
  local file="$1"
  rclone --config "$RCLONE_CONFIG" delete "${BACKUP_REMOTE}$(basename "$file")" 2>/dev/null || true
  rclone --config "$RCLONE_CONFIG" copy "$file" "${BACKUP_REMOTE}" || return 1
  # clean any leftover old-format backups
  rclone --config "$RCLONE_CONFIG" lsf "${BACKUP_REMOTE}" 2>/dev/null | grep -v "^$(basename "$file")\$" | \
    grep '\.tar\.gz$' | while read -r f; do
      [ -n "$f" ] && rclone --config "$RCLONE_CONFIG" delete "${BACKUP_REMOTE}$f" && log "pruned old format: $f"
    done || true
}

minio_fetch_latest_backup() {
  local dest="$1" latest
  latest="$(rclone --config "$RCLONE_CONFIG" lsf "${BACKUP_REMOTE}" 2>/dev/null | grep '^host-backup\.tar\.gz$' | head -1 || true)"
  [ -n "$latest" ] || return 0
  rclone --config "$RCLONE_CONFIG" copy "${BACKUP_REMOTE}${latest}" "$dest/" || return 1
  echo "$latest"
}

minio_lease_read() {
  local lf=/tmp/lease/lease.json
  rm -rf /tmp/lease && mkdir -p /tmp/lease
  if rclone --config "$RCLONE_CONFIG" copy "${BUCKET_ROOT}${LEASE_PATH}" /tmp/lease/ >/dev/null 2>&1; then
    [ -f "$lf" ] && cat "$lf"
  fi
}

minio_lease_write() { rclone --config "$RCLONE_CONFIG" moveto "$1" "${BUCKET_ROOT}${LEASE_PATH}"; }

# ============================================================================
# ghrelease (chunked assets on a private GitHub repo)
# ============================================================================
# NOTE: every call passes GH_TOKEN explicitly instead of exporting it, so a
# caller's own GH_TOKEN (e.g. watchdog.yml's GITHUB_TOKEN used to reboot
# vps.yml) is never shadowed by the storage PAT.
ghs() { GH_TOKEN="$STORAGE_REPO_PAT" GH_REPO="$STORAGE_REPO" gh "$@"; }

ghrelease_setup() {
  : "${STORAGE_REPO:?STORAGE_REPO not set (secret) — e.g. OtherAccount/vps-relay-storage}"
  : "${STORAGE_REPO_PAT:?STORAGE_REPO_PAT not set (secret) — fine-grained PAT, Contents: Read and write, scoped to STORAGE_REPO}"

  # Fail with a *useful* message. Printing the raw value would just come back as
  # '***' from GitHub if it happens to equal another secret, so validate the
  # shape instead of echoing it.
  case "$STORAGE_REPO" in
    github_pat_*|ghp_*|gho_*|ghu_*|ghs_*|ghr_*)
      die "STORAGE_REPO holds a token, not a repo path — set STORAGE_REPO to 'owner/name' (e.g. Francis261/hsjsjsjehrhbackup) and the token only in STORAGE_REPO_PAT" ;;
  esac
  case "$STORAGE_REPO" in
    ?*/?*) ;;
    *) die "STORAGE_REPO must be 'owner/name' but contains no '/'. A MinIO bucket name like 'vps-relay' belongs in S3_BUCKET, not here." ;;
  esac

  command -v gh >/dev/null 2>&1 || die "gh CLI not found (preinstalled on GitHub-hosted runners)"

  local reached
  # '|| true' matters: pipefail + errexit would kill the script silently before
  # die() gets to explain what went wrong
  reached="$(ghs api "repos/$STORAGE_REPO" --jq .full_name 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]' || true)"
  [ "$reached" = "$(printf '%s' "$STORAGE_REPO" | tr '[:upper:]' '[:lower:]')" ] || \
    die "cannot reach storage repo '$STORAGE_REPO' with STORAGE_REPO_PAT. Check that (a) the repo exists, (b) the PAT has Contents: Read and write, and (c) the PAT's Repository access includes that repo."
}

ghrelease_latest_backup_tag() {
  # newest published release whose tag starts with the backup prefix
  # (grep guards against gh api printing an error body to stdout)
  ghs api "repos/$STORAGE_REPO/releases?per_page=100" \
    --jq "[.[] | select((.draft == false) and (.tag_name | startswith(\"${BACKUP_TAG_PREFIX}\")) and (.assets | length > 0))]
          | sort_by(.created_at) | reverse | .[0].tag_name // empty" 2>/dev/null | \
    grep "^${BACKUP_TAG_PREFIX}" | head -1 || true
}

ghrelease_release_id_by_tag() {   # works for drafts too (tag ref doesn't exist until publish)
  ghs api "repos/$STORAGE_REPO/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"$1\") | .id" 2>/dev/null | grep -E '^[0-9]+$' | head -1 || true
}

ghrelease_gc_drafts() {
  # Orphan drafts left by a killed upload (6h runner cap). Never touches published backups.
  local id tag created now age
  now="$(now_epoch)"
  ghs api "repos/$STORAGE_REPO/releases?per_page=100" \
    --jq '.[] | select(.draft) | "\(.id) \(.tag_name) \(.created_at)"' 2>/dev/null | \
  while read -r id tag created; do
    [ -n "$id" ] || continue
    age=$(( (now - $(date -u -d "$created" +%s 2>/dev/null || echo "$now")) / 3600 ))
    if [ "$age" -ge "${STORAGE_KEEP_DRAFT_HOURS:-2}" ]; then
      ghs api -X DELETE "repos/$STORAGE_REPO/releases/$id" >/dev/null 2>&1 && log "gc'd orphan draft release $tag (age ${age}h)"
    fi
  done
}

ghrelease_put_backup() {   # $1 = tarball path
  local file="$1" stage=/tmp/ghrel-put
  local total_bytes parts tag old_tag total_sha chunks_json f

  rm -rf "$stage" && mkdir -p "$stage"
  total_bytes="$(stat -c%s "$file")"

  # hard guards — refuse instead of blowing the 6h window / 1000-asset cap
  [ "$total_bytes" -gt 0 ] || die "backup is empty — refusing to upload"
  if [ "$total_bytes" -gt $((MAX_BACKUP_GB * 1024 * 1024 * 1024)) ]; then
    die "backup is ${total_bytes} bytes > MAX_BACKUP_GB=${MAX_BACKUP_GB}GB — refusing to upload (old backup left untouched)"
  fi
  parts=$(( (total_bytes + CHUNK_BYTES - 1) / CHUNK_BYTES ))
  if [ "$parts" -gt "$MAX_CHUNKS" ]; then
    die "backup needs ${parts} chunks > MAX_CHUNKS=${MAX_CHUNKS} — refusing to upload (old backup left untouched)"
  fi

  log "chunking $(basename "$file") ($((total_bytes / 1024 / 1024)) MiB) into $parts chunk(s) of $((CHUNK_BYTES / 1024 / 1024)) MiB"
  split -b "$CHUNK_BYTES" -a 4 --numeric-suffixes=0 "$file" "$stage/chunk_"

  (cd "$stage" && sha256sum chunk_* > SHA256SUMS)
  total_sha="$(sha256sum "$file" | awk '{print $1}')"
  chunks_json="$(jq -Rn '[inputs | split("  ") | {sha256: .[0], name: .[1]}]' < "$stage/SHA256SUMS")"
  jq -n --arg ts "$(now_iso)" --arg src "$(self_repo)" --arg run "${RUN_ID:-}" \
        --arg total_sha "$total_sha" --arg chunks "$chunks_json" \
        --argjson chunk_bytes "$CHUNK_BYTES" --argjson parts "$parts" --argjson total_bytes "$total_bytes" \
    '{version: 1, created_at: $ts, source_repo: $src, run_id: $run,
      chunk_bytes: $chunk_bytes, parts: $parts, total_bytes: $total_bytes,
      sha256: $total_sha, chunks: ($chunks | fromjson)}' > "$stage/manifest.json"

  old_tag="$(ghrelease_latest_backup_tag)"
  tag="${BACKUP_TAG_PREFIX}$(date -u +%Y%m%dT%H%M%SZ)"

  # 1. draft (invisible) → 2. upload → 3. verify → 4. publish → 5. delete old
  ghs release create "$tag" --repo "$STORAGE_REPO" --draft --title "vps backup $tag" \
      --notes-file "$stage/manifest.json" >/dev/null || die "could not create draft release $tag"

  log "uploading $((parts + 1)) asset(s) to draft release $tag"
  # a single 1.5 GiB PUT can hiccup; --clobber makes retries idempotent
  local up_tries=0 up_ok=""
  while [ "$up_tries" -lt 3 ] && [ -z "$up_ok" ]; do
    up_tries=$((up_tries + 1))
    if ( cd "$stage" && ghs release upload "$tag" --repo "$STORAGE_REPO" --clobber manifest.json chunk_* ); then
      up_ok=1
    else
      log "WARN: asset upload attempt $up_tries failed; retrying in 20s"
      sleep 20
    fi
  done
  [ -n "$up_ok" ] || \
    die "asset upload failed after $up_tries attempt(s) — draft left for GC, previous backup ($old_tag) still intact"

  ghrelease_verify_assets "$tag" "$stage" || \
    die "post-upload verification failed — draft left for GC, previous backup ($old_tag) still intact"

  ghs release edit "$tag" --repo "$STORAGE_REPO" --draft=false >/dev/null || die "publishing $tag failed"
  log "published $tag ($parts chunk(s), $((total_bytes / 1024 / 1024)) MiB)"

  ghrelease_gc_drafts

  # only now is the previous generation removed
  if [ -n "$old_tag" ]; then
    ghs release delete "$old_tag" --repo "$STORAGE_REPO" --yes --cleanup-tag >/dev/null 2>&1 && \
      log "deleted previous backup $old_tag (+tag)" || \
      log "WARN: could not delete previous backup $old_tag — will retry next cycle"
  fi
  rm -rf "$stage"
}

ghrelease_verify_assets() {   # $1 = tag, $2 = local staging dir
  local tag="$1" stage="$2" remote expected id
  id="$(ghrelease_release_id_by_tag "$tag")"
  [ -n "$id" ] || { log "ERROR: release $tag not found"; return 1; }

  remote="$(ghs api "repos/$STORAGE_REPO/releases/$id" \
    --jq '.assets[] | select(.state == "uploaded") | "\(.name) \(.size)"' | sort)"
  expected="$(cd "$stage" && for f in manifest.json chunk_*; do echo "$f $(stat -c%s "$f")"; done | sort)"

  if [ "$remote" != "$expected" ]; then
    log "ERROR: uploaded assets do not match the local set"
    log "  expected: $(echo "$expected" | tr '\n' ';')"
    log "  remote:   $(echo "$remote" | tr '\n' ';')"
    return 1
  fi
  log "verified $(echo "$remote" | wc -l) asset(s) on $tag (names + sizes match)"
}

ghrelease_fetch_latest_backup() {   # $1 = dest dir → echoes filename of verified tarball
  local dest="$1" tag manifest parts i name sha f
  tag="$(ghrelease_latest_backup_tag)"
  [ -n "$tag" ] || return 0

  log "restoring from backup release $tag"
  ghs release download "$tag" --repo "$STORAGE_REPO" --pattern 'manifest.json' --dir "$dest" --clobber || return 1
  manifest="$dest/manifest.json"

  parts="$(jq -r '.parts // 0' "$manifest")"
  [ "$parts" -ge 1 ] || { log "ERROR: manifest has no parts"; return 1; }
  [ "$parts" -le "$MAX_CHUNKS" ] || { log "ERROR: manifest claims $parts chunks > MAX_CHUNKS=$MAX_CHUNKS"; return 1; }
  [ "$(jq -r '.chunks | length' "$manifest")" -eq "$parts" ] || { log "ERROR: manifest chunk list is inconsistent"; return 1; }

  log "downloading $parts chunk(s) from $tag"
  local tries=0 ok=""
  while [ "$tries" -lt 3 ] && [ -z "$ok" ]; do
    tries=$((tries + 1))
    ghs release download "$tag" --repo "$STORAGE_REPO" --pattern 'chunk_*' --dir "$dest" --clobber >/dev/null 2>&1 && ok=1
    [ -n "$ok" ] || { log "WARN: chunk download attempt $tries failed; retrying in 15s"; sleep 15; }
  done
  [ -n "$ok" ] || { log "ERROR: could not download chunks"; return 1; }

  # verify every chunk against the manifest before touching anything
  while read -r sha name; do
    f="$dest/$name"
    if [ ! -f "$f" ]; then log "ERROR: missing chunk $name"; return 1; fi
    if [ "$(sha256sum "$f" | awk '{print $1}')" != "$sha" ]; then
      log "ERROR: sha256 mismatch for $name — refusing to assemble a corrupt backup"
      return 1
    fi
  done < <(jq -r '.chunks[] | "\(.sha256) \(.name)"' "$manifest")

  # assemble in numeric order and verify the whole archive
  log "reassembling $(basename "$dest")/host-backup.tar.gz from $parts chunk(s)"
  # shellcheck disable=SC2046  # chunk names are chunk_0000.., safe to word-split
  ( cd "$dest" && cat $(ls chunk_* | sort) > host-backup.tar.gz ) || { log "ERROR: reassembly failed"; return 1; }
  if [ "$(sha256sum "$dest/host-backup.tar.gz" | awk '{print $1}')" != "$(jq -r '.sha256' "$manifest")" ]; then
    log "ERROR: reassembled archive sha256 mismatch — refusing to restore"
    rm -f "$dest/host-backup.tar.gz"   # never leave a bad tarball for restore.sh to extract
    return 1
  fi
  rm -f "$dest"/chunk_* "$manifest"
  log "backup verified (total sha256 ok)"
  echo "host-backup.tar.gz"
}

# lease lives in the body of a permanent 'state' release (1 GET to read, 1 PATCH to write)
ghrelease_lease_read() {
  # pull the whole release JSON first: the lease body is multi-line, so it
  # must not be line-filtered
  local out
  out="$(ghs api "repos/$STORAGE_REPO/releases/tags/${STATE_TAG}" 2>/dev/null)" || return 0
  printf '%s' "$out" | jq -r '.body // empty' 2>/dev/null || true
}

ghrelease_lease_write() {   # $1 = lease json file
  local id body
  body="$(cat "$1")"
  id="$(ghs api "repos/$STORAGE_REPO/releases/tags/${STATE_TAG}" --jq .id 2>/dev/null | grep -E '^[0-9]+$' | head -1 || true)"
  if [ -n "$id" ]; then
    ghs api -X PATCH "repos/$STORAGE_REPO/releases/$id" -f body="$body" --jq .id >/dev/null 2>&1 || return 1
  else
    ghs release create "${STATE_TAG}" --repo "$STORAGE_REPO" --title "vps-relay lease" \
      --notes-file "$1" --latest=false >/dev/null 2>&1 || return 1
  fi
}
