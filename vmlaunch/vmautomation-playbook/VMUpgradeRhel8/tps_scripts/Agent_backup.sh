#!/bin/bash
# auditbeat_backup.sh
# Fully loaded backup script for auditbeat.

set -euo pipefail
IFS=$'\n\t'

# -----------------------------
BACKUP_ROOT="/DGdata/auditbeat_backup_restore"
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
RETENTION_COUNT=5
SERVICE_NAME="auditbeat.service"
STOP_SERVICE=false
DRY_RUN=false

BACKUP_ITEMS=(
  "/etc/auditbeat"
  "/etc/auditbeat/auditbeat.yml"
  "/usr/lib/systemd/system/auditbeat.service"
  "/opt/Elastic/Agent/elastic-agent"
  "/var/log/elastic-agent/elastic-agent.log"
  "/opt/Elastic/Agent/data/elastic-agent-*/components/filebeat"
)

usage() {
  cat <<EOF
Usage: $0 [--retain N] [--stop-service] [--dry-run] [--help]

  --retain N        Number of backup folders to keep (default: ${RETENTION_COUNT})
  --stop-service    Stop ${SERVICE_NAME} during backup
  --dry-run         Show actions but do not create archive
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --retain) RETENTION_COUNT="$2"; shift 2;;
    --stop-service) STOP_SERVICE=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

mkdir -p "$BACKUP_ROOT"
BACKUP_FOLDER="${BACKUP_ROOT}/backup_auditbeat_${TIMESTAMP}"
mkdir -p "$BACKUP_FOLDER"
LOG_FILE="${BACKUP_FOLDER}/backup_auditbeat_${TIMESTAMP}.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') : $*" | tee -a "$LOG_FILE"; }

log "----- Starting auditbeat backup -----"
log "Backup root: $BACKUP_ROOT"
log "Backup folder: $BACKUP_FOLDER"
log "Retention: keep $RETENTION_COUNT"
[ "$DRY_RUN" = true ] && log "DRY RUN mode enabled"

# Save service enablement state
ENABLE_STATE_FILE="${BACKUP_FOLDER}/service_enablement.txt"
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
  if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    echo "enabled" > "$ENABLE_STATE_FILE"
  else
    echo "disabled" > "$ENABLE_STATE_FILE"
  fi
  log "Saved service enablement state: $(cat "$ENABLE_STATE_FILE")"
else
  echo "absent" > "$ENABLE_STATE_FILE"
  log "${SERVICE_NAME} not present — wrote 'absent'"
fi

# Detect installed rpm and copy matching one from BACKUP_ROOT
validate_and_copy_rpm() {
  log "[RPM] Checking installed RPM..."
  INSTALLED_RPM=$(rpm -qa | grep -i auditbeat | head -n1 || true)
  if [[ -z "$INSTALLED_RPM" ]]; then
    log "[RPM] No auditbeat RPM installed"
    return
  fi
  log "[RPM] Installed: $INSTALLED_RPM"

  VERSION_RAW=$(echo "$INSTALLED_RPM" | sed -nE 's/^auditbeat-([0-9][^ ]*)/\1/p' || true)
  if [[ -z "$VERSION_RAW" ]]; then
    log "[RPM] WARN: could not parse version"
    return
  fi
  VERSION_UNDER=$(echo "$VERSION_RAW" | tr '.' '_')
  VERSION_BASE=${VERSION_RAW%%-*}
  log "[RPM] Parsed version: $VERSION_RAW (alt: $VERSION_UNDER, base: $VERSION_BASE)"

  FOUND_RPM=""
  for pat in \
    "auditbeat*${VERSION_RAW}*.rpm" \
    "auditbeat*${VERSION_UNDER}*.rpm" \
    "auditbeat*${VERSION_BASE}*.rpm"; do
    if compgen -G "${BACKUP_ROOT}/${pat}" >/dev/null 2>&1; then
      FOUND_RPM=$(ls -1 "${BACKUP_ROOT}"/${pat} | head -n1)
      break
    fi
  done

  if [[ -n "$FOUND_RPM" ]]; then
    log "[RPM] Found matching RPM: $FOUND_RPM"
    cp -p "$FOUND_RPM" "$BACKUP_FOLDER/" && log "[RPM] Copied into backup folder"
  else
    log "[RPM] WARN: No matching RPM found in $BACKUP_ROOT"
  fi
}
validate_and_copy_rpm

# Stop service if requested
if [ "$STOP_SERVICE" = true ]; then
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Stopping $SERVICE_NAME"
    systemctl stop "$SERVICE_NAME" || log "WARN: failed to stop $SERVICE_NAME"
  fi
fi

# Collect files
TMPLIST=$(mktemp)
FOUND=0
for pattern in "${BACKUP_ITEMS[@]}"; do
  if compgen -G "$pattern" >/dev/null; then
    while IFS= read -r match; do
      [ -e "$match" ] || continue
      echo "$match" >> "$TMPLIST"
      log "Including: $match"
      FOUND=1
    done < <(compgen -G "$pattern")
  else
    log "Missing: $pattern"
  fi
done
if [ "$FOUND" -eq 0 ]; then
  log "ERROR: no files found to backup"
  rm -f "$TMPLIST"
  exit 1
fi

# Create manifest + archive
BACKUP_FILE="${BACKUP_FOLDER}/backup_auditbeat_${TIMESTAMP}.tar.gz"
MANIFEST="${BACKUP_FOLDER}/backup_auditbeat_${TIMESTAMP}.manifest.txt"

{
  echo "Backup manifest for $BACKUP_FILE"
  echo "Created: $(date --iso-8601=seconds)"
  echo ""
  echo "Included items:"
  sed 's/^/  /' "$TMPLIST"
} > "$MANIFEST"

if [ "$DRY_RUN" = true ]; then
  log "DRY RUN: would create $BACKUP_FILE"
else
  log "Creating archive..."
  tar -czf "$BACKUP_FILE" -T "$TMPLIST" 2>>"$LOG_FILE"
  sha256sum "$BACKUP_FILE" > "${BACKUP_FILE}.sha256"
  log "Archive and checksum created"
  ln -sfn "$BACKUP_FOLDER" "${BACKUP_ROOT}/latest"
  log "Updated latest symlink"
fi

rm -f "$TMPLIST"

# Restart + re-enable service if we stopped it
if [ "$STOP_SERVICE" = true ]; then
  SAVED_STATE=$(cat "$ENABLE_STATE_FILE" 2>/dev/null || echo "unknown")
  if [ "$SAVED_STATE" = "enabled" ]; then
    log "Re-enabling and starting $SERVICE_NAME"
    systemctl enable "$SERVICE_NAME" || log "WARN: enable failed"
    systemctl start "$SERVICE_NAME" || log "WARN: start failed"
  elif [ "$SAVED_STATE" = "disabled" ]; then
    log "Starting $SERVICE_NAME (was disabled at boot)"
    systemctl start "$SERVICE_NAME" || log "WARN: start failed"
  else
    log "Unknown prior state ($SAVED_STATE) — just starting"
    systemctl start "$SERVICE_NAME" || true
  fi
fi

# Retention cleanup
log "Applying retention (keep $RETENTION_COUNT)"
cd "$BACKUP_ROOT"
ls -1dt backup_auditbeat_* 2>/dev/null | tail -n +$((RETENTION_COUNT+1)) | while read -r old; do
  [ -d "$old" ] && { log "Removing old: $old"; rm -rf "$old"; }
done

log "----- Backup completed -----"
