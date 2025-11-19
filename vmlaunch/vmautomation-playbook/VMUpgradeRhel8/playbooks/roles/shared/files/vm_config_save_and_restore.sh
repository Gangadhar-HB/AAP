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
#  2016-05-18 - gmorton
#               initial version
#
#  2016-05-19 - gmorton
#               added saving and restoring network configuration
#
#  2016-05-24 - gmorton
#               fixed issues saving and restoring network configuration
#
#  2016-05-25 - gmorton
#               delete existing ifcfg files from thin pool storage before saving
#
#  2016-05-26 - gmorton
#               added save subsystem option
#
#  2016-05-27 - gmorton
#               added check to make sure docker service is running
#               added code to enable and start containers
#
#  2016-05-31 - gmorton
#               added code to save and restore NTP configuration files
#
#  2016-06-02 - gmorton
#               always save network configuration file as '$ETC_ROOT/network_config.ini'
#
#  2016-06-03 - gmorton
#               added code to save hostname
#
#  2016-06-09 - gmorton
#               fixed issue with restoring container service files
#
#  2016-06-22 - gmorton
#               moved saving of network configuration to another script
#
#  2017-05-12 - gmorton
#               Save docker storage configuration
#
#  2017-11-20 - gmorton
#               Save /etc/fstab
#               Modify code to restore configuration files
#               Delete destination soft link before copying file
#
#  2018-01-05 - gmorton
#               Save VM configuration state
#
#  2018-07-05 - gmorton
#               save and restore sys conf files (e.g. /etc/sysctl.conf, /etc/sysctl.d/*)
#               save and restore /etc/localtime to/from /usr/local/etc/timezone
#               save and restore iptables
#
#  2018-07-13 - gmorton
#               added check to see if file exists before trying to restore it
#
#  2018-07-14 - gmorton
#               Just print log message if file is not found - don't return an error
#
#  2018-09-11 - kkuruba
#               Added container service file state
#
#  2018-11-26 - gmorton
#               Added code to backup and restore docker registry configuration
#
#  2018-11-28 - gmorton
#               Added check for masked container service file
#
#  2019-04-15 - gmorton
#               save /etc/hosts
#
#  2019-05-15 - gmorton
#               save /etc/sysconfig/*.repo.conf files
#               fix restore issue with /etc/hosts
#
#  2019-11-11 - gmorton
#               save and restore file '/etc/crypttab'
#
#  2019-11-19 - gmorton
#               move existing ifcfg-* files when restoring from /usr/local/etc
#
#  2019-11-22 - gmorton
#               save files /etc/hosts.allow and /etc/hosts.deny
#
#  2019-12-18 - gmorton
#               updated ntp configuration file save and restore
#
#  2019-12-20 - gmorton
#               added update-ca-trust command
#
#  2020-05-29 - gmorton
#               save and restore script ContainerstartInOrder.sh if present
#
#  2020-06-02 - gmorton
#               fix cut and past error for save and restore of ContainerstartInOrder.sh
#
#  2020-06-04 - gmorton
#               save and restore F5FDBUpdate.sh and F5SNATUpdate.sh if present
#               save and restore f5localfdbupdate.service and snatfdbupdate.service if present
#               save and restore f5localfdbupdate.timer and snatfdbupdate.timer if present
#
#  2020-07-22 - gmorton
#               save and restore /usr/local/bin/F5_encrypted_password if present
#
#  2020-09-10 - gmorton
#               fixed mkdir mode
#
#  2023-01-10 - SAYANTAN KARMAKAR
#               save and restore Sophos files and service
# MINT-4132
#MINT-3779
#/usr/local/bin/contentinfo
# Version:
VERSION="2023-02-10"



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
DOCKER_APP=/usr/bin/docker
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
    -r - restart networking


  COMMANDS:

    SAVE [subsystem] - save VM configuration
    STATE <ok(0) or fail(1)> - save VM's configuration state (0 or 1)
    RESTORE - restore VM configuration


  PARAMETERS:

    subsystem - (optional) name of subsystem configuration to save
                           (e.g. systemd, networking, ntp, hostname)
                           Default is all subsystems if none specified


  EXAMPLE USAGE:

    $(basename $0) -h
    $(basename $0) -d 2 SAVE
    $(basename $0) -d 2 SAVE SYS_CONF
    $(basename $0) -d 2 SAVE NETWORKING
    $(basename $0) -d 2 SAVE SYSTEMD
    $(basename $0) -d 2 SAVE NTP
    $(basename $0) -d 2 SAVE HOSTNAME
    $(basename $0) -d 2 -r RESTORE
    $(basename $0) -d 2 RESTORE
    $(basename $0) -d 2 STATE 0
    $(basename $0) -d 2 STATE 1


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

    # Save system configuration
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "sys_conf" ]; then

        if ! save_sys_conf; then
            return 1
        fi

    fi

    # Save /etc/fstab
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "fstab" ]; then

        if ! save_etc_fstab; then
            return 1
        fi

    fi

    # Save /etc/crypttab
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "crypttab" ]; then

        if ! save_etc_crypttab; then
            return 1
        fi

    fi

    # Save container systemd service files
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "systemd" ]; then

        if ! save_container_service_files; then
            return 1
        fi

    fi

    # Save hostname
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "hostname" ]; then

        if ! save_hostname; then
            return 1
        fi

    fi

    # Save /etc/hosts
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "etc_hosts" ]; then

        if ! save_etc_hosts; then
            return 1
        fi

    fi

    # Save ntp files
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "ntp" ]; then

        if ! save_ntp_configuration_files; then
            return 1
        fi

    fi

    # Save network configuration
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "networking" ]; then

        if ! save_network_config "$config_file"; then
            return 1
        fi

    fi

    # Save docker storage configuration
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "docker" ]; then

        if ! save_docker_config; then
            return 1
        fi

    fi

    # Save docker registry configuration
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "registry" ]; then

        if ! save_docker_registry_config; then
            return 1
        fi

    fi

    # Save sysconfig files
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "sysconfig" ]; then

        if ! save_sysconfig_files; then
            return 1
        fi

    fi
   # Save sophos items
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "sophos" ]; then

        if ! save_sophos_files; then
            return 1
        fi
    fi
    # Save miscellaneous items
    if [ "$subsystem_flag" == "ALL" -o "$subsystem_flag" == "misc" ]; then

        if ! save_misc_items; then
            return 1
        fi

    fi

    return 0
}

