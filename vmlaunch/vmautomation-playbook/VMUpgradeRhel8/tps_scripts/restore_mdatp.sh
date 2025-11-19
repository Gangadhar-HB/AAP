#!/bin/bash

# === Configuration ===
BACKUP_ROOT="/DGdata/mdatp_backup_restore"
# Logfile for this script's execution
LOGFILE="$BACKUP_ROOT/mdatp_restore_rpm_$(date +%F_%H-%M-%S).log"

INFO="[INFO]"
WARN="[WARN]"
ERROR="[ERROR]"

# === Logging Setup ===
# Ensure the backup directory exists for logs
mkdir -p "$BACKUP_ROOT"
# Redirect all stdout and stderr to the logfile and also display on console
exec > >(tee -a "$LOGFILE") 2>&1

# Function to display messages with a prefix
disp_msg() {
    echo -e "$1 $2"
}

# --- MAIN RESTORATION SCRIPT (RPM Only) ---
restore_mdatp_rpm() {
    disp_msg $INFO "Starting Microsoft Defender for Endpoint RPM-only restore..."
    disp_msg $INFO "Restore log: $LOGFILE"
    disp_msg $INFO "--------------------------------------------------"

    # --- Step 1: Validate Backup Files ---
    MDE_PACKAGE=$(find "$BACKUP_ROOT" -maxdepth 1 -name "mdatp*.rpm" | head -n 1)
    if [ -z "$MDE_PACKAGE" ] || [ ! -f "$MDE_PACKAGE" ]; then
        disp_msg $ERROR "MDE RPM package file not found in backup directory."
        exit 1
    fi

    ONBOARDING_FILE=$(find "$BACKUP_ROOT" -maxdepth 1 -name "MicrosoftDefenderATPOnboardingLinuxServer.json" | head -n 1)
    if [ -z "$ONBOARDING_FILE" ] || [ ! -f "$ONBOARDING_FILE" ]; then
        disp_msg $ERROR "Onboarding file 'MicrosoftDefenderATPOnboardingLinuxServer.json' not found in backup directory."
        exit 1
    fi

    disp_msg $INFO "Backup files validated. Found:"
    disp_msg $INFO "  - Package: $(basename "$MDE_PACKAGE")"
    disp_msg $INFO "  - Onboarding File: $(basename "$ONBOARDING_FILE")"
    disp_msg $INFO "--------------------------------------------------"

    # --- Step 2: Stop and Uninstall the Existing MDE Package ---
    disp_msg $INFO "Stopping and uninstalling any existing MDE package..."
    systemctl stop mdatp || disp_msg $WARN "Failed to stop MDE service. Continuing uninstall."
    systemctl disable mdatp || disp_msg $WARN "Failed to disable MDE service. Continuing uninstall."

    if ! rpm -q mdatp &> /dev/null; then
        disp_msg $WARN "MDE package is not currently installed. Skipping uninstall."
    else
        rpm -e mdatp || { disp_msg $ERROR "RPM uninstall failed. Aborting."; exit 1; }
        disp_msg $INFO "Existing MDE package uninstalled successfully."
    fi
    disp_msg $INFO "--------------------------------------------------"

    # --- Step 3: Install the MDE Package from Backup ---
    disp_msg $INFO "Installing MDE package from backup: $(basename "$MDE_PACKAGE")"
    rpm -ivh "$MDE_PACKAGE" || { disp_msg $ERROR "RPM installation failed. Aborting."; exit 1; }
    disp_msg $INFO "MDE package installed successfully."
    disp_msg $INFO "--------------------------------------------------"

    # --- Step 4: Re-onboard the Device ---
    disp_msg $INFO "Re-onboarding MDE using backed-up configuration..."
    mdatp edr onboard --json "$ONBOARDING_FILE" || { disp_msg $ERROR "Failed to onboard MDE. Aborting."; exit 1; }
    disp_msg $INFO "MDE onboarded successfully."
    disp_msg $INFO "--------------------------------------------------"
    
    # --- Step 5: Start and Enable the Service ---
    disp_msg $INFO "Enabling and starting MDE service..."
    systemctl enable mdatp
    systemctl start mdatp
    
    # --- Step 6: Final Status Check ---
    disp_msg $INFO "MDE restore script finished."
    disp_msg $INFO "Checking MDE service status..."
    systemctl status mdatp
    
    disp_msg $INFO "For a full health check, run 'sudo mdatp health' manually."
    disp_msg $INFO "Log saved to $LOGFILE"
}

# === MAIN Execution ===
restore_mdatp_rpm