#!/usr/bin/env bash
# Comprehensive host backup: Docker images + volumes + home dir + pm2 state.
# Uploads a single host-backup.tar.gz to the configured storage backend
# (MinIO/S3 via rclone, or chunked GitHub release assets — see scripts/storage.sh).
#
# Fail soft on purpose: a step that fails is logged and the cycle continues.
# A partial backup that still gets uploaded is worth far more than a job that
# dies with nothing stored — and the job dying is exactly what used to happen
# (tar exits 1 on "file changed as we read it", and errexit killed the script).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
set +e   # belt & braces: a failing step must never kill the cycle

storage_setup

STAGE=/tmp/backup
rm -rf "$STAGE" && mkdir -p "$STAGE/images" "$STAGE/home"

# ── time budget ─────────────────────────────────────────────────────────────
# BACKUP_DEADLINE_EPOCH is the job's hard deadline, set by loop.sh.
# 0 (or unset) means "no deadline" — used for manual runs.
DEADLINE="${BACKUP_DEADLINE_EPOCH:-0}"
LEFT="$(time_left_sec "$DEADLINE")"
log "backup starting (time left: $(( LEFT / 60 )) min)"

# ── 1. PM2 process list ─────────────────────────────────────────────────────
if command -v pm2 &>/dev/null; then
  pm2 save 2>/dev/null || true
  PM2_DUMP=""
  for p in "/root/.pm2/dump.pm2" "$HOME/.pm2/dump.pm2" "/home/runner/.pm2/dump.pm2"; do
    if [ -f "$p" ]; then
      PM2_DUMP="$p"
      break
    fi
  done
  if [ -n "$PM2_DUMP" ]; then
    sudo cp "$PM2_DUMP" "$STAGE/pm2-dump" 2>/dev/null || cp "$PM2_DUMP" "$STAGE/pm2-dump" 2>/dev/null || true
    log "pm2 process list saved from $PM2_DUMP"
  else
    log "WARN: pm2 dump file not found"
  fi
fi

# ── 2. Docker images + container configs ────────────────────────────────────
if [ "${SKIP_DOCKER:-false}" = "true" ]; then
  log "SKIP_DOCKER=true; skipping Docker backup"
  RUNNING_CONTAINERS=""
else
  RUNNING_CONTAINERS="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
  if [ -n "$RUNNING_CONTAINERS" ]; then
    # Save full container configs (cheap — always worth doing)
    mkdir -p "$STAGE/containers"
    for c in $RUNNING_CONTAINERS; do
      log "saving config: $c"
      docker inspect "$c" > "$STAGE/containers/${c}.json" 2>/dev/null || true
    done

    for c in $RUNNING_CONTAINERS; do
      LEFT="$(time_left_sec "$DEADLINE")"
      if [ "$LEFT" -lt 180 ]; then
        log "WARN: only $(( LEFT / 60 )) min left — stopping docker image backup before $c"
        break
      fi
      IMAGE_TAG="backup-${c}"
      log "committing container $c -> $IMAGE_TAG"
      docker commit "$c" "$IMAGE_TAG" >/dev/null 2>&1 || { log "WARN: commit $c failed"; continue; }
      log "saving $IMAGE_TAG"
      # .part + rename: a failed save must never leave a half-written image
      # that restore.sh would try to load.
      if docker save "$IMAGE_TAG" 2>/dev/null | gzip -1 > "$STAGE/images/$c.tar.gz.part"; then
        mv "$STAGE/images/$c.tar.gz.part" "$STAGE/images/$c.tar.gz"
      else
        log "WARN: save $c failed"
        rm -f "$STAGE/images/$c.tar.gz.part"
      fi
      docker rmi "$IMAGE_TAG" 2>/dev/null || true
    done
    IMG_COUNT=$(find "$STAGE/images/" -name '*.tar.gz' 2>/dev/null | wc -l)
    log "docker images saved: $IMG_COUNT"
  else
    log "no running containers to back up"
  fi

  # ── 3. Docker volumes ─────────────────────────────────────────────────────
  # Always attempt this: the data-root path differs per install, so the old
  # "/var/lib/docker/volumes exists?" check silently skipped volumes.
  VOL_COUNT=0
  for vol in $(docker volume ls -q 2>/dev/null); do
    [ -z "$vol" ] && continue
    LEFT="$(time_left_sec "$DEADLINE")"
    if [ "$LEFT" -lt 120 ]; then
      log "WARN: only $(( LEFT / 60 )) min left — skipping remaining volumes"
      break
    fi
    log "saving volume $vol"
    if docker run --rm -v "$vol":/data:ro -v "$STAGE":/backup alpine \
        tar czf "/backup/vol-${vol}.tar.gz" -C / data 2>/dev/null; then
      VOL_COUNT=$(( VOL_COUNT + 1))
    else
      log "WARN: volume $vol skipped"
    fi
  done
  log "docker volumes saved: $VOL_COUNT"
