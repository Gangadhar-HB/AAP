#
# Copyright Motorola Solutions, Inc. and/or Kodiak Networks, Inc.
# All Rights Reserved
# Motorola Solutions Confidential Restricted
#

import sys
import os
import warnings
import subprocess
import threading
import yaml
import logging


# Configure logging
logging.basicConfig(
    filename = '/var/log/VMPatchUpgrade.log',
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

inputfile = '/usr/local/bin/vmautomation-playbook/input.yml'
status_dict = {}  # Corrected to dictionary
failed_vms = []

def Cleanup(msg, Status):
    logging.error(msg)
    print(msg)
    sys.exit(Status)

def PrintLog(msg):
    logging.info(msg)
    print(msg)

def upgrade_vm(vmip, name, hostip):
    PrintLog(f"Upgrading VM '{name}' with Hostip: {hostip} and VMIP: {vmip}")
    try:
        result = subprocess.run(
            ["sh", "/usr/local/bin/vmautomation-playbook/VMUpgradeRhel8/VMUpgrade.sh", "1", vmip, name, hostip],
            check=True
        )
        if result.returncode != 0:
            PrintLog(f"Failed to perform VMUpgrade for VMIP: {vmip}")
            status_dict[vmip] = "Failed"
        else:
            PrintLog(f"VMUpgrade is successful for VMIP: {vmip}")
            status_dict[vmip] = "Success"
    except subprocess.CalledProcessError as e:
        status_dict[vmip] = f"Error: {e}"

def get_vmip():
    with open(inputfile) as userfile:
        data = yaml.safe_load(userfile)
    vm_data = {}

    for vm in data.get('vms', []):
        vm_type = vm.get('vm_type', '').lower()
        if 'f5' not in vm_type:
            name = vm.get('name')
            hostip = vm.get('hostip')
            for iface in vm.get('networkInterface', []):
                if 'gw' in iface:
                    ip = iface.get('ipaddress')
                    if ip:
                        ip = ip.split('/')[0]
                        vm_data[ip] = (name, hostip)

    PrintLog(f"VM IPs, names, and hostips found from input file are: {vm_data}")

    if not vm_data:
        Cleanup("No VM IPs found for the given ClusterID.", 1)

    batch_size = 7
    vm_ips = list(vm_data.keys())
    idx = 0
    total = len(vm_ips)
    while idx < total:
        threads = []
        batch = vm_ips[idx:idx + batch_size]
        PrintLog(f"Processing batch: {batch}")
        for vmip in batch:
            name, hostip = vm_data[vmip]
            thread = threading.Thread(target=upgrade_vm, args=(vmip, name, hostip))
            thread.start()
            threads.append(thread)
        for thread in threads:
            thread.join()
        for vmip in batch:
            status = status_dict.get(vmip, 'Unknown')
            PrintLog(f"VMIP {vmip} status: {status}")
            if status == "Failed" or (isinstance(status, str) and status.startswith("Error")):
                failed_vms.append(vmip)
        idx += batch_size
    if failed_vms:
        Cleanup(f"Upgrade failed for the following VMIPs: {', '.join(failed_vms)}.Please check /var/log/VMUpgrade.log", 1)
    else:
        PrintLog(f"VM Upgrade is successful for all VMIPs")

def create_qcow_dat(upgrade_qcow2, qcow2datfile):
    with open(qcow2datfile, 'w') as f:
        f.write(f"VM_UPGRADE_QCOW2={upgrade_qcow2}\n")
        f.write("VM_ROLLBACK_QCOW2=\n")
        f.write("UPG_RELEASE=bm_host\n")
        f.write("CUR_RELEASE=cloud-init\n")
        f.write("UPG_USER=autoinstall\n")
        f.write("LV_NAME=podmanstorage\n")
        f.write("LV_SIZE=400g\n")

def main():
    PrintLog("-----------------Executing VM Patch Upgrade-----------------")

    if len(sys.argv) != 2:
        Cleanup(f"Usage: python {sys.argv[0]} <upgrade_qcow2>", 1)

    upgrade_qcow2 = sys.argv[1]

    PrintLog(f"Upgrade QCOW2: {upgrade_qcow2}")

    if not os.path.isfile(upgrade_qcow2):
        Cleanup(f"Upgrade QCOW2 file not found: {upgrade_qcow2}", 1)

    # Create qcow2 dat file
    qcow2datfile = "/usr/local/bin/vmautomation-playbook/VMUpgradeRhel8/qcow2details.dat"
    create_qcow_dat(upgrade_qcow2, qcow2datfile)
    PrintLog(f"Created QCOW2 dat file: {qcow2datfile}")

    # Fetch and upgrade VMs
    get_vmip()

if __name__ == "__main__":
    main()
    sys.exit(0)
