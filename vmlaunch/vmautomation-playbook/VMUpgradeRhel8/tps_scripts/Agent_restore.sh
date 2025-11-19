#!/bin/bash
# auditbeat_restore.sh
# Final restore script for auditbeat (fully featured)
# - installs RPM (if present), handles already-installed case
# - stops/disables service, renames old dirs, removes unit files
# - extracts backup, restores passwd/group/shadow, reapplies enablement (absent -> enable)
# - logs to BACKUP_ROOT/restore_logs/
#
# Usage:
#   sudo ./auditbeat_restore.sh [--file PATH_TO_TAR] [--dry-run] [--no-start]

set -euo pipefail
IFS=$'\n\t'

BACKUP_ROOT="/DGdata/auditbeat_backup_restore"
DRY_RUN=false
NO_START=false
TAR_PATH=""
SERVICE_NAME="auditbeat.service"

# Directories to rename if present (adjust as required)
TARGET_DIRS=(
  "/usr/share/auditbeat"
  "/opt/Elastic/Agent/elastic-agent"
  "/opt/Elastic/Agent/data"
)

# Candidate systemd unit files to remove before install
SERVICE_FILES=(
  "/etc/systemd/system/auditbeat.service"
  "/usr/lib/systemd/system/auditbeat.service"
)

usage() {
  cat <<EOF
Usage: $0 [--file PATH_TO_TAR] [--dry-run] [--no-start] [--help]

  --file PATH_TO_TAR   Path to a specific backup tar.gz
  --dry-run            Show actions but make no changes
  --no-start           Do not start/restart auditbeat.service after restore
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) TAR_PATH="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --no-start) NO_START=true; shift;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

BACKUP_ROOT="${BACKUP_ROOT%/}"
LOG_DIR="${BACKUP_ROOT}/restore_logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/restore_auditbeat_$(date +%Y%m%d%H%M%S).log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') : $*" | tee -a "$LOG_FILE"; }

log "----- Starting auditbeat restore -----"
log "Backup root: $BACKUP_ROOT"
[ "$DRY_RUN" = true ] && log "DRY RUN mode enabled"

#
# Determine selected folder & tar
#
if [ -n "$TAR_PATH" ]; then
  if [ ! -f "$TAR_PATH" ]; then
    log "ERROR: specified tar not found: $TAR_PATH"; exit 1
  fi
  SELECTED_TAR="$TAR_PATH"
  SELECTED_FOLDER="$(dirname "$TAR_PATH")"
else
  if [ -L "${BACKUP_ROOT}/latest" ] && [ -d "${BACKUP_ROOT}/latest" ]; then
    SELECTED_FOLDER="$(readlink -f "${BACKUP_ROOT}/latest")"
  else
    SELECTED_FOLDER=$(ls -1dt "${BACKUP_ROOT}"/backup_auditbeat_* 2>/dev/null | head -n1 || true)
  fi
  if [ -z "$SELECTED_FOLDER" ] || [ ! -d "$SELECTED_FOLDER" ]; then
    log "ERROR: no backup folder found in ${BACKUP_ROOT}"; exit 1
  fi
  SELECTED_TAR=$(ls -1t "${SELECTED_FOLDER}"/backup_auditbeat_*.tar.gz 2>/dev/null | head -n1 || true)
fi

if [ -z "${SELECTED_TAR:-}" ] || [ ! -f "$SELECTED_TAR" ]; then
  log "ERROR: backup tar not found in folder: ${SELECTED_FOLDER:-unknown}"; exit 1
fi

log "Selected folder: $SELECTED_FOLDER"
log "Selected tar: $SELECTED_TAR"

#
# Verify checksum (if present)
#
if [ -f "${SELECTED_TAR}.sha256" ] && command -v sha256sum >/dev/null 2>&1; then
  log "Verifying checksum: ${SELECTED_TAR}.sha256"
  if sha256sum -c "${SELECTED_TAR}.sha256" --status; then
    log "Checksum OK"
  else
    log "ERROR: checksum verification failed"; exit 1
  fi
else
  log "No checksum file or sha256sum missing; continuing"
fi

#
# Step: Stop and disable the service
#
log "[STEP] Stopping and disabling ${SERVICE_NAME} (if present)"
if [ "$DRY_RUN" = true ]; then
  log "[DRY RUN] systemctl stop ${SERVICE_NAME} ; systemctl disable ${SERVICE_NAME}"
