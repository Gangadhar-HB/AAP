#!/bin/bash

# === Configuration ===
# Main installation directory for Microsoft Defender for Endpoint
MDATP_DIR="/opt/microsoft/mdatp"
# Directory containing MDE configuration files
MDATP_CONFIG_DIR="/etc/opt/microsoft/mdatp"
# Root directory for all backup and restore operations
BACKUP_ROOT="/DGdata/mdatp_backup_restore"
# Specific directory within BACKUP_ROOT for MDE backups
BACKUP_DIR="$BACKUP_ROOT/mdatp"
# Path to the systemd service file for MDE
SERVICE_FILE="/usr/lib/systemd/system/mdatp.service" # Common path, adjust if yours is different (e.g., /etc/systemd/system/mdatp.service)
# Pattern for MDE RPM/package files (used for validation, not direct backup from system)
PACKAGE_NAME_PATTERN="mdatp" # General pattern for package manager checks
# Logfile for this script's execution
LOGFILE="$BACKUP_ROOT/mdatp_backup_$(date +%F_%H-%M-%S).log"

INFO="[INFO]"
WARN="[WARN]"
ERROR="[ERROR]"

# === Logging Setup ===
# Ensure the backup directory exists for logs and backups
mkdir -p "$BACKUP_DIR"
# Redirect all stdout and stderr to the logfile and also display on console
exec > >(tee -a "$LOGFILE") 2>&1

# Function to display messages with a prefix
disp_msg() {
    echo -e "$1 $2"
}

# --- STEP 1: Validate the installed MDE package ---
# Checks if the mdatp package is installed using either rpm (for RHEL/CentOS/Fedora) or dpkg (for Debian/Ubuntu)
validate_package() {
    disp_msg $INFO "Validating installed MDE package..."

    local INSTALLED_PACKAGE=""

    # Check for RPM-based systems
    if command -v rpm &> /dev/null; then
        INSTALLED_PACKAGE=$(rpm -qa | grep -i "$PACKAGE_NAME_PATTERN" | head -n 1)
        PACKAGE_MANAGER="RPM"
    else
        disp_msg $WARN "'rpm' package manager not  found. Cannot validate MDE installation."
        return
    fi

    if [[ -z "$INSTALLED_PACKAGE" ]]; then
        disp_msg $WARN "Microsoft Defender for Endpoint package is not currently installed on this system according to $PACKAGE_MANAGER."
        return
    fi

    disp_msg $INFO "Installed MDE package ($PACKAGE_MANAGER): $INSTALLED_PACKAGE"
    disp_msg $INFO "Package validation completed."
}

# --- STEP 2: Stop Microsoft Defender for Endpoint Safely ---
# Stops and disables the mdatp service
stop_mdatp() {
    disp_msg $INFO "Stopping Microsoft Defender for Endpoint agent..."

    # Check if the service file exists
    if [[ ! -f "$SERVICE_FILE" ]]; then
        disp_msg $WARN "MDE service file not found at $SERVICE_FILE. Cannot stop service."
        return
    fi

    # Check if the mdatp service is active
    if systemctl is-active --quiet mdatp; then
        if ! systemctl stop mdatp; then
            disp_msg $ERROR "Failed to stop mdatp service. Please check systemctl status mdatp."
            exit 1
        fi
        disp_msg $INFO "MDE service 'mdatp' stopped successfully."
    else
        disp_msg $WARN "MDE service 'mdatp' is not active. Skipping stop operation."
    fi

    disp_msg $INFO "Disabling MDE service 'mdatp'..."
    if ! systemctl disable mdatp; then
        disp_msg $WARN "Failed to disable mdatp service. This might not be critical for backup but note it."
    else
        disp_msg $INFO "MDE service 'mdatp' disabled."
    fi

    systemctl daemon-reload # Reload systemd daemons after any service changes
}

# --- STEP 3: Create Backup of MDE Directories and Configuration ---
# Backs up the main MDE directory, configuration directory, service file, and user/group entries
create_backup() {
    disp_msg $INFO "Creating backup at $BACKUP_ROOT..."

    # Clean up previous backup content in BACKUP_DIR but keep the root directory for logs
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR" || {
        disp_msg $ERROR "Failed to create backup directory $BACKUP_DIR"
        exit 1
    }

    disp_msg $INFO "Backing up $MDATP_DIR (excluding 'log' and 'tmp')..."

    # Use tar for a more robust backup, preserving permissions and ownership
    # FIX: Corrected tar command to place --exclude options before the source directory
    if [[ -d "$MDATP_DIR" ]]; then
        tar -czf "$BACKUP_DIR/mdatp_main_dir.tar.gz" \
            --exclude='log' \
            --exclude='tmp' \
            -C "$(dirname "$MDATP_DIR")" "$(basename "$MDATP_DIR")" \
            || { disp_msg $ERROR "Failed to backup $MDATP_DIR"; exit 1; }
        disp_msg $INFO "Backup of $MDATP_DIR completed."
    else
        disp_msg $WARN "Main MDE directory $MDATP_DIR not found. Skipping its backup."
    fi

    disp_msg $INFO "Backing up $MDATP_CONFIG_DIR..."
    if [[ -d "$MDATP_CONFIG_DIR" ]]; then
        tar -czf "$BACKUP_DIR/mdatp_config_dir.tar.gz" -C "$(dirname "$MDATP_CONFIG_DIR")" \
            "$(basename "$MDATP_CONFIG_DIR")" \
            || { disp_msg $ERROR "Failed to backup $MDATP_CONFIG_DIR"; exit 1; }
        disp_msg $INFO "Backup of $MDATP_CONFIG_DIR completed."
    else
        disp_msg $WARN "MDE configuration directory $MDATP_CONFIG_DIR not found. Skipping its backup."
    fi

    # Backup the service file if it exists
    if [[ -f "$SERVICE_FILE" ]]; then
        cp -rp "$SERVICE_FILE" "$BACKUP_ROOT/mdatp.service"
        disp_msg $INFO "Backed up MDE service file: $(basename "$SERVICE_FILE")"
    else
        disp_msg $WARN "MDE service file $SERVICE_FILE not found. Skipping service file backup."
    fi

    # Backup user/group entries related to MDE
    disp_msg $INFO "Backing up MDE user/group entries..."
    grep -i '^mdatp' /etc/passwd > "$BACKUP_ROOT/passwd_mdatp"
    grep -i '^mdatp' /etc/shadow > "$BACKUP_ROOT/shadow_mdatp"
    grep -i '^mdatp' /etc/group  > "$BACKUP_ROOT/group_mdatp"
    # Ensure shadow file backup has restricted permissions
    chmod 600 "$BACKUP_ROOT/shadow_mdatp"
    disp_msg $INFO "MDE user/group entries backed up."

    disp_msg $INFO "Backup completed successfully to $BACKUP_ROOT."
}

# === MAIN Execution ===
disp_msg $INFO "Starting Microsoft Defender for Endpoint backup..."
disp_msg $INFO "Log file: $LOGFILE"
disp_msg $INFO "--------------------------------------------------"

validate_package
disp_msg $INFO "--------------------------------------------------"
stop_mdatp
disp_msg $INFO "--------------------------------------------------"
create_backup
disp_msg $INFO "--------------------------------------------------"
disp_msg $INFO "Microsoft Defender for Endpoint backup script finished."