#
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
    fi

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
    return 0
}

#
# Save miscellaneous items
#
save_misc_items ()
{
    disp_msg $INFO "    saving miscellaneous items ..."

        # If present, save file '/usr/local/bin/contentinfo'
    if [ -f "/usr/local/bin/contentinfo" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/misc/usr/local/bin"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/misc/usr/local/bin>"
            return 1
        fi

        if ! copy_file "/usr/local/bin/contentinfo" "${ETC_ROOT}/misc/usr/local/bin"; then
            return 1
        fi
    fi

    # If present, save file '/usr/local/bin/ContainerstartInOrder.sh'
    if [ -f "/usr/local/bin/ContainerstartInOrder.sh" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/misc/usr/local/bin"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/misc/usr/local/bin>"
            return 1
        fi

        if ! copy_file "/usr/local/bin/ContainerstartInOrder.sh" "${ETC_ROOT}/misc/usr/local/bin"; then
            return 1
        fi
    fi

    # If present, save file '/usr/local/bin/F5_encrypted_password'
    if [ -f "/usr/local/bin/F5_encrypted_password" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/misc/usr/local/bin"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/misc/usr/local/bin>"
            return 1
        fi

        if ! copy_file "/usr/local/bin/F5_encrypted_password" "${ETC_ROOT}/misc/usr/local/bin"; then
            return 1
        fi
    fi

    # If present, save file '/usr/local/bin/F5FDBUpdate.sh'
    if [ -f "/usr/local/bin/F5FDBUpdate.sh" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/misc/usr/local/bin"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/misc/usr/local/bin>"
            return 1
        fi

        if ! copy_file "/usr/local/bin/F5FDBUpdate.sh" "${ETC_ROOT}/misc/usr/local/bin"; then
            return 1
        fi
    fi

    # If present, save file '/usr/local/bin/F5SNATUpdate.sh'
    if [ -f "/usr/local/bin/F5SNATUpdate.sh" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/misc/usr/local/bin"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/misc/usr/local/bin>"
            return 1
        fi

        if ! copy_file "/usr/local/bin/F5SNATUpdate.sh" "${ETC_ROOT}/misc/usr/local/bin"; then
            return 1
        fi
    fi

    # If present, save file '/etc/systemd/system/containerstartinorder.service'
    if [ -f "/etc/systemd/system/containerstartinorder.service" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/misc/etc/systemd/system"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/misc/etc/systemd/system>"
            return 1
        fi

        if ! copy_file "/etc/systemd/system/containerstartinorder.service" "${ETC_ROOT}/misc/etc/systemd/system"; then
            return 1
        fi
    fi

    # If present, save file '/etc/systemd/system/f5localfdbupdate.service'
    if [ -f "/etc/systemd/system/f5localfdbupdate.service" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/misc/etc/systemd/system"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/misc/etc/systemd/system>"
            return 1
        fi

        if ! copy_file "/etc/systemd/system/f5localfdbupdate.service" "${ETC_ROOT}/misc/etc/systemd/system"; then
            return 1
        fi
    fi

    # If present, save file '/etc/systemd/system/f5localfdbupdate.timer'
    if [ -f "/etc/systemd/system/f5localfdbupdate.timer" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/misc/etc/systemd/system"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/misc/etc/systemd/system>"
            return 1
        fi

        if ! copy_file "/etc/systemd/system/f5localfdbupdate.timer" "${ETC_ROOT}/misc/etc/systemd/system"; then
            return 1
        fi
    fi

    # If present, save file '/etc/systemd/system/snatfdbupdate.service'
    if [ -f "/etc/systemd/system/snatfdbupdate.service" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/misc/etc/systemd/system"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/misc/etc/systemd/system>"
            return 1
        fi

        if ! copy_file "/etc/systemd/system/snatfdbupdate.service" "${ETC_ROOT}/misc/etc/systemd/system"; then
            return 1
        fi
    fi

    # If present, save file '/etc/systemd/system/snatfdbupdate.timer'
    if [ -f "/etc/systemd/system/snatfdbupdate.timer" ]; then
        # Create directory
        if ! /bin/mkdir -m 0755 -p "${ETC_ROOT}/misc/etc/systemd/system"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/misc/etc/systemd/system>"
            return 1
        fi

        if ! copy_file "/etc/systemd/system/snatfdbupdate.timer" "${ETC_ROOT}/misc/etc/systemd/system"; then
            return 1
        fi
    fi

    return 0
}


#
# Save system configuration
#
save_sys_conf ()
{
    local sys_conf_file_list
    local sys_conf_file

    disp_msg $INFO "    saving sys conf ..."

    # Check to see if directory /etc/sysctl.d exists
    if [ -d "/etc/sysctl.d" ]; then

        # Create directory
        if ! /bin/mkdir -p "${ETC_ROOT}/sysctl.d"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/sysctl.d>"
            return 1
        fi

        # Get list of files under directory /etc/sysctl.d
        sys_conf_file_list=$( /bin/find /etc/sysctl.d -type f |/bin/xargs )

        for sys_conf_file in $sys_conf_file_list
        do
            if ! copy_file "$sys_conf_file" "${ETC_ROOT}/sysctl.d"; then
                return 1
            fi
        done

    fi

    if ! copy_file "/etc/sysctl.conf" "$ETC_ROOT"; then
        return 1
    fi

    return 0
}


#
# Save /etc/fstab
#
save_etc_fstab ()
{
    disp_msg $INFO "    saving /etc/fstab ..."

    if ! mkdir -p "$ETC_ROOT"; then
        disp_msg $ERROR "unable to create directory <$ETC_ROOT>"
        return 1
    fi

    if ! copy_file "/etc/fstab" "$ETC_ROOT"; then
        return 1
    fi

    return 0
}


#
# Save /etc/crypttab
#
save_etc_crypttab ()
{
    disp_msg $INFO "    saving /etc/crypttab ..."

    if ! mkdir -p "$ETC_ROOT"; then
        disp_msg $ERROR "unable to create directory <$ETC_ROOT>"
        return 1
    fi

    if ! copy_file "/etc/crypttab" "$ETC_ROOT"; then
        return 1
    fi

    return 0
}


#
# Save hostname
#
save_hostname ()
{
    disp_msg $INFO "    saving hostname ..."

    if ! /bin/mkdir -p "$ETC_ROOT"; then
        disp_msg $ERROR "unable to create directory <$ETC_ROOT>"
        return 1
    fi

    if ! copy_file "/etc/hostname" "$ETC_ROOT"; then
        return 1
    fi

    return 0
}


#
# Save /etc/hosts
#
save_etc_hosts ()
{
    disp_msg $INFO "    saving /etc/hosts ..."

    if ! /bin/mkdir -p "$ETC_ROOT"; then
        disp_msg $ERROR "unable to create directory <$ETC_ROOT>"
        return 1
    fi

    if ! copy_file "/etc/hosts" "$ETC_ROOT"; then
        return 1
    fi

    if [ -f "/etc/hosts.allow" ]; then
        if ! copy_file "/etc/hosts.allow" "$ETC_ROOT"; then
            return 1
        fi
    fi

    if [ -f "/etc/hosts.deny" ]; then
        if ! copy_file "/etc/hosts.deny" "$ETC_ROOT"; then
            return 1
        fi
    fi

    if [ -f "/etc/resolv.conf" ]; then
        if ! copy_file "/etc/resolv.conf" "$ETC_ROOT"; then
            return 1
        fi
    fi

    if [ -f "/etc/nsswitch.conf" ]; then
        if ! copy_file "/etc/nsswitch.conf" "$ETC_ROOT"; then
            return 1
        fi
    fi

    return 0
}


#
# Save container service files
#
save_container_service_files ()
{
    local container_list
    local container
    local service_files
    local service_file

    disp_msg $INFO "    saving container service files ..."

    # Verify docker is running
    if ! $DOCKER_APP ps > /dev/null 2>&1; then
        disp_msg $INFO "      unable to save container service files; requires docker service to be running"
        return 0
    fi

    if [ -d "${ETC_ROOT}/systemd/system" ]; then

        service_files=$( find ${ETC_ROOT}/systemd/system -maxdepth 1 -name "*.service*" )

        for service_file in $service_files
        do
            if ! delete_file "$service_file"; then
                return 1
            fi

        done

    else

        # Create directory
        if ! mkdir -p "$ETC_ROOT/systemd/system"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/systemd/system>"
            return 1
        fi

    fi

    # Get list of containers
    container_list=$( $DOCKER_APP ps --all |grep -v "^CONTAINER" |awk '{print $NF}' )

    running_container_list=$( $DOCKER_APP ps --format {{.Names}} > ${ETC_ROOT}/running_container.dat )

    for container in $container_list
    do
        if [ -f /etc/systemd/system/${container}.service ]; then

            copy_file "/etc/systemd/system/${container}.service" "${ETC_ROOT}/systemd/system"

        else
            if [ -f "/etc/systemd/system/${container}.service.masked" ]; then
                copy_file "/etc/systemd/system/${container}.service.masked" "${ETC_ROOT}/systemd/system"
            fi
        fi

    done

    return 0
}


#
# Save network configuration files
#
# $1 - network config file
#
save_ntp_configuration_files ()
{
    local timezone_file_path

    disp_msg $INFO "    saving NTP configuration ..."

    if [ -d "${ETC_ROOT}" ]; then

        # Check to see if /etc/localtime is a link to a timezone data file
        if [ -L "/etc/localtime" ]; then
            # Get timezone file path
            timezone_file_path=$( /bin/ls -l /etc/localtime |/bin/awk '{print $NF}' |/bin/sed -nr "s|^[^/]*(.*)$|\1|p" )

            # Check to see if file exists
            if [ -f "$timezone_file_path" ]; then
                # Save timezone
                disp_msg $INFO "        saving timezone file path <$timezone_file_path> to file </usr/local/etc/timezone>"
                echo "$timezone_file_path" > /usr/local/etc/timezone
            fi
        fi

        if ! copy_file "/etc/ntp.conf" "$ETC_ROOT"; then
            return 1
        fi

        /bin/mkdir -m 0755 -p "$ETC_ROOT/sysconfig"
        if ! copy_file "/etc/sysconfig/ntpd" "$ETC_ROOT/sysconfig"; then
            return 1
        fi

        /bin/mkdir -m 0755 -p "$ETC_ROOT/ntp"
        if ! copy_file "/etc/ntp/step-tickers" "$ETC_ROOT/ntp"; then
            return 1
        fi

        /bin/mkdir -m 0755 -p "$ETC_ROOT/logrotate.d"
        if [ -f "/etc/logrotate.d/ntpd" ]; then
            if ! copy_file "/etc/logrotate.d/ntpd" "$ETC_ROOT/logrotate.d"; then
                return 1
            fi
        fi

    fi

    return 0
}


#
# Save /etc/sysconfig files
#
save_sysconfig_files ()
{
    disp_msg $INFO "    saving /etc/sysconfig files ..."

    # Create directory
    if ! mkdir -p "${ETC_ROOT}/sysconfig"; then
        disp_msg $ERROR "unable to create directory <$ETC_ROOT/sysconfig>"
        return 1
    fi

    if [ -d "${ETC_ROOT}/sysconfig" ]; then

        if [ -f /etc/sysconfig/*.repo.conf ]; then
            disp_msg $INFO "        copying files </etc/sysconfig/*.repo.conf> to <${ETC_ROOT}/sysconfig>"
            /bin/cp -f /etc/sysconfig/*.repo.conf ${ETC_ROOT}/sysconfig
        fi

    fi

    return 0
}


#
# Save docker configuration files
#
save_docker_config ()
{
    disp_msg $INFO "    saving docker configuration ..."

    # Create directory
    if ! mkdir -p "${ETC_ROOT}/sysconfig"; then
        disp_msg $ERROR "unable to create directory <$ETC_ROOT/sysconfig>"
        return 1
    fi

    if [ -d "$ETC_ROOT/sysconfig" ]; then

        if ! copy_file "/etc/sysconfig/docker" "$ETC_ROOT/sysconfig"; then
            return 1
        fi

        if ! copy_file "/etc/sysconfig/docker-network" "$ETC_ROOT/sysconfig"; then
            return 1
        fi

        if ! copy_file "/etc/sysconfig/docker-registry" "$ETC_ROOT/sysconfig"; then
            return 1
        fi

        if ! copy_file "/etc/sysconfig/docker-storage" "$ETC_ROOT/sysconfig"; then
            return 1
        fi

        if ! copy_file "/etc/sysconfig/docker-storage-setup" "$ETC_ROOT/sysconfig"; then
            return 1
        fi

    fi

    return 0
}


#
# Save docker registry configuration files
#
save_docker_registry_config ()
{
    disp_msg $INFO "    saving docker registry configuration ..."

    # Copy directory
    if ! copy_folders "/etc/pki/ca-trust/source/anchors" "${ETC_ROOT}/registry/pki/ca-trust/source/anchors"; then
        return 1
    fi

    # Copy directory
    if ! copy_folders "/etc/pki/ca-trust/source/blacklist" "${ETC_ROOT}/registry/pki/ca-trust/source/blacklist"; then
        return 1
    fi

    # Copy directory
    if ! copy_folders "/usr/share/pki/ca-trust-source/anchors" "${ETC_ROOT}/registry/pki/ca-trust-source/anchors"; then
        return 1
    fi

    # Copy directory
    if ! copy_folders "/usr/share/pki/ca-trust-source/blacklist" "${ETC_ROOT}/registry/pki/ca-trust-source/blacklist"; then
        return 1
    fi

    # Copy directory
    if ! copy_folders "/var/lib/registry" "${ETC_ROOT}/registry/lib"; then
        return 1
    fi

    return 0
}



#
# Save network configuration files
#
# $1 - network config file
#
save_network_config ()
{
    local config_file="$1"
    local ifcfg_files
    local ifcfg_file
    local intf_list
    local intf
    local static_route_files
    local static_route_file

    disp_msg $INFO "    saving network configuration ..."


    # Get list of interfaces
    intf_list=$( ip link show |grep -E '^[0-9]+: ' |awk '{print $2}' |cut -d ':' -f1 |cut -d '@' -f1 )
    for intf in $intf_list
    do
        disp_msg $INFO "      interface <$intf>"
    done


    # Get list of interface configuration files
    ifcfg_files=$( find /etc/sysconfig/network-scripts -maxdepth 1 -name "ifcfg-*" )
    for ifcfg_file in $ifcfg_files
    do
        disp_msg $INFO "      interface configuration file <$ifcfg_file>"
    done


    # Delete existing interface configuration files
    if [ -d "${ETC_ROOT}/sysconfig/network-scripts" ]; then

        ifcfg_files=$( find ${ETC_ROOT}/sysconfig/network-scripts -maxdepth 1 -name "ifcfg-*" )

        for ifcfg_file in $ifcfg_files
        do

            if ! delete_file "$ifcfg_file"; then
                return 1
            fi

        done

    else

        if ! mkdir -p "${ETC_ROOT}/sysconfig/network-scripts"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/sysconfig/network-scripts>"
            return 1
        fi

    fi


    # Get list of interface configuration files
    ifcfg_files=$( find /etc/sysconfig/network-scripts -maxdepth 1 -name "ifcfg-*" )

    for ifcfg_file in $ifcfg_files
    do

        if ! copy_file "$ifcfg_file" "${ETC_ROOT}/sysconfig/network-scripts"; then
            return 1
        fi

    done


    # Delete existing static route configuration files
    if [ -d "${ETC_ROOT}/sysconfig/network-scripts" ]; then

        static_route_files=$( find ${ETC_ROOT}/sysconfig/network-scripts -maxdepth 1 -name "route-*" )

        for static_route_file in $static_route_files
        do

            if ! delete_file "$static_route_file"; then
                return 1
            fi

        done

    else

        if ! mkdir -p "${ETC_ROOT}/sysconfig/network-scripts"; then
            disp_msg $ERROR "unable to create directory <${ETC_ROOT}/sysconfig/network-scripts>"
            return 1
        fi

    fi


    # Get list of static route configuration files
    static_route_files=$( find /etc/sysconfig/network-scripts -maxdepth 1 -name "route-*" )

    for static_route_file in $static_route_files
    do
        if ! copy_file "$static_route_file" "${ETC_ROOT}/sysconfig/network-scripts"; then
            return 1
        fi

    done


    if ! copy_file "/etc/sysconfig/network" "${ETC_ROOT}/sysconfig"; then
        return 1
    fi


    if ! mkdir -p "${ETC_ROOT}/udev/rules.d"; then
        disp_msg $ERROR "unable to create directory <${ETC_ROOT}/udev/rules.d>"
        return 1
    fi


    if ! copy_file "/etc/udev/rules.d/71-persistent-kodiak.rules" "${ETC_ROOT}/udev/rules.d"; then
        return 1
    fi

    # Save IPv4 iptables
    if [ -f "/etc/sysconfig/iptables-config" ]; then

        if ! copy_file "/etc/sysconfig/iptables-config" "${ETC_ROOT}/sysconfig"; then
            return 1
        fi

        if ! copy_file "/etc/sysconfig/iptables" "${ETC_ROOT}/sysconfig"; then
            return 1
        fi

    fi

    # Save IPv6 iptables
    if [ -f "/etc/sysconfig/ip6tables-config" ]; then

        if ! copy_file "/etc/sysconfig/ip6tables-config" "${ETC_ROOT}/sysconfig"; then
            return 1
        fi

        if ! copy_file "/etc/sysconfig/ip6tables" "${ETC_ROOT}/sysconfig"; then
            return 1
        fi

    fi

    return 0
}


#
# Restore VM configuration
#
restore_configuration ()
{
    local tar_file
    local etc_root_dir="${ETC_ROOT}"

    disp_msg $INFO "  restoring VM configuration ..."

    # Check for root directory
    if [ ! -d "${etc_root_dir}" ]; then
        disp_msg $ERROR "root restore configuration directory <$etc_root_dir> not found"
        return 1
    fi

    # Restore system configuration
    if ! restore_sys_conf "$etc_root_dir"; then
        return 1
    fi

    # Restore /etc/fstab
    if ! restore_etc_fstab "$etc_root_dir"; then
        return 1
    fi

    # Restore /etc/crypttab
    if ! restore_etc_crypttab "$etc_root_dir"; then
        return 1
    fi

    # Restore hostname
    if ! restore_hostname "$etc_root_dir"; then
        return 1
    fi

    # Restore /etc/hosts
    if ! restore_etc_hosts "$etc_root_dir"; then
        return 1
    fi

    # Restore network configuration
    if ! restore_network_config "$etc_root_dir"; then
        return 1
    fi

    # Restore NTP configuration
    if ! restore_ntp_configuration "$etc_root_dir"; then
        return 1
    fi

    # Restore docker configuration files
    if ! restore_docker_config_files "$etc_root_dir"; then
        return 1
    fi

    # Restore docker registry configuration files
    if ! restore_docker_registry_files "$etc_root_dir"; then
        return 1
    fi

    # Restore container systemd service files
    if ! restore_container_service_files "$etc_root_dir"; then
        return 1
    fi

    # Restore /etc/sysconfig files
    if ! restore_sysconfig_files "$etc_root_dir"; then
        return 1
    fi
    # Restore sophos file
    if ! restore_sophos_files "$etc_root_dir"; then
        return 1
    fi
    # Restore miscellaneous items
    if ! restore_misc_items "$etc_root_dir"; then
        return 1
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
# Restore miscellaneous items
#
# $1 - root directory
#
restore_misc_items ()
{
    local etc_root_dir="$1"

    disp_msg $INFO "    restoring miscellaneous items ..."

        if [ -f "${etc_root_dir}/misc/usr/local/bin/contentinfo" ]; then
        if ! copy_file "${etc_root_dir}/misc/usr/local/bin/contentinfo" "/usr/local/bin"; then
            return 1
        fi
    fi

    if [ -f "${etc_root_dir}/misc/usr/local/bin/ContainerstartInOrder.sh" ]; then
        if ! copy_file "${etc_root_dir}/misc/usr/local/bin/ContainerstartInOrder.sh" "/usr/local/bin"; then
            return 1
        fi
    fi

    if [ -f "${etc_root_dir}/misc/etc/systemd/system/containerstartinorder.service" ]; then
        if ! copy_file "${etc_root_dir}/misc/etc/systemd/system/containerstartinorder.service" "/etc/systemd/system"; then
            return 1
        fi

        # Enable service
        /bin/systemctl enable containerstartinorder.service
    fi

    if [ -f "${etc_root_dir}/misc/usr/local/bin/F5_encrypted_password" ]; then
        if ! copy_file "${etc_root_dir}/misc/usr/local/bin/F5_encrypted_password" "/usr/local/bin"; then
            return 1
        fi
    fi

    if [ -f "${etc_root_dir}/misc/usr/local/bin/F5FDBUpdate.sh" ]; then
        if ! copy_file "${etc_root_dir}/misc/usr/local/bin/F5FDBUpdate.sh" "/usr/local/bin"; then
            return 1
        fi
    fi

    if [ -f "${etc_root_dir}/misc/etc/systemd/system/f5localfdbupdate.timer" ]; then
        if ! copy_file "${etc_root_dir}/misc/etc/systemd/system/f5localfdbupdate.timer" "/etc/systemd/system"; then
            return 1
        fi

        # Enable timer
        /bin/systemctl enable f5localfdbupdate.timer
    fi

    if [ -f "${etc_root_dir}/misc/etc/systemd/system/f5localfdbupdate.service" ]; then
        if ! copy_file "${etc_root_dir}/misc/etc/systemd/system/f5localfdbupdate.service" "/etc/systemd/system"; then
            return 1
        fi

        # Enable service
        /bin/systemctl enable f5localfdbupdate.service
    fi

    if [ -f "${etc_root_dir}/misc/usr/local/bin/F5SNATUpdate.sh" ]; then
        if ! copy_file "${etc_root_dir}/misc/usr/local/bin/F5SNATUpdate.sh" "/usr/local/bin"; then
            return 1
        fi
    fi

    if [ -f "${etc_root_dir}/misc/etc/systemd/system/snatfdbupdate.timer" ]; then
        if ! copy_file "${etc_root_dir}/misc/etc/systemd/system/snatfdbupdate.timer" "/etc/systemd/system"; then
            return 1
        fi

        # Enable timer
        /bin/systemctl enable snatfdbupdate.timer
    fi

    if [ -f "${etc_root_dir}/misc/etc/systemd/system/snatfdbupdate.service" ]; then
        if ! copy_file "${etc_root_dir}/misc/etc/systemd/system/snatfdbupdate.service" "/etc/systemd/system"; then
            return 1
        fi

        # Enable service
        /bin/systemctl enable snatfdbupdate.service
    fi

    return 0
}


#
# Restore system configuration
#
# $1 - root directory
#
restore_sys_conf ()
{
    local etc_root_dir="$1"
    local sys_conf_file_list
    local sys_conf_file

    disp_msg $INFO "    restoring sys conf ..."

    if [ -d "${etc_root_dir}/sysctl.d" ]; then

        # Get list of files under directory /etc/sysctl.d
        sys_conf_file_list=$( /bin/find "${etc_root_dir}/sysctl.d" -type f |/bin/xargs )

        for sys_conf_file in $sys_conf_file_list
        do
            if ! copy_file "$sys_conf_file" "/etc/sysctl.d"; then
                return 1
            fi
        done
    else
        disp_msg $INFO "        directory <${etc_root_dir}/sysctl.d> not found"
    fi

    # Copy file
    if [ -f "${etc_root_dir}/sysctl.conf" ]; then
        if ! copy_file "${etc_root_dir}/sysctl.conf" "/etc"; then
            return 1
        fi
    else
        disp_msg $INFO "        file <${etc_root_dir}/sysctl.conf> not found"
    fi

    # Load system configuration
    if ! /sbin/sysctl --system > /dev/null 2>&1; then
        disp_msg $ERROR "unable to load system configuration"
        return 1
    else
        disp_msg $INFO "        loaded system configuration (executed command 'sysctl --system')"
    fi

    return 0
}


#
# Restore timezone
#
# $1 - root directory
#
restore_timezone ()
{
    local etc_root_dir="$1"
    local timezone_file_path

    # Check to see if file containing timezone file path exists
    if [ -f "${etc_root_dir}/timezone" ]; then

        # Get file path to timezone data file
        timezone_file_path=$( cat "${etc_root_dir}/timezone" )

        # Delete file /etc/localtime
        /bin/rm -f /etc/localtime

        # Set link to timezone data file
        if ! /bin/ln -s "$timezone_file_path" /etc/localtime; then
            disp_msg $ERROR "unable to set link from </etc/localtime> to <$timezone_file_path>"
            return 1
        else
            disp_msg $INFO "        linked </etc/localtime> to <$timezone_file_path>"
        fi

    else
        disp_msg $INFO "        file <${etc_root_dir}/timezone> not found"
    fi

    return 0
}


#
# Restore /etc/fstab
#
# $1 - root directory
#
restore_etc_fstab ()
{
    local etc_root_dir="$1"

    disp_msg $INFO "    restoring /etc/fstab ..."

    # Copy file from thin pool storage
    if [ -f "${etc_root_dir}/fstab" ]; then
        if ! copy_file "${etc_root_dir}/fstab" "/etc"; then
            return 1
        fi
    else
        disp_msg $INFO "        file <${etc_root_dir}/fstab> not found"
    fi

    return 0
}


#
# Restore /etc/crypttab
#
# $1 - root directory
#
restore_etc_crypttab ()
{
    local etc_root_dir="$1"

    disp_msg $INFO "    restoring /etc/crypttab ..."

    # Copy file from thin pool storage
    if [ -f "${etc_root_dir}/crypttab" ]; then
        if ! copy_file "${etc_root_dir}/crypttab" "/etc"; then
            return 1
        fi
    else
        disp_msg $INFO "        file <${etc_root_dir}/crypttab> not found"
    fi

    return 0
}


#
# Restore hostname
#
#
# $1 - root directory
#
restore_hostname ()
{
    local etc_root_dir="$1"
    local host_name

    disp_msg $INFO "    restoring hostname ..."

    if [ -f "${etc_root_dir}/hostname" ]; then

        host_name=$( cat ${etc_root_dir}/hostname )

        if ! /bin/hostnamectl set-hostname "$host_name"; then
            disp_msg $ERROR "unable to set hostname to <$host_name>"
            return 1
        fi

    else
        disp_msg $INFO "        file <${etc_root_dir}/hostname> not found"
    fi

    return 0
}


#
# Restore /etc/hosts
#
# $1 - root directory
#
restore_etc_hosts ()
{
    local etc_root_dir="$1"
    local host_name

    disp_msg $INFO "    restoring /etc/hosts ..."

    if [ -f "${etc_root_dir}/hosts" ]; then

        copy_file "${etc_root_dir}/hosts" "/etc"

    else
        disp_msg $INFO "        file <${etc_root_dir}/hosts> not found"
    fi

    if [ -f "${etc_root_dir}/hosts.allow" ]; then

        copy_file "${etc_root_dir}/hosts.allow" "/etc"

    else
        disp_msg $INFO "        file <${etc_root_dir}/hosts.allow> not found"
    fi

    if [ -f "${etc_root_dir}/hosts.deny" ]; then

        copy_file "${etc_root_dir}/hosts.deny" "/etc"

    else
        disp_msg $INFO "        file <${etc_root_dir}/hosts.deny> not found"
    fi

    if [ -f "${etc_root_dir}/resolv.conf" ]; then

        copy_file "${etc_root_dir}/resolv.conf" "/etc"

    else
        disp_msg $INFO "        file <${etc_root_dir}/resolv.conf> not found"
    fi

    if [ -f "${etc_root_dir}/nsswitch.conf" ]; then

        copy_file "${etc_root_dir}/nsswitch.conf" "/etc"

    else
        disp_msg $INFO "        file <${etc_root_dir}/nsswitch.conf> not found"
    fi

    return 0
}


#
# Restore container service files
#
#
# $1 - root directory
#
restore_container_service_files ()
{
    local etc_root_dir="$1"

    local service_files
    local service_file
    local service
    local running_state
    local container_name

    disp_msg $INFO "    restoring container systemd service files ..."

    service_files=$( find ${etc_root_dir}/systemd/system -maxdepth 1 -name "*.service*" 2>/dev/null )

    for service_file in $service_files

    do
        service=${service_file##*/}
        # Copy container service file from thin pool storage

        copy_file "${service_file}" "/etc/systemd/system"

        # Enable/Disable/Masking container service

        if [ -f "${etc_root_dir}/running_container.dat" ]; then

            running_state=$( cat "${etc_root_dir}/running_container.dat" )

            container_name=${service%.service*}

            if [[ "${running_state[@]}" =~ "${container_name}" ]]; then

                disp_msg $INFO "    Enablig service $service"

                systemctl enable "$service"

            elif [[ "$service" =~ .*masked.* ]]; then

                service=$( echo ${service%.masked} )

                disp_msg $INFO "    masking $service"

                systemctl mask "$service"

            else

                disp_msg $INFO "    Disabling service $service"

                systemctl disable "$service"

            fi

        else

            disp_msg $INFO "    Enabling service $service"

            systemctl enable "$service"

        fi

    done

    return 0
}


#
# Restore /etc/sysconfig files
#
# $1 - root directory
#
restore_sysconfig_files ()
{
    local etc_root_dir="$1"

    disp_msg $INFO "    restoring /etc/sysconfig files ..."

    if [ -f ${etc_root_dir}/sysconfig/*.repo.conf ]; then
        disp_msg $INFO "        copying files <${etc_root_dir}/sysconfig/*.repo.conf> to </etc/sysconfig>"
        /bin/cp -f ${etc_root_dir}/sysconfig/*.repo.conf /etc/sysconfig
    fi

    return 0
}


#
# Restore docker configuration files
#
# $1 - root directory
#
restore_docker_config_files ()
{
    local etc_root_dir="$1"

    disp_msg $INFO "    restoring docker configuration ..."

    # Restore docker configuration file
    if [ -f "${etc_root_dir}/sysconfig/docker" ]; then
        if ! copy_file "${etc_root_dir}/sysconfig/docker" "/etc/sysconfig"; then
            return 1
        fi
    else
        disp_msg $INFO "        file <${etc_root_dir}/sysconfig/docker> not found"
    fi

    # Restore docker configuration file
    if [ -f "${etc_root_dir}/sysconfig/docker-network" ]; then
        if ! copy_file "${etc_root_dir}/sysconfig/docker-network" "/etc/sysconfig"; then
            return 1
        fi
    else
        disp_msg $INFO "        file <${etc_root_dir}/sysconfig/docker-network> not found"
    fi

    # Restore docker configuration file
    if [ -f "${etc_root_dir}/sysconfig/docker-registry" ]; then
        if ! copy_file "${etc_root_dir}/sysconfig/docker-registry" "/etc/sysconfig"; then
            return 1
        fi
    else
        disp_msg $INFO "        file <${etc_root_dir}/sysconfig/docker-registry> not found"
    fi

    # Restore docker configuration file
    if [ -f "${etc_root_dir}/sysconfig/docker-storage" ]; then
        if ! copy_file "${etc_root_dir}/sysconfig/docker-storage" "/etc/sysconfig"; then
            return 1
        fi
    else
        disp_msg $INFO "        file <${etc_root_dir}/sysconfig/docker-storage> not found"
    fi

    # Restore docker configuration file
    if [ -f "${etc_root_dir}/sysconfig/docker-storage-setup" ]; then
        if ! copy_file "${etc_root_dir}/sysconfig/docker-storage-setup" "/etc/sysconfig"; then
            return 1
        fi
    else
        disp_msg $INFO "        file <${etc_root_dir}/sysconfig/docker-storage-setup> not found"
    fi

    return 0
}


#
# Restore docker registry configuration files
#
# $1 - root directory
#
restore_docker_registry_files ()
{
    local etc_root_dir="$1"

    disp_msg $INFO "    restoring docker registry configuration ..."

    # Copy directories
    if ! copy_folders "${etc_root_dir}/registry/lib" "/var/lib/registry"; then
        return 1
    fi

    # Copy directories
    if ! copy_folders "${etc_root_dir}/registry/pki/ca-trust/source/anchors" "/etc/pki/ca-trust/source/anchors" ; then
        return 1
    fi


    # Copy directories
    if ! copy_folders "${etc_root_dir}/registry/pki/ca-trust/source/blacklist" "/etc/pki/ca-trust/source/blacklist"; then
        return 1
    fi

    # Copy directories
    if ! copy_folders "${etc_root_dir}/registry/pki/ca-trust-source/anchors" "/usr/share/pki/ca-trust-source/anchors"; then
        return 1
    fi

    # Copy directories
    if ! copy_folders "${etc_root_dir}/registry/pki/ca-trust-source/blacklist" "/usr/share/pki/ca-trust-source/blacklist"; then
        return 1
    fi

    # Update ca-trust
    /bin/update-ca-trust

    return 0
}


#
# Restore NTP configuration files
#
# $1 - root directory
#
restore_ntp_configuration ()
{
    local etc_root_dir="$1"

    disp_msg $INFO "    restoring NTP configuration ..."

    if [ -f "${etc_root_dir}/ntp.conf" ]; then
        if ! copy_file "${etc_root_dir}/ntp.conf" "/etc"; then
            return 1
        fi
    else
        disp_msg $INFO "        file <${etc_root_dir}/ntp.conf> not found"
    fi

    if [ -f "${etc_root_dir}/sysconfig/ntpd" ]; then
        if ! copy_file "${etc_root_dir}/sysconfig/ntpd" "/etc/sysconfig"; then
            return 1
        fi
    else
        disp_msg $INFO "        file <${etc_root_dir}/sysconfig/ntpd> not found"
    fi

    if [ -f "${etc_root_dir}/ntp/step-tickers" ]; then
        if ! copy_file "${etc_root_dir}/ntp/step-tickers" "/etc/ntp"; then
            return 1
        fi
    else
        disp_msg $INFO "        file <${etc_root_dir}/ntp/step-tickers> not found"
    fi

    if [ -f "${etc_root_dir}/logrotate.d/ntpd" ]; then
        if ! copy_file "${etc_root_dir}/logrotate.d/ntpd" "/etc/logrotate.d"; then
            return 1
        fi
    else
        disp_msg $INFO "        file <${etc_root_dir}/logrotate.d/ntpd> not found"
    fi

    # Restore timezone
    if ! restore_timezone "$etc_root_dir"; then
        return 1
    fi

    return 0
}


#
# Restore network configuration
#
# $1 - root directory
#
restore_network_config ()
{
    local etc_root_dir="$1"

    local ifcfg_files
    local ifcfg_file
    local static_route_files
    local static_route_file
    local route_cfg
    local ifcfg_file
    local ifcfg
    local link_list
    local link

    disp_msg $INFO "    restoring network configuration ..."

    # Get list of interfaces
    intf_list=$( ip link show |grep -E '^[0-9]+:' |awk '{print $2}' |cut -d ':' -f1 |cut -d '@' -f1 )

    # Get list of 'ifcfg-*' files to restore
    ifcfg_files=$( find ${etc_root_dir}/sysconfig/network-scripts -maxdepth 1 -name "ifcfg-*" )

    if [ -n "$ifcfg_files" ]; then

        # Create tempory directory for existing interface configuration files
        /bin/mkdir -m 0755 -p /etc/sysconfig/network-scripts/save

        for intf in $intf_list
        do
            disp_msg $INFO "      interface is <$intf>"

            if [ -f "/etc/sysconfig/network-scripts/ifcfg-${intf}" ]; then
                move_file "/etc/sysconfig/network-scripts/ifcfg-${intf}" "/etc/sysconfig/network-scripts/save"
            fi

        done
    fi

    # Restore interface configuration 'ifcfg-*' files
    for ifcfg_file in $ifcfg_files
    do

        if ! copy_file "$ifcfg_file" "/etc/sysconfig/network-scripts"; then
            return 1
        fi

    done


    # Restore static route configuration 'route-*' files
    static_route_files=$( find ${etc_root_dir}/sysconfig/network-scripts -maxdepth 1 -name "route-*" )

    for static_route_file in $static_route_files
    do

        if ! copy_file "$static_route_file" "/etc/sysconfig/network-scripts"; then
            return 1
        fi

    done


    if [ -f "${etc_root_dir}/sysconfig/network" ]; then

        if ! copy_file "${etc_root_dir}/sysconfig/network" "/etc/sysconfig"; then
            return 1
        fi

    else
        disp_msg $INFO "        file <${etc_root_dir}/sysconfig/network> not found"
    fi


    if [ -f "${etc_root_dir}/udev/rules.d/71-persistent-kodiak.rules" ]; then

        if ! copy_file "${etc_root_dir}/udev/rules.d/71-persistent-kodiak.rules" "/etc/udev/rules.d"; then
            return 1
        fi

    else
        disp_msg $INFO "        file <${etc_root_dir}/udev/rules.d/71-persistent-kodiak.rules> not found"
    fi

    # Restore IPv4 iptables
    if [ -f "${etc_root_dir}/sysconfig/iptables-config" ]; then

        if ! copy_file "${etc_root_dir}/sysconfig/iptables-config" "/etc/sysconfig"; then
            return 1
        fi

        if ! copy_file "${etc_root_dir}/sysconfig/iptables" "/etc/sysconfig"; then
            return 1
        fi

    else
        disp_msg $INFO "        file <${etc_root_dir}/sysconfig/iptables-config> not found"
    fi

    # Restore IPv6 iptables
    if [ -f "${etc_root_dir}/sysconfig/ip6tables-config" ]; then

        if ! copy_file "${etc_root_dir}/sysconfig/ip6tables-config" "/etc/sysconfig"; then
            return 1
        fi

        if ! copy_file "${etc_root_dir}/sysconfig/ip6tables" "/etc/sysconfig"; then
            return 1
        fi

    else
        disp_msg $INFO "        file <${etc_root_dir}/sysconfig/ip6tables-config> not found"
    fi


    if [[ $NETWORK_RESTART_FLAG -ne 0 ]]; then
        # Restart networking
        disp_msg $INFO "      restart networking"
        if ! systemctl restart network.service; then
            disp_msg $ERROR "unable to restart networking"
            return 1
        fi
    fi


    return 0
}


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
    if ! /bin/cp -f "$filepath" "$destination"; then
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



#
# Set VM's configuration state
#
# $1 - state
#
set_config_state ()
{
    local state=$1
    local file_path="${ETC_ROOT}/vm_config_state.txt"

    if [ -d "${ETC_ROOT}" ]; then

        disp_msg $INFO "Setting VM configuration state to <$state>"

        if [[ $state -eq 0 ]]; then
            echo "OK" > "$file_path"
        else
            echo "FAIL" > "$file_path"
        fi

    else
        disp_msg $INFO "unable to set VM's configuration state; directory <${ETC_ROOT}> not found"
        return 1
    fi

    return 0
}


#
# Check VM's configuration state
#
check_config_state ()
{
    local state
    local file_path="${ETC_ROOT}/vm_config_state.txt"
    local retval=1

    # Check if file exists
    if [ -f "$file_path" ]; then

        # Get configuration state
        state=$( cat "$file_path" )

        case $state in

            OK)
                disp_msg $INFO "VM configuration state is OK"
                retval=0
                ;;

            *)
                disp_msg $INFO "VM configuration state is FAIL"
                ;;

        esac

    else
        disp_msg $INFO "VM configuration state file <$file_path> not found (configuration may be from older version)"
        retval=0
    fi

    return $retval
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

        # Set VM's configuration state to fail
        if ! set_config_state 1; then
            cleanup_and_exit 1
        fi

        # Save configuration
        save_configuration "$SUBSYSTEM" "$CONFIG_FILE"

        RETURN_VAL=$?

        if [ $RETURN_VAL -ne 0 ]; then
            cleanup_and_exit $RETURN_VAL
        fi

        # Set VM's configuration state to OK
        if ! set_config_state 0; then
            cleanup_and_exit 1
        fi
        ;;


    RESTORE|restore)

        disp_msg $INFO "Restore VM configuration from thin pool storage"

        # Check VM's configuration state
        if ! check_config_state; then
            cleanup_and_exit $RETURN_VAL
        fi

        # Restore configuration
        restore_configuration

        RETURN_VAL=$?

        if [ $RETURN_VAL -ne 0 ]; then
            cleanup_and_exit $RETURN_VAL
        fi
        ;;


    STATE|state)

        disp_msg $INFO "Set VM configuration state"

        CONFIG_STATE="$2"

        if [ -z "$CONFIG_STATE" ]; then
            CONFIG_STATE=1
        fi

        # Set VM's configuration state
        if ! set_config_state $CONFIG_STATE; then
            cleanup_and_exit 1
        fi
        ;;


    *)
        disp_msg $ERROR "CMD <$CMD> not found"
        usage 1
        ;;

esac


# Exit
cleanup_and_exit 0