else
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      log "Stopping ${SERVICE_NAME}"
      systemctl stop "$SERVICE_NAME" || log "WARN: failed to stop ${SERVICE_NAME}"
    else
      log "${SERVICE_NAME} not active"
    fi
    log "Disabling ${SERVICE_NAME}"
    systemctl disable "$SERVICE_NAME" || log "WARN: systemctl disable returned non-zero"
  else
    log "${SERVICE_NAME} unit file not present; skipping stop/disable"
  fi
fi

#
# Step: Rename old directories (if present)
#
log "[STEP] Renaming existing install directories (if present)"
TS_NOW=$(date +%s)
for d in "${TARGET_DIRS[@]}"; do
  if [ -d "$d" ]; then
    NEW_NAME="${d}_old_${TS_NOW}"
    if [ "$DRY_RUN" = true ]; then
      log "[DRY RUN] would run: mv \"$d\" \"$NEW_NAME\""
    else
      log "Renaming $d -> $NEW_NAME"
      if mv "$d" "$NEW_NAME"; then
        log "Renamed $d -> $NEW_NAME"
      else
        log "ERROR: failed to rename $d to $NEW_NAME"; exit 1
      fi
    fi
  else
    log "Not present: $d"
  fi
done

#
# Step: Remove existing systemd service file(s) if exist
#
log "[STEP] Removing existing systemd unit files if present"
DID_REMOVE_UNIT=0
for svcfile in "${SERVICE_FILES[@]}"; do
  if [ -f "$svcfile" ]; then
    if [ "$DRY_RUN" = true ]; then
      log "[DRY RUN] would remove $svcfile"
      DID_REMOVE_UNIT=1
    else
      log "Removing $svcfile"
      rm -f "$svcfile" || log "WARN: failed to remove $svcfile"
      DID_REMOVE_UNIT=1
    fi
  fi
done

if [ "$DID_REMOVE_UNIT" -eq 1 ]; then
  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] would run: systemctl daemon-reexec ; systemctl daemon-reload"
  else
    log "Re-execing and reloading systemd"
    systemctl daemon-reexec || log "WARN: daemon-reexec failed"
    systemctl daemon-reload || log "WARN: daemon-reload failed"
  fi
fi

#
# Step: Install auditbeat RPM (preferred: selected folder -> BACKUP_ROOT)
#
install_auditbeat_rpm() {
  local RPM_TO_INSTALL=""
  # Prefer RPM inside selected folder
  if compgen -G "${SELECTED_FOLDER}/auditbeat*.rpm" >/dev/null 2>&1; then
    RPM_TO_INSTALL=$(ls -1 "${SELECTED_FOLDER}"/auditbeat*.rpm | head -n1)
  elif compgen -G "${BACKUP_ROOT}/auditbeat*.rpm" >/dev/null 2>&1; then
    RPM_TO_INSTALL=$(ls -1 "${BACKUP_ROOT}"/auditbeat*.rpm | head -n1)
  fi

  if [ -z "$RPM_TO_INSTALL" ]; then
    log "[RPM] No auditbeat RPM found in ${SELECTED_FOLDER} or ${BACKUP_ROOT}"
    return 1
  fi

  log "[RPM] Candidate RPM: $(basename "$RPM_TO_INSTALL")"

  # Query NEVRA from the RPM file (package identity)
  NEW_PKG="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$RPM_TO_INSTALL" 2>/dev/null || true)"
  if [ -n "$NEW_PKG" ]; then
    log "[RPM] RPM provides package: $NEW_PKG"
    # If exact package is already installed, skip reinstall
    if rpm -q "$NEW_PKG" >/dev/null 2>&1; then
      log "[RPM] Package $NEW_PKG is already installed -> skipping rpm -ivh"
      return 0
    fi
  else
    log "[RPM] Could not determine package NEVRA from RPM file (continuing to attempt install)"
  fi

  # Attempt install with rpm -ivh --nodigest (as requested). If it fails, try rpm -Uvh --oldpackage as fallback.
  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] would run: rpm -ivh --nodigest \"$RPM_TO_INSTALL\""
    return 0
  fi

  log "[RPM] Running: rpm -ivh --nodigest \"$RPM_TO_INSTALL\""
  if rpm -ivh --nodigest "$RPM_TO_INSTALL"; then
    log "[RPM] rpm -ivh succeeded"
    return 0
  else
    log "[RPM] rpm -ivh failed — attempting rpm -Uvh --oldpackage --nodigest as fallback"
    if rpm -Uvh --oldpackage --nodigest "$RPM_TO_INSTALL"; then
      log "[RPM] rpm -Uvh --oldpackage succeeded"
      return 0
    else
      log "[RPM] ERROR: RPM installation failed (both -i and -U attempts)"; return 2
    fi
  fi
}

