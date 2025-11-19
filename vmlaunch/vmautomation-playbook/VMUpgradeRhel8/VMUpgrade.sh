#!/bin/bash
#
# Copyright Motorola Solutions, Inc. and/or Kodiak Networks, Inc.
# All Rights Reserved
# Motorola Solutions Confidential Restricted
#

#!/bin/bash
# Author - Naveen Eruvaram
# Date - 14-05-2018
# Script to upgrade VMs using ansible playbooks
# $1 = <operation type> [1: Upgrade|0: Rollback]
# $2 = <VM IP>

export HOME=/root
LOGFILE=/var/log/VMUpgrade.log

[ $# -lt 4 ] && echo "Usage: $0 <Operation(Upgrade-1/Rollback-0)> <VM IPaddress > <VMName> <HostIP>" && exit 1

OPTION=$1
VMIPADDR=$2
VMName=$3
HOSTIP=$4
confile=/etc/kodiakEMS.conf
TTPath=/opt/TimesTen/kodiak/bin
ROOT_DIR=/usr/local/bin/vmautomation-playbook/VMUpgradeRhel8
ALL_VARS=$ROOT_DIR/playbooks/group_vars/all
INVENTORY="$ROOT_DIR/inventory"
Qcow2DatFile=$ROOT_DIR/qcow2details.dat
InputFile=/usr/local/bin/vmautomation-playbook/input.yml

echo "`date +%x_%H:%M:%S:%3N`: OPTION: $OPTION, VMIPADDR: $VMIPADDR" >>$LOGFILE 2>>$LOGFILE

SourceConfig()
{
    if [ ! -s ${confile} ]; then
        echo "`date +%x_%H:%M:%S:%3N`: ${confile}  do not exists!! Hence exiting..." |tee -a $LOGFILE
        exit 1
    fi

    source $confile >>$LOGFILE 2>>$LOGFILE
    export LD_LIBRARY_PATH=/opt/TimesTen/kodiak/lib:$LD_LIBRARY_PATH
    echo "`date +%x_%H:%M:%S:%3N`: Local EMSIP: $EMSIP" >>$LOGFILE
}


[ ! -s $Qcow2DatFile ] && echo "$Qcow2DatFile does not exists!!" >>$LOGFILE && exit 1
if [ $OPTION == 1 ]; then
    QCOW2FILE=`cat $Qcow2DatFile |grep VM_UPGRADE_QCOW2|cut -d '=' -f2` 2>>$LOGFILE
elif [ $OPTION == 0 ]; then
    QCOW2FILE=`cat $Qcow2DatFile |grep VM_ROLLBACK_QCOW2|cut -d '=' -f2` 2>>$LOGFILE
else
    echo "`date +%x_%H:%M:%S:%3N`: Invalid option provided..." >>$LOGFILE
    exit 1
fi

[ ! -f $QCOW2FILE ] && echo "$QCOW2FILE file not found" >>$LOGFILE && exit 1
echo "`date +%x_%H:%M:%S:%3N`: QCOW2FILE: $QCOW2FILE" >>$LOGFILE 2>>$LOGFILE

UpgRel=`cat $Qcow2DatFile |grep "UPG_RELEASE=" |cut -d '=' -f2` 2>>$LOGFILE
CurRel=`cat $Qcow2DatFile |grep "CUR_RELEASE=" |cut -d '=' -f2` 2>>$LOGFILE
#RepoIP=$( cat $Qcow2DatFile | grep "REPO_IP=" | cut -d '=' -f2 ) >> $LOGFILE
upg_user=$( cat $Qcow2DatFile | grep "UPG_USER=" | cut -d '=' -f2 ) >> $LOGFILE
lv_size=$( cat $Qcow2DatFile | grep "LV_SIZE=" | cut -d '=' -f2 ) >> $LOGFILE
if grep -q "REPO_CERTIFICATE_DOMAIN" $Qcow2DatFile;then
    certificate_domain=$( cat $Qcow2DatFile | grep "REPO_CERTIFICATE_DOMAIN" | cut -d '=' -f2 ) >> $LOGFILE
else
    certificate_domain="update-repo.kodiak.repo"
fi
repository_name=$( cat $Qcow2DatFile | grep "REPOSITORY_NAME=" | cut -d '=' -f2 ) >> $LOGFILE

#VMName=`echo $VMData | cut -d ',' -f1`
#HOSTIP=`echo $VMData | cut -d ',' -f2`
#VMName=`cat $InputFile | grep -B 10 "$VMIPADDR"  | grep -w "name" | cut -d ":" -f2 | xargs`
#HOSTIP=`cat $InputFile | grep -B 10 "$VMIPADDR"  | grep -w "hostip" | cut -d ":" -f2 | xargs`
echo "`date +%x_%H:%M:%S:%3N`: VMNAME: $VMName HOSTIP: $HOSTIP" >>$LOGFILE 2>>$LOGFILE

#if [ $OPTION == 1 ]; then
    #nc -z $VMIPADDR 22 -w 5 >>$LOGFILE 2>>$LOGFILE
#    [ $? -ne 0 ] && echo "`date +%x_%H:%M:%S:%3N`: VM: $VMIPADDR is not connecting.." >>$LOGFILE && exit 1
#fi

nc -z $HOSTIP 22 -w 5 >>$LOGFILE 2>>$LOGFILE
[ $? -ne 0 ] && echo "`date +%x_%H:%M:%S:%3N`: VM: $HOSTIP is not connecting.." >>$LOGFILE && exit 1

INVENTORY=$INVENTORY'_'$VMIPADDR

echo "creating inventory file..." >>$LOGFILE
[ -s "$INVENTORY" ] && rm -vf $INVENTORY >>$LOGFILE 2>>$LOGFILE
echo -e "[bare_metal_hosts]\n$HOSTIP\n[vm_hosts]\n$VMIPADDR" >> $INVENTORY

echo  'true' > /home/autoinstall/check_status_$VMIPADDR 2>>$LOGFILE

echo -e "\n[all:vars]\ncheck_status_file=check_status_$VMIPADDR\nvm_name=$VMName" >> $INVENTORY
#export OS_PATCH_HOST_TYPE='host_vm'
#export OS_PATCH_HOST_LIST=$HOSTIP
#export OS_PATCH_VM_LIST=$VMIPADDR

qcow2_name=$(basename -- "$QCOW2FILE")
sed -i "s|^qcow2:.*|qcow2: $QCOW2FILE|g" $ALL_VARS 2>>$LOGFILE
#sed -i "s/^vm_name:.*/vm_name: $VMName/g" $ALL_VARS 2>>$LOGFILE
sed -i "s/^qcow2_name:.*/qcow2_name: $qcow2_name/g" $ALL_VARS 2>>$LOGFILE
sed -i "s/^req_vm_patch:.*/req_vm_patch: $CurRel/g" $ALL_VARS 2>>$LOGFILE
sed -i "s/^release_vm_patch:.*/release_vm_patch: $UpgRel/g" $ALL_VARS 2>>$LOGFILE
#sed -i "s/^repo_ip:.*/repo_ip: $RepoIP/g" $ALL_VARS 2>>$LOGFILE
sed -i "s/^upg_user:.*/upg_user: $upg_user/g" $ALL_VARS 2>>$LOGFILE
#sed -i "s/^certificate_domain:.*/certificate_domain: $certificate_domain/g" $ALL_VARS 2>>$LOGFILE
#sed -i "s/^repository_name:.*/repository_name: $repository_name/g" $ALL_VARS 2>>$LOGFILE
sed -i "s/^lv_size:.*/lv_size: $lv_size/g" $ALL_VARS 2>>$LOGFILE
sed -i "s/^UpgradeType:.*/UpgradeType: $3/g" "$ALL_VARS" 2>>"$LOGFILE"

cd $ROOT_DIR >>$LOGFILE 2>>$LOGFILE

if [ $OPTION == 1 ]; then
    echo "`date +%x_%H:%M:%S:%3N`: Executing VM UPGRADE.." >>$LOGFILE 2>>$LOGFILE
    ansible-playbook -i $INVENTORY $ROOT_DIR/playbooks/vm_upgrade_thinvolume.yml >>$LOGFILE 2>>$LOGFILE
    if [ $? -eq 0 ]; then
        echo "`date +%x_%H:%M:%S:%3N`: VM Upgraded successfully." >>$LOGFILE
    else
        echo "`date +%x_%H:%M:%S:%3N`: VM Upgrade failed!!" >>$LOGFILE
        exit 1
    fi

elif [ $OPTION == 0 ]; then
    echo "`date +%x_%H:%M:%S:%3N`: Executing VM ROLLBACK.." >>$LOGFILE 2>>$LOGFILE
    ansible-playbook -i $INVENTORY $ROOT_DIR/playbooks/vm_rollback_thinvolume.yml >>$LOGFILE 2>>$LOGFILE
    if [ $? -eq 0 ]; then
        echo "`date +%x_%H:%M:%S:%3N`: VM Rollback executed successfully." >>$LOGFILE
    else
        echo "`date +%x_%H:%M:%S:%3N`: VM Rollback failed!!" >>$LOGFILE
        exit 1
    fi
else
    echo "`date +%x_%H:%M:%S:%3N`: Invalid option provided..." >>$LOGFILE
    exit 1
fi

[ -s "$INVENTORY" ] && rm -vf $INVENTORY >>$LOGFILE
[ -s "/home/autoinstall/check_status_$VMIPADDR" ] && rm -vf /home/autoinstall/check_status_$VMIPADDR >>$LOGFILE

exit 0

