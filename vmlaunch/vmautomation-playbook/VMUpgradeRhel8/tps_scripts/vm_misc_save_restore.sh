#!/bin/bash
#
#
# Purpose:
#   Save Kodiak VM configuration data to thin pool storage and
#   restore configuration data from thin pool storage.
#
#
# Description:
#   This script saves pertinent '/etc' configuration data to
#   folder '/usr/local/etc' located in the Kodiak VM's thin pool 
#   storage. It also restores configuration data from thin pool
#   storage.
#
#
# Notes:
#
#
# Author:
#   Greg Morton
#
#
# History:
#
# 

#/usr/local/bin/contentinfo
# Version:
VERSION="2024-11-21"



SCRIPT_NAME="$(basename $0)"
EXTENSION=$( date +%Y%m%d%H%M%S )
TMP_FILE="/dev/null"
LOOP_TIME_OUT=60
MAX_LOOP_CNT=40
LOOP_DELAY=5


# Create temporary directory to store debug information
TMP_DIR=$( mkdir -p /tmp/scripts && mktemp -d "/tmp/scripts/$(basename $0).XXXX" )


#
# Required Applications
#
LOGGER_APP=/usr/bin/logger
SYSTEMCTL_APP=/usr/bin/systemctl
DOCKER_APP=/usr/bin/podman
IP_CMD=/sbin/ip



APP_LIST=( $LOGGER_APP \
           $SYSTEMCTL_APP \
           $DOCKER_APP \
           $IP_CMD \
         )


# Debug
let ERROR=0
let WARNING=1
let INFO=2
let DEBUG=3
let DEVEL=4
let DEBUG_LEVEL=$ERROR


# Set to !0 to enable test mode
let TEST_MODE=0     # Enable test mode


################################################################################
#
# Globals
#
################################################################################

# Dry run flag
DRY_RUN_FLAG=0

# '/etc' root in thin pool storage
ETC_ROOT="/usr/local/etc"

# Network restart flag
NETWORK_RESTART_FLAG=0





#
# Command usage
#
usage() 
{
    local md5sum=$( cat $0 |md5sum |awk '{print $1}' )

cat <<EOOPTS


  USAGE:

    $(basename $0) [OPTIONS] CMD [parameters]

      Version: $VERSION
       Md5sum: $md5sum


  OPTIONS:

    -d <level> - set debug level (range is 0 to 4, 5 enables test mode; default is '0')
    --dry_run - sets dry run flag to true (useful for debugging command line options)
    -h, --help - display usage and exit


  COMMANDS:
 
    SAVE [subsystem] - save VM configuration
    RESTORE - restore VM configuration

  EXAMPLE USAGE:

    $(basename $0) -h
    $(basename $0) -d 2 SAVE
    $(basename $0) -d 2 RESTORE


EOOPTS

    cleanup_and_exit $1
}