fi

# ── 4. Root home directory (SSH logs in as root, not runner) ───────────────
ROOT_HOME="${BACKUP_ROOT_HOME:-/root}"
log "backing up root home directory from $ROOT_HOME"

HOME_EXCLUDES=()
while IFS= read -r x; do
  [ -n "$x" ] && HOME_EXCLUDES+=("$x")
done < <(backup_home_excludes)

# Size estimate with the same excludes, so it matches what is really archived.
# Capped: du on a huge tree must not eat the budget.
ROOT_BYTES="$(timeout 60 du -sx --block-size=1 "${HOME_EXCLUDES[@]}" "$ROOT_HOME" 2>/dev/null | cut -f1)"
EST_SEC=0
if [ -n "$ROOT_BYTES" ] && [ "$ROOT_BYTES" -gt 0 ] 2>/dev/null; then
  EST_SEC=$(( ROOT_BYTES / (HOME_TAR_MB_S * 1024 * 1024) ))
  log "home dir ~$(( ROOT_BYTES / 1024 / 1024 )) MiB, estimated tar time ~$(( EST_SEC / 60 )) min"
fi

LEFT="$(time_left_sec "$DEADLINE")"
SKIP_HOME=0
if [ "$LEFT" -lt 120 ]; then
  log "WARN: only $(( LEFT / 60 )) min left — skipping home directory"
  SKIP_HOME=1
elif [ "$EST_SEC" -gt 0 ] && [ "$EST_SEC" -gt $(( LEFT - 180 )) ]; then
  log "WARN: home backup needs ~$(( EST_SEC / 60 )) min but only $(( LEFT / 60 )) min left — skipping home directory"
  log "WARN: (docker images, containers and pm2 state are still backed up)"
  SKIP_HOME=1
fi

if [ "$SKIP_HOME" = "0" ]; then
  # Hard cap: never let the tar run past the deadline. A tar killed by
  # `timeout` leaves a truncated archive, so the result is written to .part
  # and only promoted to home.tar.gz when tar actually succeeded.
  TAR_LIMIT=$(( LEFT - 120 ))
  [ "$TAR_LIMIT" -gt 86400 ] && TAR_LIMIT=86400
  log "creating home.tar.gz (hard cap: ${TAR_LIMIT}s)"
  timeout --signal=TERM "$TAR_LIMIT" \
    sudo tar --warning=no-file-changed --ignore-failed-read -cf - \
    -C "$ROOT_HOME" "${HOME_EXCLUDES[@]}" . 2>"$STAGE/home-tar.err" \
    | gzip -1 > "$STAGE/home/home.tar.gz.part"
  TAR_RC="${PIPESTATUS[0]}"
  case "$TAR_RC" in
    0|1)
      # 0 = clean, 1 = warnings only ("file changed as we read it") — the
      # archive itself is valid and restorable.
      mv "$STAGE/home/home.tar.gz.part" "$STAGE/home/home.tar.gz"
      log "home directory saved ($(du -sh "$STAGE/home/home.tar.gz" 2>/dev/null | cut -f1))"
      ;;
    124)
      log "WARN: home tar hit the time limit — home directory skipped"
      rm -f "$STAGE/home/home.tar.gz.part"
      ;;
    *)
      log "WARN: home tar failed (exit $TAR_RC) — keeping partial archive"
      log "  tar said: $(head -3 "$STAGE/home-tar.err" 2>/dev/null | tr '\n' ';')"
      if [ -s "$STAGE/home/home.tar.gz.part" ]; then
        mv "$STAGE/home/home.tar.gz.part" "$STAGE/home/home.tar.gz"
      else
        rm -f "$STAGE/home/home.tar.gz.part"
      fi
      ;;
  esac
  [ -s "$STAGE/home-tar.err" ] && log "tar warnings: $(grep -c . "$STAGE/home-tar.err" 2>/dev/null) line(s)"
