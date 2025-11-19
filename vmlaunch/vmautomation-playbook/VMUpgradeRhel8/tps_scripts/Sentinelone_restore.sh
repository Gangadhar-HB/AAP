#!/bin/bash

# === LOGGING SETUP ===
BACKUP_ROOT="/DGdata/sentinelone_backup_restore"
BACKUP_DIR="$BACKUP_ROOT/sentinelone"
mkdir -p "$BACKUP_DIR"
LOGFILE="$BACKUP_ROOT/sentinelone_restore_$(date +%F_%H-%M-%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

# === CONFIGURATION ===
S1_DIR="/opt/sentinelone"
SERVICE_FILE="/usr/lib/systemd/system/sentinelone.service"
INFO="INFO"
ERROR="ERROR"

# === HELPER ===
disp_msg() {
    echo "[$1] $2"
}

# === RESTORE PROCESS ===
restore_sentinelone() {
    disp_msg $INFO "Starting SentinelOne restore from backup in $BACKUP_DIR..."

    # Step 1: Modify service file temporarily to allow stop
    if grep -q "RefuseManualStop=yes" "$SERVICE_FILE"; then
        disp_msg $INFO "Temporarily allowing manual stop of SentinelOne service..."
        sed -i 's/RefuseManualStop=yes/#RefuseManualStop=yes/' "$SERVICE_FILE"
        systemctl daemon-reexec
        systemctl daemon-reload
    fi

    # Step 2: Stop and disable the service
    disp_msg $INFO "Stopping SentinelOne service..."
    systemctl stop sentinelone || disp_msg $ERROR "Failed to stop SentinelOne service"

    disp_msg $INFO "Disabling SentinelOne service..."
    systemctl disable sentinelone

    # Step 3: Rename old directory
    if [ -d "$S1_DIR" ]; then
        NEW_NAME="${S1_DIR}_old_$(date +%s)"
        disp_msg $INFO "Renaming existing $S1_DIR to $NEW_NAME"
        mv "$S1_DIR" "$NEW_NAME" || {
            disp_msg $ERROR "Failed to rename $S1_DIR"
            exit 1
        }
    fi

    # Step 4: Remove existing systemd service file if exists
    if [ -f "$SERVICE_FILE" ]; then
        disp_msg $INFO "Removing existing SentinelOne systemd service file"
        rm -f "$SERVICE_FILE"
        systemctl daemon-reexec
        systemctl daemon-reload
    fi

    # Step 5: Remove existing user/group if they exist
    if id "sentinelone" &>/dev/null; then
        disp_msg $INFO "Removing existing 'sentinelone' user"
        userdel -r sentinelone || disp_msg $ERROR "Failed to remove user 'sentinelone'"
    fi

    if getent group sentinelone &>/dev/null; then
        disp_msg $INFO "Removing existing 'sentinelone' group"
        groupdel sentinelone || disp_msg $ERROR "Failed to remove group 'sentinelone'"
    fi

    # Step 6: Install RPM from backup
    RPM_FILE=$(find "$BACKUP_ROOT" -maxdepth 1 -name "SentinelAgent_linux_x86_64_v*.rpm" | head -n 1)
    if [ -f "$RPM_FILE" ]; then
        disp_msg $INFO "Installing RPM from backup: $(basename "$RPM_FILE")"
        rpm -ivh --nodigest --nosignature "$RPM_FILE" || {
            disp_msg $ERROR "RPM installation failed"
            exit 1
        }
    else
        disp_msg $ERROR "RPM file not found in backup directory"
        exit 1
    fi

    # Step 7: Restore full directory
    if [ -d "$BACKUP_DIR" ]; then
        disp_msg $INFO "Restoring SentinelOne directory to $S1_DIR..."

        mkdir -p "$S1_DIR"
        rsync -a "$BACKUP_DIR/" "$S1_DIR/" || {
            disp_msg $ERROR "Failed to restore $S1_DIR"
            exit 1
        }

        chown -R sentinelone:sentinelone "$S1_DIR"
        chmod -R 755 "$S1_DIR"
    else
        disp_msg $ERROR "Backup directory not found at $BACKUP_DIR"
        exit 1
    fi

    # Step 8: Restore systemd service file
    if [ -f "$BACKUP_ROOT/sentinelone.service" ]; then
        disp_msg $INFO "Restoring sentinelone.service file..."
        cp -rp "$BACKUP_ROOT/sentinelone.service" "$SERVICE_FILE"
        systemctl daemon-reexec
        systemctl daemon-reload
    fi

    # Step 9: Restore user/group/passwd entries
    disp_msg $INFO "Restoring user/group entries..."

    if [ -f "$BACKUP_ROOT/passwd" ]; then
        while IFS= read -r line; do
            user=$(echo "$line" | cut -d: -f1)
            if ! grep -q "^$user:" /etc/passwd; then
                echo "$line" >> /etc/passwd
            fi
        done < "$BACKUP_ROOT/passwd"
    fi

    if [ -f "$BACKUP_ROOT/shadow" ]; then
        while IFS= read -r line; do
            user=$(echo "$line" | cut -d: -f1)
            if ! grep -q "^$user:" /etc/shadow; then
                echo "$line" >> /etc/shadow
            fi
        done < "$BACKUP_ROOT/shadow"
    fi

    if [ -f "$BACKUP_ROOT/group" ]; then
        while IFS= read -r line; do
            group=$(echo "$line" | cut -d: -f1)
            if ! grep -q "^$group:" /etc/group; then
                echo "$line" >> /etc/group
            fi
        done < "$BACKUP_ROOT/group"
    fi

    # Step 10: Re-enable and start service
    disp_msg $INFO "Re-enabling and starting SentinelOne service..."
    systemctl enable sentinelone
    systemctl start sentinelone
    systemctl status sentinelone

    disp_msg $INFO "SentinelOne restore completed successfully"
    disp_msg $INFO "Log saved to $LOGFILE"
}

# === MAIN ===
restore_sentinelone