if ! install_auditbeat_rpm; then
  # If return was 1 => no rpm found; return 2 => install failure. We continue if no rpm found by choice.
  rc=$?
  if [ $rc -eq 2 ]; then
    log "ERROR: RPM install failed -> aborting restore"; exit 1
  else
    log "No RPM installed; continuing restore (you may want to provide the RPM in ${BACKUP_ROOT})"
  fi
fi

#
# Preview & extraction
#
log "Archive preview (first 40 entries):"
tar -tzf "$SELECTED_TAR" | head -n 40 | sed 's/^/   /' | tee -a "$LOG_FILE"

if [ "$DRY_RUN" = true ]; then
  log "DRY RUN: would extract $SELECTED_TAR to /"
  exit 0
fi

# Ensure service not running
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Stopping ${SERVICE_NAME} (pre-extract)"
    systemctl stop "$SERVICE_NAME" || log "WARN: failed to stop ${SERVICE_NAME}"
  fi
fi

log "Extracting ${SELECTED_TAR} to / (overwrites existing files with same paths)"
if tar -xzf "$SELECTED_TAR" -C / 2>>"$LOG_FILE"; then
  log "Extraction completed"
else
  log "ERROR: extraction failed (see $LOG_FILE)"; exit 1
fi

#
# Restore optional user/group/shadow files
#
PASSWD_FILE="${SELECTED_FOLDER}/passwd.auditbeat"
GROUP_FILE="${SELECTED_FOLDER}/group.auditbeat"
SHADOW_FILE="${SELECTED_FOLDER}/shadow.auditbeat"

if [ -f "$GROUP_FILE" ]; then
  log "Restoring group entries from $GROUP_FILE"
  while IFS= read -r line; do
    grp=$(echo "$line" | cut -d: -f1)
    if ! getent group "$grp" >/dev/null 2>&1; then
      echo "$line" >> /etc/group
      log "Appended group $grp"
    fi
  done < "$GROUP_FILE"
fi

if [ -f "$PASSWD_FILE" ]; then
  log "Restoring passwd entries from $PASSWD_FILE"
  while IFS= read -r line; do
    user=$(echo "$line" | cut -d: -f1)
    if ! getent passwd "$user" >/dev/null 2>&1; then
      echo "$line" >> /etc/passwd
      log "Appended passwd entry for $user"
    fi
  done < "$PASSWD_FILE"
fi

if [ -f "$SHADOW_FILE" ]; then
  log "Restoring shadow entries from $SHADOW_FILE"
  while IFS= read -r line; do
    user=$(echo "$line" | cut -d: -f1)
    if ! grep -q "^${user}:" /etc/shadow 2>/dev/null; then
      echo "$line" >> /etc/shadow
      log "Appended shadow entry for $user"
    fi
  done < "$SHADOW_FILE"
  chmod 600 /etc/shadow || true
fi

#
# Reapply enablement state (treat 'absent' as 'enabled' so service becomes enabled after restore)
#
ENABLE_STATE_FILE="${SELECTED_FOLDER}/service_enablement.txt"
if [ -f "$ENABLE_STATE_FILE" ]; then
  state=$(tr -d '[:space:]' < "$ENABLE_STATE_FILE" || echo "")
  log "Reapplying saved enablement state: '$state'"
  case "$state" in
    enabled)
      log "Enabling ${SERVICE_NAME}"
      systemctl enable "$SERVICE_NAME" || log "WARN: enable failed"
      ;;
    disabled)
      log "Disabling ${SERVICE_NAME}"
      systemctl disable "$SERVICE_NAME" || log "WARN: disable failed"
      ;;
    absent)
      log "Saved state was 'absent' — enabling ${SERVICE_NAME} by default"
      systemctl enable "$SERVICE_NAME" || log "WARN: enable failed"
      ;;
    *)
      log "Unknown saved state: '$state' — no enable/disable changes made"
      ;;
  esac
else
  log "No saved enablement file found in backup — skipping enable/disable step"
fi

# Ensure systemd sees new units
log "Reloading systemd daemon"
systemctl daemon-reload || log "WARN: daemon-reload failed"

#
# Final: start service unless suppressed
#
if [ "$NO_START" = false ]; then
  log "Starting ${SERVICE_NAME}"
  if systemctl start "$SERVICE_NAME"; then
    log "${SERVICE_NAME} started successfully"
  else
    log "WARN: failed to start ${SERVICE_NAME}; dumping journal tail"
    journalctl -u "$SERVICE_NAME" --no-pager | tail -n 100 | sed 's/^/   /' | tee -a "$LOG_FILE"
  fi
else
  log "--no-start specified: not starting ${SERVICE_NAME}"
fi

log "----- Restore completed -----"
