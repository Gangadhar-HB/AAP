#!/bin/bash

# Define the directories and files to backup
BACKUP_ITEMS=(
 "/opt/Elastic/Agent"
 "/opt/Elastic/Agent/elastic-agent.yml"
 "/etc/systemd/system/elastic-agent.service"
 "/etc/systemd/system/multi-user.target.wants/elastic-agent.service"
 "/opt/Elastic/Agent/elastic-agent"
 "/var/log/elastic-agent/elastic-agent.log"
 "/opt/Elastic/Agent/data/elastic-agent-8.13.4-a2e31a/components/filebeat"
)

# Define the backup destination directory
BACKUP_DEST="/usr/local/etc"
# Get the current date and time for the backup filename
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
# Define the backup filename
BACKUP_FILE="$BACKUP_DEST/backup_elasticagent_$TIMESTAMP.tar.gz"

# Create the backup directory if it doesn't exist
mkdir -p "$BACKUP_DEST"

# Define the service name
SERVICE_NAME="elastic-agent.service"

if systemctl is-active --quiet "$SERVICE_NAME";then
 # Perform the backup
 tar -czf "$BACKUP_FILE" "${BACKUP_ITEMS[@]}"
else
 echo "elastic-agent.service is not running currently."
fi

# Check if the backup was successful
if [ $? -eq 0 ]; then
 echo "Backup of specified elastic-agent.service files and directories completed successfully. Backup file: $BACKUP_FILE"
else
 echo "Backup of specified mdatp files and directories failed."
 exit 1
fi