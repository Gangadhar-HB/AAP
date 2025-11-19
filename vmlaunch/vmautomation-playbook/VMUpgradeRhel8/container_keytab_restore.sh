#!/bin/bash

export HOME=/root
LOGFILE=/DGlogs/container_keytab_generation.log
cluster_id=$1
ARGCOUNT=$#
([ "$#" != 1 ] || [ $cluster_id -gt 2  ] || [ $cluster_id == 0 ] ) && echo -e "Usage for keytab restore: $0 <Cluster ID>" && echo -e "Usage for keytab restore: $0 <Cluster ID>" >>$LOGFILE 2>>$LOGFILE && exit 1

count=0
confile=/etc/kodiakEMS.conf
TTPath=/opt/TimesTen/kodiak/bin
ROOT_DIR=/DG/activeRelease/container/VMUpgradeRhel8
ALL_VARS=$ROOT_DIR/playbooks/group_vars/all
INVENTORY_PRE="$ROOT_DIR/inventory"

echo "     ###########################################################     "   >>$LOGFILE 2>>$LOGFILE
echo "     ########KEYTAB RESTORE IN ROLLED BACK CONTAINERS###########     "   >>$LOGFILE 2>>$LOGFILE
echo "     ###########################################################     "   >>$LOGFILE 2>>$LOGFILE
echo "`date +%x_%H:%M:%S:%3N`: cluster_id: $cluster_id " >>$LOGFILE 2>>$LOGFILE
SourceConfig()
{
    if [ ! -s ${confile} ]; then
        echo "`date +%x_%H:%M:%S:%3N`: ${confile}  do not exists!! Hence exiting..." |tee -a $LOGFILE
        exit 0
    fi

    source $confile >>$LOGFILE 2>>$LOGFILE
    export LD_LIBRARY_PATH=/opt/TimesTen/kodiak/lib:$LD_LIBRARY_PATH
    echo "`date +%x_%H:%M:%S:%3N`: Local EMSIP: $EMSIP" >>$LOGFILE
}

SourceConfig

# Variables (adjust as needed)
host_vars="./host_vars"
INVENTORY="${INVENTORY_PRE}_keytab_$cluster_id"

# Declare associative array for hostlist
declare -A hostlist

generate_list_of_containers() {
    local ip_address="$1"
    local container_list=()

    # Get all CONTAINER_SIGCARDID for the given HOSTIP
    local sig_ids
    sig_ids=$($TTPath/ttIsql -connStr "dsn=$DATASTORENAME;uid=$EMSUSERID;pwd=$EMSPASSWORD" \
        -e "SELECT CONTAINER_SIGCARDID FROM DG.CONTAINER_CONFIGVALUES \
            WHERE PARAMNAME='HOSTIP' AND PARAMVALUE='$ip_address';exit;" \
        -v 1 2>>"$LOGFILE" | sed 's/[<>]//g' | sed 's/ *//g')

    # Loop through each SIGCARDID
    for sigid in $sig_ids; do
        # Fetch PROJECT, IMAGE, HOSTIP, PTTSERVERID, HOST
        local query_result
        query_result=$($TTPath/ttIsql -connStr "dsn=$DATASTORENAME;uid=$EMSUSERID;pwd=$EMSPASSWORD" \
            -e "SELECT PARAMVALUE FROM DG.CONTAINER_CONFIGVALUES \
                WHERE PARAMNAME IN ('PROJECT', 'IMAGE', 'HOSTIP', 'PTTSERVERID', 'HOST') \
                AND CONTAINER_SIGCARDID=$sigid;exit;" \
            -v 1 2>>"$LOGFILE" | sed 's/[<>]//g' | sed 's/ *//g')

        # Convert query_result into an array
        local values=()
        while IFS= read -r line; do
            [ -n "$line" ] && values+=("$line")
        done <<< "$query_result"

        # Make sure we have at least 5 results
        if [ "${#values[@]}" -ge 5 ]; then
            local proj="${values[0]}"
            local image="${values[2]}"
            local hostip="${values[1]}"
            local pttserverid="${values[3]}"
            local host="${values[4]}"

            # Extract image tag
            local image_tag="${image##*:}"

            # Build container name
            local containername="${pttserverid}-${proj}-${host}-${image_tag}"
            container_list+=("$containername")
        fi
    done

    # Assign to associative array for the IP
    hostlist["$ip_address"]="${container_list[*]}"

    # Call inventory generation function (if implemented)
    generate_inventory "$ip_address"
}

