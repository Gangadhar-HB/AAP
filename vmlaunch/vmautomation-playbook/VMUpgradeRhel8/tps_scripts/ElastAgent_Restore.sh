#!/bin/bash

# Define the backup destination directory
BACKUP_DEST="/usr/local/etc/"
# Get the latest backup file
LATEST_BACKUP_FILE=$(ls -t "BACKUP_DEST/backup_elasticagent_*.tar.gz" | head -1)

# Check if there are any backup files
if [ -z "$LATEST_BACKUP_FILE" ]; then
 echo "No backup files found in $BACKUP_DEST"
 exit 1
fi

# Define the directories and files to restore
RESTORE_ITEMS=(
 "/opt/Elastic/Agent"
 "/opt/Elastic/Agent/elastic-agent.yml"
 "/etc/systemd/system/elastic-agent.service"
 "/etc/systemd/system/multi-user.target.wants/elastic-agent.service"
 "/opt/Elastic/Agent/elastic-agent"
 "/var/log/elastic-agent/elastic-agent.log"
 "/opt/Elastic/Agent/data/elastic-agent-8.13.4-a2e31a/components/filebeat"
)

# Perform the restore
tar -xzf "$LATEST_BACKUP_FILE" -C /

# Check if the restore was successful
if [ $? -eq 0 ]; then
 echo "Restore of specified ElasticAgent files and directories completed successfully from $LATEST_BACKUP_FILE"
else
 echo "Restore of specified ElasticAgent files and directories failed."
 exit 1
fi