fi

# ── 5. Metadata ─────────────────────────────────────────────────────────────
jq -n \
  --arg ts "$(now_iso)" \
  --arg repo "$(self_repo)" \
  --arg run "${RUN_ID:-}" \
  --arg hostname "$(hostname)" \
  --arg containers "$RUNNING_CONTAINERS" \
  '{timestamp:$ts, repo:$repo, run_id:$run, hostname:$hostname, containers:$containers}' \
  > "$STAGE/meta.json"

# ── 6. Create single tarball ────────────────────────────────────────────────
ARTIFACT="host-backup.tar.gz"
log "creating $ARTIFACT"
INCLUDES=(meta.json)
[ -n "$(ls -A "$STAGE/images" 2>/dev/null)" ] && INCLUDES+=(images)
[ -n "$(ls -A "$STAGE/containers" 2>/dev/null)" ] && INCLUDES+=(containers)
[ -f "$STAGE/home/home.tar.gz" ] && INCLUDES+=(home)
[ -f "$STAGE/pm2-dump" ] && INCLUDES+=(pm2-dump)
# the volume archives live in the stage root — they were never included before
for v in "$STAGE"/vol-*.tar.gz; do
  [ -f "$v" ] && INCLUDES+=("$(basename "$v")")
done

tar -cf - -C "$STAGE" "${INCLUDES[@]}" | gzip -1 > "$STAGE/$ARTIFACT.part"
if [ "${PIPESTATUS[0]}" -ne 0 ] && [ ! -s "$STAGE/$ARTIFACT.part" ]; then
  log "ERROR: could not create $ARTIFACT — nothing to upload"
  exit 1
fi
mv "$STAGE/$ARTIFACT.part" "$STAGE/$ARTIFACT"
SIZE_BYTES="$(stat -c%s "$STAGE/$ARTIFACT" 2>/dev/null || echo 0)"
log "artifact ready: $ARTIFACT ($(( SIZE_BYTES / 1024 / 1024 )) MiB)"

# The staged copies are inside the artifact now — drop them so the upload
# (which needs a second full copy for the chunks) has room to breathe.
rm -rf "$STAGE/home" "$STAGE/images" "$STAGE/containers"
rm -f "$STAGE"/vol-*.tar.gz

# ── 7. Refuse oversized uploads, then upload ───────────────────────────────
if [ "$SIZE_BYTES" -gt $((MAX_BACKUP_GB * 1024 * 1024 * 1024)) ]; then
  log "ERROR: $ARTIFACT is $(( SIZE_BYTES / 1024 / 1024 )) MiB > MAX_BACKUP_GB=${MAX_BACKUP_GB}GB"
  log "ERROR: refusing to upload (previous backup left untouched)"
  log "ERROR: either raise the MAX_BACKUP_GB variable or trim what is stored under /root"
  exit 1
fi

AVAIL_KB="$(df -Pk /tmp 2>/dev/null | awk 'NR==2 {print $4}')"
NEED_KB=$(( SIZE_BYTES / 1024 + 65536 ))
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
  log "ERROR: not enough free space in /tmp ($(( AVAIL_KB / 1024 )) MiB free, need ~$(( NEED_KB / 1024 )) MiB)"
  log "ERROR: refusing to upload a truncated archive — previous backup left untouched"
  exit 1
fi

if storage_put_backup "$STAGE/$ARTIFACT"; then
  log "uploaded $ARTIFACT"
else
  log "ERROR: storage upload failed — previous backup left untouched"
  exit 1
fi

rm -rf "$STAGE"
log "backup complete"