# Function to generate inventory files from hostlist
generate_inventory() {

    # Create/Clean host_vars
    if [ ! -d "$host_vars" ]; then
        mkdir -p "$host_vars"
        echo "Created directory: $host_vars"
    else
        rm -f "$host_vars"/*
        echo "Cleaned directory: $host_vars"
    fi

    # Remove existing inventory file
    if [ -f "$INVENTORY" ]; then
        rm -f "$INVENTORY"
        echo "Removed existing inventory file: $INVENTORY"
    fi

    # Write nodes section
    {
        echo "[vm_cont]"
        for ip in "${!hostlist[@]}"; do
            echo "$ip"
        done
    } > "$INVENTORY"

    # Create host_vars files
    for hostip in "${!hostlist[@]}"; do
        hostfile="$host_vars/$hostip"
        {
            echo "containers:"
            for container in ${hostlist[$hostip]}; do
                echo "  - $container"
            done
        } > "$hostfile"
        echo "Updated $hostfile with containers: ${hostlist[$hostip]}"
    done
}

ValidateVMIP()
{
    # SQL to fetch VM IPs
    VMIPS="select DISTINCT(PARAMVALUE) from DG.CONTAINER_CONFIGVALUES where ( CONTAINER_SIGCARDID,CONTAINER_TYPE ) in (select CONTAINER_SIGCARDID,CONTAINER_TYPE from DG.CONTAINER_CONFIGVALUES where PARAMNAME='CLUSTERID' and PARAMVALUE=$cluster_id) and PARAMNAME='HOSTIP';"

    # Execute SQL and clean output
    VMIP_LIST=$($TTPath/ttIsql \
        -connStr "dsn=$DATASTORENAME;uid=$EMSUSERID;pwd=$EMSPASSWORD" \
        -e "$VMIPS;exit;" -v 1 2>> "$LOGFILE" \
        | sed 's/< *//g' | sed 's/ *>//g' | sed 's/ *//g')

    # If no IPs found, log and exit
    if [ -z "$VMIP_LIST" ]; then
        echo "$(date +%x_%H:%M:%S:%3N): Failed to fetch VMIPS!!" >> "$LOGFILE"
        exit 1
    fi

    # Append to hostlist (assuming it's a bash associative array)
    for ip in $VMIP_LIST; do
        if [ -z "${hostlist[$ip]}" ]; then
            hostlist[$ip]=""   # initialize empty entry
        fi

        echo "$ip" >> "$INVENTORY"

        generate_list_of_containers "$ip"

    done

    # Optional log
    echo "$(date +%x_%H:%M:%S:%3N): Added VM IPs to hostlist: $VMIP_LIST" >> "$LOGFILE"
}

INVENTORY="${INVENTORY_PRE}_keytab_$cluster_id"
declare -A hostlist

ValidateVMIP

echo "`date +%x_%H:%M:%S:%3N`: Inventory file for Cluster  $cluster_id ">>$LOGFILE 2>>$LOGFILE
echo "`cat $INVENTORY`" >>$LOGFILE 2>>$LOGFILE
cd $ROOT_DIR >>$LOGFILE 2>>$LOGFILE
echo "====================================================================================" >>$LOGFILE 2>>$LOGFILE
echo "`date +%x_%H:%M:%S:%3N`: Executing Keytab Restore Playbook for cluster $cluster_id" >>$LOGFILE 2>>$LOGFILE
echo "====================================================================================" >>$LOGFILE 2>>$LOGFILE
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8
export ANSIBLE_LOG_PATH=/DGlogs/keytab_restore_ansible.log

ansible-playbook -i $INVENTORY $ROOT_DIR/playbooks/keytab_restore.yml -vv  >>$LOGFILE 2>>$LOGFILE
if [ $? -eq 0 ]; then
   echo "`date +%x_%H:%M:%S:%3N`: Keytab restoration is successful for Cluster $cluster_id" >>$LOGFILE
   [ -s "$INVENTORY" ] && rm -vf $INVENTORY >>$LOGFILE
else
    echo "`date +%x_%H:%M:%S:%3N`: Keytab restore failed for cluster $cluster_id" >>$LOGFILE
    exit 1
fi
exit 0