#
# Parse command line
#
# $1 - option string
#
# Example:
# 
#   -f <option> -d -a <option> -c -p <option>
#
#   Option string is "fap"
#
parse_cmd_line ()
{
    local option_list="$1"
    
    local arg_cnt=${#ARGS[@]}
    local index=0
    local key_index=0
    local param=""
    local option=""
    local position=0
    local flag=""
    local loop_cnt=0
    local len=0
    
    
    while [[ $arg_cnt -ne 0 ]] 
    do
    
        # Get command line parameter
        param="${ARGS[$index]}"
        ((++index))
 
        case $param in
        
            --*=*)
            
                value="${param##*=}"
                option="${param%%=*}"
                
                if [ -z "$value" ]; then
                    disp_msg $ERROR "value required for command line option $param"
                    return 1                
                fi
                                
                KEYS[$key_index]="${option##*-}"
                VALUES[$key_index]="$value"
                
                ((++key_index))
                let SHIFT_CNT=$SHIFT_CNT+1
                ;;
                
            --dry_run) # Option does not require a parameter
                KEYS[$key_index]="${param##*-}"
                VALUES[$key_index]="" 
                    
                ((++key_index))
                let SHIFT_CNT=$SHIFT_CNT+1
                ;;
                                
            --*)
            
                if [[ $index -lt ${#ARGS[@]} ]]; then
                    
                    value="${ARGS[$index]}"
                                  
                    # Check for value
                    if [ "${value:0:1}" != "-" ]; then
                        KEYS[$key_index]="${param##*-}"
                        VALUES[$key_index]="$value"
             
                        ((++key_index))
                        let SHIFT_CNT=$SHIFT_CNT+2
                        ((--arg_cnt))
                        ((++index))  
                    
                    else
                        KEYS[$key_index]="${param##*-}"
                        VALUES[$key_index]="$value" 
                    
                        ((++key_index))
                        let SHIFT_CNT=$SHIFT_CNT+1
                    fi                                          

                else

                    KEYS[$key_index]="${param##*-}"
                    VALUES[$key_index]="" 
                    
                    ((++key_index))
                    let SHIFT_CNT=$SHIFT_CNT+1
                    
                fi
                
                ;;
                
            -*)
                option=${param:1:1}
            
                # Search option list to see if option requires a value
                let position=0
                while [[ $position -lt ${#option_list} ]]
                do
                    flag="${option_list:$position:1}"
                    
                    if [ "$flag" == "$option" ]; then
                        break
                    fi
                    
                    ((++position))
                    
                done
                
                if [[ $position -lt ${#option_list} ]]; then
                
                    # Command line option requires a value
                    
                    # Check to see if there is no space between option and value
                    len=${#param}
                    
                    if [[ $len -gt 2 ]]; then
                    
                        # No space found between option and value
                        value="${param:2:$len}"
                        
                        KEYS[$key_index]="$option"
                        VALUES[$key_index]="$value"
                    
                        ((++key_index))
                        let SHIFT_CNT=$SHIFT_CNT+1
                        
                    else
                    
                        # Space found between option and value
                        
                        if [[ $index -lt ${#ARGS[@]} ]]; then
                        
                            value="${ARGS[$index]}"
                        
                            # Check for missing value
                            if [ "${value:0:1}" == "-" ]; then
                                disp_msg $ERROR "value required for command line option $param"
                                return 1
                            fi
                    
                            KEYS[$key_index]="$option"
                            VALUES[$key_index]="$value"
                    
                            ((++key_index))
                            let SHIFT_CNT=$SHIFT_CNT+2
                            ((--arg_cnt))
                            ((++index))
                        
                        else
                        
                            # last parameter, required option not found
                            disp_msg $ERROR "value required for command line option $param"
                            return 1

                        fi

                    
                    fi
                                    
                else
                
                    # Command line option has no value associated with it
                    
                    KEYS[$key_index]="$option"
                    VALUES[$key_index]=""
                    
                    ((++key_index))
                    let SHIFT_CNT=$SHIFT_CNT+1
                
                fi
      
                ;;
                    
        esac
        
        ((--arg_cnt))
        ((++loop_cnt))
        
        if [[ $loop_cnt -gt $MAX_LOOP_CNT ]]; then
            disp_msg $ERROR "max loop count <$MAX_LOOP_CNT> exceeded"
            cleanup_and_exit 0        
        fi

    done
    
    
    return 0
}


#
# Display debug messages
#
disp_msg ()
{
    local level="$1"
    local msg="$2"
        
    
    if [[ $level -le $DEBUG_LEVEL ]]; then
    
        case $level in
        
        $ERROR)
            echo -e "\n\n  [ERROR> - $msg\n\n"
            $LOGGER_APP -t kodiak "[$SCRIPT_NAME ERROR> $msg"
            ;;
            
        $WARNING)
            echo -e "\n  [WARNING> - $msg\n"
            $LOGGER_APP -t kodiak "[$SCRIPT_NAME WARNING> $msg"
            ;;
            
        $INFO)
            echo -e "[INFO] $msg"
            $LOGGER_APP -t kodiak "[$SCRIPT_NAME INFO> $msg"
            ;;
            
        $DEBUG)
            echo -e "[DEBUG] $msg"
            ;;

        *)
            echo -e "[DEVEL] $msg"
            ;;
            
        esac
       
    fi

    
    return 0
}


#
# Check if application is installed
#
# $1 - application
#
is_app_installed ()
{
    local app="$1"
    local retval=0
    
    retval=$( command -v "$app" >/dev/null 2>&1 )
    
    return $retval
}


#
# Cleanup and exit
#
# $1 - return value
#
cleanup_and_exit ()
{

    # Delete temporary directory
    if [ -d "$TMP_DIR" ]; then
        if [[ $TEST_MODE -eq 0 ]]; then
            rm -rf "$TMP_DIR"
        fi
    fi

    echo -e "\n\n"
    
    exit $1
}




################################################################################
##
## Functions
##
################################################################################


#
# Save VM configuration
#
# $1 - subsystem (e.g. networking, systemd, etc.)
# $2 - configuration file
#
save_configuration ()
{
    local config_file="$2"
    local subsystem
    local subsystem_flag
    
    # Convert to lowercase
    subsystem=$( echo "$1" | awk '{print tolower($0)}' )
    
    if [ ! -n "$subsystem" ]; then
        subsystem_flag="ALL"
    else
        subsystem_flag="$subsystem"
    fi
    
    disp_msg $INFO "  saving VM configuration for subsystem <$subsystem_flag> ..."
  
   # Save sophos items
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "sophos" ]; then

        if ! save_sophos_files; then
            return 1
        fi
    fi

   # Save sentinelone items
#   if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "sentinelone" ]; then
#        
#       if ! save_sentinelone_files; then
#           return 1 
#       fi
#   fi 


   # Save auditbeat items
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "auditbeat" ]; then

        if ! save_auditbeat_files; then
            return 1
        fi
    fi

   # Save cosign policy
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "cosign" ]; then

        if ! save_cosign_files; then
            return 1
        fi
    fi
   
    # Execte backup_mdatp.sh script to save
    if [ -f "/DGdata/Software/tps_scripts/backup_mdatp.sh" ]; then
        disp_msg $INFO "Executing backup_mdatp.sh..."
        /bin/bash /DGdata/Software/tps_scripts/backup_mdatp.sh
        if [[ $? -ne 0 ]]; then
            disp_msg $ERROR "backup_mdatp.sh execution failed"
#            return 1
        fi
    else
        disp_msg $WARNING "backup_mdatp.sh script not found"
    fi

#    return 0



    # Execte Sentinelone_backup.sh script to save
    if [ -f "/DGdata/Software/tps_scripts/Sentinelone_backup.sh" ]; then
        disp_msg $INFO "Executing Sentinelone_backup.sh..."
        /bin/bash /DGdata/Software/tps_scripts/Sentinelone_backup.sh
        if [[ $? -ne 0 ]]; then
            disp_msg $ERROR "Sentinelone_backup.sh execution failed"
#            return 1
        fi
    else
        disp_msg $WARNING "Sentinelone_backup.sh script not found"
    fi

#    return 0


    # Execute ElastAgent_Backup.sh script to save
    if [ -f "/DGdata/Software/tps_scripts/ElastAgent_Backup.sh" ]; then
        disp_msg $INFO "Executing ElastAgent_Backup.sh..."
        /bin/bash /DGdata/Software/tps_scripts/ElastAgent_Backup.sh
        if [[ $? -ne 0 ]]; then
            disp_msg $ERROR "ElastAgent_Backup.sh execution failed"
#            return 1
        fi
    else
        disp_msg $WARNING "ElastAgent_Backup.sh script not found"
    fi

#return 0



return 0


}

#
# Save cosign Files
#
save_cosign_files ()
{
    rm -rf ${ETC_ROOT}/cosign/*
    disp_msg $INFO " Saving cosign files..."
    
    # Create directory
    if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/cosign"; then
        disp_msg $ERROR "unable to create directory <${ETC_ROOT}/cosign>"
            return 1
    fi
    
   #if present, save file '/etc/containers/registries.d/default.yaml'
    if [ -f "/etc/containers/registries.d/default.yaml" ]; then
        
        if ! copy_file "/etc/containers/registries.d/default.yaml" "${ETC_ROOT}/cosign"; then
             return 1
        fi
     
    fi

   #if present, save file '/etc/containers/policy.json'
     if [ -f "/etc/containers/policy.json" ]; then
        if ! copy_file "/etc/containers/policy.json" "${ETC_ROOT}/cosign"; then
             return 1
        fi
     fi

   #if present, save file '/etc/pki/Msikodiak_Skopeo.pub'
     if [ -f "/etc/pki/Msikodiak_Skopeo.pub" ]; then
        if ! copy_file "/etc/pki/Msikodiak_Skopeo.pub" "${ETC_ROOT}/cosign"; then
             return 1
        fi
     fi
    return 0
}

#
# Save auditbeat Files
#
save_auditbeat_files ()
{
     disp_msg $INFO " Checking  auditbeat service..."
     rm -rf ${ETC_ROOT}/auditbeat/*
     service_status=`systemctl is-enabled auditbeat`
    if [ "$service_status" == "enabled" ]; then
      disp_msg $INFO " Saving auditbeat files..."
    # If present, save file '/usr/lib/systemd/system/auditbeat.service'
      if [ -f "/usr/lib/systemd/system/auditbeat.service" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/auditbeat"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/auditbeat>"
            return 1
        fi
        if ! copy_file "/usr/lib/systemd/system/auditbeat.service" "${ETC_ROOT}/auditbeat"; then
             return 1
      fi
     
    fi

   #if present, save file '/etc/auditbeat/auditbeat.yml'
     if [ -f "/etc/auditbeat/auditbeat.yml" ]; then
        if ! copy_file "/etc/auditbeat/auditbeat.yml" "${ETC_ROOT}/auditbeat"; then
             return 1
        fi
     fi
    else 
 
      disp_msg $INFO "Service is not runnoing hence skipping backup"
  fi
  return 0
}

# Save sophos Files
#
save_sophos_files ()
{
     disp_msg $INFO "    saving sophos file ..."
    # If present, save file '/usr/lib/systemd/system/sophos-spl.service'
    if [ -f "/usr/lib/systemd/system/sophos-spl.service" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/sophos"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/sophos>"
            return 1
        fi
        if ! copy_file "/usr/lib/systemd/system/sophos-spl.service" "${ETC_ROOT}/sophos"; then
             return 1
        fi
#    

    #if present, save file '/usr/lib/systemd/system/sophos-spl-update.service'
    if [ -f "/usr/lib/systemd/system/sophos-spl-update.service" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/sophos"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/sophos>"
            return 1
        fi
        if ! copy_file "/usr/lib/systemd/system/sophos-spl-update.service" "${ETC_ROOT}/sophos"; then
             return 1
        fi
    fi
    #if present, save file '/etc/rsyslog.d/rsyslog_sophos-spl.conf'
    if [ -f "/etc/rsyslog.d/rsyslog_sophos-spl.conf" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/sophos"; then
             disp_msg $ERROR "unable to create directory <${ETC_ROOT}/sophos>"
             return 1
        fi
        if ! copy_file "/etc/rsyslog.d/rsyslog_sophos-spl.conf" "${ETC_ROOT}/sophos"; then
            return 1
        fi
    fi
    # Saving the Sophos User details
    disp_msg $INFO "Saving Sophos User Details...."
        if [ -f "${ETC_ROOT}/sophos/passwd" ]; then
            rm -f ${ETC_ROOT}/sophos/passwd
                        cat /etc/passwd |grep -i sophos >> ${ETC_ROOT}/sophos/passwd
        else
            cat /etc/passwd |grep -i sophos >> ${ETC_ROOT}/sophos/passwd
        fi 
        if [ -f "${ETC_ROOT}/sophos/shadow" ]; then
            rm -f ${ETC_ROOT}/sophos/shadow
                        cat /etc/shadow |grep -i sophos >> ${ETC_ROOT}/sophos/shadow
        else
            cat /etc/shadow |grep -i sophos >> ${ETC_ROOT}/sophos/shadow
        fi
        if [ -f "${ETC_ROOT}/sophos/group" ]; then
            rm -f ${ETC_ROOT}/sophos/group
                        cat /etc/group |grep -i sophos >> ${ETC_ROOT}/sophos/group
        else 
            cat /etc/group |grep -i sophos >> ${ETC_ROOT}/sophos/group
        fi
        fi   
    return 0
}
#
#
# Save sentinelone Files
#
#save_sentinelone_files ()
#{
#     disp_msg $INFO "    saving sentinelone file ..."
#    # If present, save file '/usr/lib/systemd/system/sentinelone.service'
#    if [ -f "/usr/lib/systemd/system/sentinelone.service" ]; then
#        # Create directory
#        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/sentinelone"; then
#            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/sentinelone>"
#            return 1
#        fi
#        if ! copy_file "/usr/lib/systemd/system/sentinelone.service" "${ETC_ROOT}/sentinelone"; then
#             return 1
#        fi
#    
#
#    # Saving the sentinelone User details
#    disp_msg $INFO "Saving sentinelone User Details...."
#        if [ -f "${ETC_ROOT}/sentinelone/passwd" ]; then
#            cat /etc/passwd |grep -i sentinelone > ${ETC_ROOT}/sentinelone/passwd
#       else
#            cat /etc/passwd |grep -i sentinelone > ${ETC_ROOT}/sentinelone/passwd
#       fi
#       if [ -f "${ETC_ROOT}/sentinelone/shadow" ]; then
#            cat /etc/shadow |grep -i sentinelone > ${ETC_ROOT}/sentinelone/shadow
#       else
#            cat /etc/shadow |grep -i sentinelone > ${ETC_ROOT}/sentinelone/shadow
#       fi
#       if [ -f "${ETC_ROOT}/sentinelone/group" ]; then
#            cat /etc/group |grep -i sentinelone > ${ETC_ROOT}/sentinelone/group
#       else
#            cat /etc/group |grep -i sentinelone > ${ETC_ROOT}/sentinelone/group
#       fi
#    fi
#    # Backup /opt/sentinelone folder
#    #if [ -d "/opt/sentinelone" ]; then
#    #    if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/sentinelone_folder"; then
#    #        disp_msg $ERROR "unable to create directory <${ETC_ROOT}/sentinelone_folder>"
#    #        return 1
#    #    fi
#    #    disp_msg $INFO "Backing up /opt/sentinelone folder..."
#    #    if ! copy_folders "/opt/sentinelone" "${ETC_ROOT}/sentinelone_folder"; then
#    #        return 1
#    #    fi
#    #else
#    #   disp_msg $INFO "/opt/sentinelone folder not found, skipping backup."
#    #fi
#
#    return 0
#}



#
# Restore VM configuration
#
restore_configuration ()
{
    local etc_root_dir="${ETC_ROOT}"
    
    disp_msg $INFO "  restoring VM configuration ..."
    
    # Restore sophos file
    if ! restore_sophos_files "$etc_root_dir"; then
        return 1
    fi
   # Restore sentinelone file
#     if ! restore_sentinelone_files "$etc_root_dir"; then
#        return 1
#     fi 
    # Restore auditbeat file
    if ! restore_auditbeat_files "$etc_root_dir"; then
        return 1
    fi

    # Restore cosign file
    if ! restore_cosign_files "$etc_root_dir"; then
        return 1
    fi

    # Call restore_mdatp.sh script
    if [ -f "/DGdata/Software/tps_scripts/restore_mdatp.sh" ]; then
        disp_msg $INFO "Executing restore_mdatp.sh..."
        /bin/bash /DGdata/Software/tps_scripts/restore_mdatp.sh
        if [[ $? -ne 0 ]]; then
            disp_msg $ERROR "restore_mdatp.sh execution failed"
#            return 1
        fi
    else
        disp_msg $WARNING "restore_mdatp.sh script not found"
    fi


    # Execute Sentinelone_restore.sh script to restore
    if [ -f "/DGdata/Software/tps_scripts/Sentinelone_restore.sh" ]; then
        disp_msg $INFO "Executing Sentinelone_restore.sh..."
        /bin/bash /DGdata/Software/tps_scripts/Sentinelone_restore.sh
        if [[ $? -ne 0 ]]; then
            disp_msg $ERROR "Sentinelone_restore.sh execution failed"
#            return 1
        fi
    else
        disp_msg $WARNING "Sentinelone_restore.sh script not found"
    fi

    

    # Execute ElastAgent_Restore.sh script to restore
    if [ -f "/DGdata/Software/tps_scripts/ElastAgent_Restore.sh" ]; then
        disp_msg $INFO "Executing ElastAgent_Restore.sh..."
        /bin/bash /DGdata/Software/tps_scripts/ElastAgent_Restore.sh
        if [[ $? -ne 0 ]]; then
            disp_msg $ERROR "ElastAgent_Restore.sh execution failed"
#            return 1
        fi
    else
        disp_msg $WARNING "ElastAgent_Restore.sh script not found"
    fi

    
   
    return 0
}

#
# Restore cosign items
#
restore_cosign_files()
{
    local etc_root_dir="$1"
    disp_msg $INFO "    restoring cosign items ..."


    if [ -f "${etc_root_dir}/cosign/default.yaml" ]; then
        if ! copy_file "${etc_root_dir}/cosign/default.yaml" "/etc/containers/registries.d/"; then
            return 1
        fi
    fi


    if [ -f "${etc_root_dir}/cosign/policy.json" ]; then
        if ! copy_file "${etc_root_dir}/cosign/policy.json" "/etc/containers/"; then
            return 1
        fi
    fi

    if [ -f "${etc_root_dir}/cosign/Msikodiak_Skopeo.pub" ]; then
        if ! copy_file "${etc_root_dir}/cosign/Msikodiak_Skopeo.pub" "/etc/pki/"; then
            return 1
        fi
    fi
    return 0
}

#
# Restore auditbeat items
#
restore_auditbeat_files()
{
    local etc_root_dir="$1"
    disp_msg $INFO "    restoring auditbeat items ..."


    if [ -f "${etc_root_dir}/auditbeat/auditbeat.yml" ]; then
        if ! copy_file "${etc_root_dir}/auditbeat/auditbeat.yml" "/etc/auditbeat/"; then
            return 1
        fi
    fi


    if [ -f "${etc_root_dir}/auditbeat/auditbeat.service" ]; then
        if ! copy_file "${etc_root_dir}/auditbeat/auditbeat.service" "/usr/lib/systemd/system/"; then
            return 1
        fi
        # Disbable service
        /bin/systemctl enable auditbeat.service
    fi

    return 0
}

#
# Restore sophos items
#
restore_sophos_files()
{
    local etc_root_dir="$1"
    disp_msg $INFO "    restoring sophos items ..."
    if [ -f "${etc_root_dir}/sophos/passwd" ]; then
        cat ${etc_root_dir}/sophos/passwd >> /etc/passwd
    fi
    if [ -f "${etc_root_dir}/sophos/shadow" ]; then
        cat ${etc_root_dir}/sophos/shadow >> /etc/shadow
    fi
    if [ -f "${etc_root_dir}/sophos/group" ]; then
        cat ${etc_root_dir}/sophos/group >> /etc/group
    fi
    if [ -f "${etc_root_dir}/sophos/sophos-spl.service" ]; then
        if ! copy_file "${etc_root_dir}/sophos/sophos-spl.service" "/usr/lib/systemd/system/"; then
            return 1
        fi
        # Enable service
        /bin/systemctl enable sophos-spl.service
    
    fi
    
    if [ -f "${etc_root_dir}/sophos/sophos-spl-update.service" ]; then
        if ! copy_file "${etc_root_dir}/sophos/sophos-spl-update.service" "/usr/lib/systemd/system/"; then
            return 1
        fi
        # Enable service
        /bin/systemctl enable sophos-spl-update.service
    fi

    if [ -f "${etc_root_dir}/sophos/rsyslog_sophos-spl.conf" ]; then
        if ! copy_file "${etc_root_dir}/sophos/rsyslog_sophos-spl.conf" "/etc/rsyslog.d/"; then
            return 1
        fi
    fi
    
    return 0
}

#
# Restore sentinelone items
#
#restore_sentinelone_files()
#{
#    local etc_root_dir="$1"
#    disp_msg $INFO "    restoring sentinelone items ..."
#
#    # Compare /etc/passwd sentinelone entries with backup
#    if [ -f "${etc_root_dir}/sentinelone/passwd" ]; then
#        local current_passwd
#        local backup_passwd
#        current_passwd=$(cat /etc/passwd | grep -i sentinelone)
#        backup_passwd=$(cat "${etc_root_dir}/sentinelone/passwd")
#        if [ "$current_passwd" != "$backup_passwd" ]; then
#            disp_msg $INFO "SentinelOne user entries in /etc/passwd differ from backup."
#            sed -i '/[Ss]entinelone/d' /etc/passwd
#            cat ${etc_root_dir}/sentinelone/passwd >> /etc/passwd
#        else
#            disp_msg $INFO "SentinelOne user entries in /etc/passwd match the backup."
#        fi
#    fi
#
#   # Compare /etc/shadow sentinelone entries with backup
#    if [ -f "${etc_root_dir}/sentinelone/shadow" ]; then
#        local current_shadow
#        local backup_shadow
#        current_shadow=$(cat /etc/shadow | grep -i sentinelone)
#        backup_shadow=$(cat "${etc_root_dir}/sentinelone/shadow")
#        if [ "$current_shadow" != "$backup_shadow" ]; then
#            disp_msg $INFO "SentinelOne user entries in /etc/shadow differ from backup."
#            sed -i '/[Ss]entinelone/d' /etc/shadow
#            cat ${etc_root_dir}/sentinelone/shadow >> /etc/shadow
#        else
#            disp_msg $INFO "SentinelOne user entries in /etc/shadow match the backup."
#        fi
#    fi
#
#    # Compare /etc/group sentinelone entries with backup
#    if [ -f "${etc_root_dir}/sentinelone/group" ]; then
#        local current_group
#        local backup_group
#      current_group=$(cat /etc/group | grep -i sentinelone)
#        backup_group=$(cat "${etc_root_dir}/sentinelone/group")
#        if [ "$current_group" != "$backup_group" ]; then
#            disp_msg $INFO "SentinelOne user entries in /etc/group differ from backup."
#            sed -i '/[Ss]entinelone/d' /etc/group
#            cat ${etc_root_dir}/sentinelone/group >> /etc/group
#        else
#            disp_msg $INFO "SentinelOne user entries in /etc/group match the backup."
#        fi
#    fi
#
#    if [ -f "${etc_root_dir}/sentinelone/sentinelone.service" ]; then
#        if ! copy_file "${etc_root_dir}/sentinelone/sentinelone.service" "/usr/lib/systemd/system/"; then
#            disp_msg $ERROR "Unable to restore ${etc_root_dir}/sentinelone/sentinelone.service"
#        fi
#        # Enable service
#        /bin/systemctl enable sentinelone.service
#    fi
#
#    # Restore /opt/sentinelone folder
#    if [ -d "${etc_root_dir}/sentinelone_folder" ]; then
#        disp_msg $INFO "Restoring /opt/sentinelone folder..."
#        if ! copy_folders "${etc_root_dir}/sentinelone_folder" "/opt/sentinelone"; then
#            disp_msg $ERROR "Unable to restore ${etc_root_dir}/sentinelone/sentinelone.service"
#        fi
#    else
#        disp_msg $INFO "${etc_root_dir}/sentinelone_folder not found, skipping restore."
#    fi
#
#       
#}
        
#
# Copy file
#
# $1 - filepath
# $2 - destination
#
copy_file ()
{
    local filepath="$1"
    local destination="$2"
    local filename=$( basename "$filepath" )
    
    disp_msg $INFO "        copying file <$filepath> to <$destination>"
    
    # Check for source file
    if [ ! -f "$filepath" ]; then
        disp_msg $ERROR "source file <$filepath> not found"
        return 1
    fi
    
    # Check for destination directory
    if [ ! -d "$destination" ]; then
        disp_msg $ERROR "destination directory <$destination> not found"
        return 1
    fi
    
    # Check if destination file is a soft link
    if [ -L "${destination}/${filename}" ]; then
        disp_msg $INFO "          deleting destination soft link <${destination}/${filename}>"
        # Delete destination soft link
        /bin/rm -f "${destination}/${filename}"
    fi
    
    # Copy file
    if ! /bin/cp -pf "$filepath" "$destination"; then
        disp_msg $ERROR "unable to copy file <$filepath> to <$destination>"
        return 1
    fi

    return 0
}


#
# Copy files from one directory to another
#
# $1 - source
# $2 - destination
#
copy_folders ()
{
    local source="$1"
    local destination="$2"
    local files
    
    disp_msg $INFO "        copying files from <${source}/*> to <$destination>"
    
    # Check for source directory
    if [ -d "$source" ]; then
    
        # Check to see if source directory contains any files or sub-directories
        if [ -n "$(ls -A $source 2>/dev/null)" ]; then
        
            # Check for destination directory
            if [ ! -d "$destination" ]; then
                # Try to create destination directory
                if ! /bin/mkdir -p "$destination"; then
                    disp_msg $ERROR "unable to create destination directory <$destination>"
                    return 1
                else
                    disp_msg $INFO "          created destination directory <$destination>"
                    
                    # Set permissions
                    if ! /bin/chmod 0755 "$destination"; then
                        disp_msg $ERORR "unable to set permissions to <0755> for directory <$destination>"
                        return 1
                    fi
                fi
            fi
                
            # Copy files
            if ! /bin/cp -rf ${source}/* "$destination"; then
                disp_msg $ERROR "unable to copy files from <${source}/*> to <$destination>"
                return 1
            else
                disp_msg $INFO "          copied files from <${source}/*> to <$destination>"
            fi
            
        else
            disp_msg $INFO "          source directory <$source> is empty"
        fi
    
    else
        disp_msg $INFO "          source directory <$source> not found"
    fi

    return 0
}


#
# Delete file
#
# $1 - filepath
#
delete_file ()
{
    local filepath="$1"
    
    disp_msg $INFO "        deleting file <$filepath>"
 
    if [ ! -f "$filepath" ]; then
        disp_msg $INFO "source file <$filepath> to delete not found"
        return 0
    fi
    
    # Delete file
    if ! /bin/rm -f "$filepath"; then
        disp_msg $ERROR "unable to delete file <$filepath>"
        return 1
    fi    

    return 0
}


#
# Move file
#
# $1 - filepath
# $2 - destination
#
move_file ()
{
    local filepath="$1"
    local destination="$2"
    
    disp_msg $INFO "      moving file <$filepath> to <$destination>"
            
    # Copy file file
    if ! copy_file "$filepath" "$destination"; then
        return 1
    fi
    
    # Delete file
    if ! delete_file "$filepath"; then
        return 1
    fi
    
    return 0
}

################################################################################
#
# Prerequisites
#
################################################################################

# Install signal handler
trap "cleanup_and_exit 1" SIGHUP SIGINT SIGTERM


# Check for user root
if [[ $EUID -ne 0 ]]; then
    disp_msg $ERROR "must be user root"
    cleanup_and_exit 1
fi


# Ensure applications are installed on host
for app in ${APP_LIST[@]}
do
    if [ ! -x "$app" ]; then
        disp_msg $ERROR "required application <$app> not found"
        cleanup_and_exit 1
    fi

done




################################################################################
##
## Parse command line
##
################################################################################


OPTION_LIST="d"  # list of command line flags requiring parameters
ARGS=("$@")
KEYS=""
VALUES=""
SHIFT_CNT=0

# Parse command line
parse_cmd_line "$OPTION_LIST"

if [[ $? -ne 0 ]]; then
    exit 1
else
    shift $SHIFT_CNT
fi


let index=0
for key in ${KEYS[@]}
do

    value="${VALUES[$index]}"
    
    case $key in 
    
        h|help)
            usage 1
            ;;
            
        d)
            let DEBUG_LEVEL=$value
            
            # Enable test mode
            if [[ $DEBUG_LEVEL -gt $DEVEL ]]; then
                TEST_MODE=1
                TMP_FILE="${TMP_DIR}/debug.log"
            fi
            ;;
            
           
        dry_run|dryrun)
            let DRY_RUN_FLAG=1
            ;;
            
        r)
            NETWORK_RESTART_FLAG=1
            ;;
            
            
        *)
            disp_msg $ERROR "unknown command line option <$key>"
            usage 1
            ;;
            
    esac
    
    ((++index))
    
done


if [[ $DRY_RUN_FLAG -ne 0 ]]; then
    
    echo -e "\n"
    
    let DEBUG_LEVEL=$DEBUG

    disp_msg $DEBUG "--dryrun is set to <$DRY_RUN_FLAG>"

    
    echo -e "\n"
    
    CMD="$1"
    disp_msg $DEBUG "Command is <$CMD>"
    echo ""
    shift

    for param in "$@"
    do
        echo -e "  param is <$param>"
    done

    cleanup_and_exit 0
fi


CMD="$1"

disp_msg $DEBUG "Command is <$CMD>"

if [[ -z "$CMD" ]]; then
    usage 1
fi




################################################################################
#
# Main
#
################################################################################


#
# Execute command
#
case $CMD in

    SAVE|save)
        
        disp_msg $INFO "Save VM configuration to thin pool storage"
        
        # Get optional command line parameter
        SUBSYSTEM="$2"

        # Get optional command line parameter
        CONFIG_FILE="$3"
        
        # Save configuration
        save_configuration "$SUBSYSTEM" "$CONFIG_FILE"

        RETURN_VAL=$?
        
        if [ $RETURN_VAL -ne 0 ]; then
            cleanup_and_exit $RETURN_VAL
        fi  

        ;;
           
           
    RESTORE|restore)
        
        disp_msg $INFO "Restore VM configuration from thin pool storage"
        
        # Restore configuration
        restore_configuration

        RETURN_VAL=$?
        
        if [ $RETURN_VAL -ne 0 ]; then
            cleanup_and_exit $RETURN_VAL
        fi
        ;;
        
    *)
        disp_msg $ERROR "CMD <$CMD> not found"
        usage 1
        ;;

esac


# Exit
cleanup_and_exit 0
