#!/bin/bash

# === Configuration ===
S1_DIR="/opt/sentinelone"
BACKUP_ROOT="/DGdata/sentinelone_backup_restore"
BACKUP_DIR="$BACKUP_ROOT/sentinelone"
SERVICE_FILE="/usr/lib/systemd/system/sentinelone.service"
RPM_PATTERN="SentinelAgent_linux_x86_64_v*.rpm"
LOGFILE="$BACKUP_ROOT/sentinelone_backup_$(date +%F_%H-%M-%S).log"

INFO="[INFO]"
ERROR="[ERROR]"

# === Logging Setup ===
mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$LOGFILE") 2>&1

disp_msg() {
    echo -e "$1 $2"
}

# === STEP 1: Validate that the installed SentinelOne version matches a file in the backup folder ===
validate_rpm() {
    echo "[INFO] Validating installed RPM against backup directory..."

    # Get installed RPM name
    INSTALLED_RPM=$(rpm -qa | grep -i sentinelagent | head -n 1)

    if [[ -z "$INSTALLED_RPM" ]]; then
        echo "[WARN] SentinelOne RPM is not currently installed on this system."
        return
    fi

    echo "[INFO] Installed SentinelOne RPM: $INSTALLED_RPM"

    # Extract version (e.g., 25.1.3.6) from RPM string like SentinelAgent-25.1.3.6-1.x86_64
    VERSION_RAW=$(echo "$INSTALLED_RPM" | sed -E 's/.*[Ss]entinel[Aa]gent-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*/\1/')

    if [[ -z "$VERSION_RAW" ]]; then
        echo "[WARN] Unable to parse version from installed RPM name."
        return
    fi

    # Convert to format used in RPM filename (25.1.3.6 → 25_1_3_6)
    VERSION_FMT=$(echo "$VERSION_RAW" | tr '.' '_')

    # Build expected RPM filename
    RPM_FILENAME="SentinelAgent_linux_x86_64_v${VERSION_FMT}.rpm"
    RPM_PATH="$BACKUP_ROOT/$RPM_FILENAME"

    if [[ -f "$RPM_PATH" ]]; then
        echo "[INFO] Matching RPM found in backup directory: $RPM_FILENAME"
    else
        echo "[WARN] Expected RPM $RPM_FILENAME not found in $BACKUP_ROOT"
        echo "       This might affect restoration if RPM is needed. Proceeding anyway."
    fi
}

# === STEP 2: Stop SentinelOne Safely ===
stop_sentinelone() {
    disp_msg $INFO "Modifying SentinelOne service file to allow manual stop..."

    if grep -q '^RefuseManualStop=yes' "$SERVICE_FILE"; then
        sed -i 's/^RefuseManualStop=yes/#RefuseManualStop=yes/' "$SERVICE_FILE"
        disp_msg $INFO "Commented out 'RefuseManualStop=yes' in $SERVICE_FILE"
        systemctl daemon-reexec
        systemctl daemon-reload
    fi

    disp_msg $INFO "Stopping SentinelOne agent..."
    if ! systemctl stop sentinelone; then
        disp_msg $ERROR "Failed to stop sentinelone service"
        exit 1
    fi

    disp_msg $INFO "Disabling SentinelOne service..."
    systemctl disable sentinelone

    if grep -q '^#RefuseManualStop=yes' "$SERVICE_FILE"; then
        sed -i 's/^#RefuseManualStop=yes/RefuseManualStop=yes/' "$SERVICE_FILE"
        disp_msg $INFO "Restored 'RefuseManualStop=yes' in $SERVICE_FILE"
        systemctl daemon-reexec
        systemctl daemon-reload
    fi
}

# === STEP 3: Backup Directory with cpio ===
create_backup() {
    disp_msg $INFO "Creating backup at $BACKUP_ROOT..."

    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR" || {
        disp_msg $ERROR "Failed to create backup directory"
        exit 1
    }

    disp_msg $INFO "Backing up $S1_DIR (excluding 'log' and 'mount/osnoise')..."

    cd "$S1_DIR" || {
        disp_msg $ERROR "Failed to access $S1_DIR"
        exit 1
    }

    find . \
        -path "./log" -prune -o \
        -path "./mount/osnoise" -prune -o \
        -print | cpio -pdmu "$BACKUP_DIR" 2>/dev/null

    if [ $? -ne 0 ]; then
        disp_msg $ERROR "Backup copy failed"
        exit 1
    fi

    # Backup the service file
    if [ -f "$SERVICE_FILE" ]; then
        cp -rp "$SERVICE_FILE" "$BACKUP_ROOT/sentinelone.service"
    fi

    # Backup user/group entries
    grep -i '^sentinelone' /etc/passwd > "$BACKUP_ROOT/passwd"
    grep -i '^sentinelone' /etc/shadow > "$BACKUP_ROOT/shadow"
    grep -i '^sentinelone' /etc/group  > "$BACKUP_ROOT/group"
    chmod 600 "$BACKUP_ROOT/shadow"

    disp_msg $INFO "Backup completed successfully"
}

# === MAIN ===
disp_msg $INFO "Starting SentinelOne backup..."
validate_rpm
stop_sentinelone
create_backup
