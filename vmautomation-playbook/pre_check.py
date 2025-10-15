import yaml
import subprocess
import os
import sys
# Load the YAML file
with open('input.yml', 'r') as file:
    input_file_content = yaml.safe_load(file)
content = input_file_content['vms']
def cosign_params_input_check_locally():
    # Define the Python script to be executed on the remote host
    try:
        global input_file_content
        
        # Additional check for repo_url and cosign_pub_key_file
        missing_repo_url = False
        missing_cosign_key = False
        repo_url = input_file_content['repo_url'] if 'repo_url' in input_file_content else None
        cosign_key = input_file_content['cosign_pub_key_file'] if 'cosign_pub_key_file' in input_file_content else None
        print("repo_url:", repo_url)
        print("cosign_key:", cosign_key)
        if not repo_url:
            missing_repo_url = True
        if not cosign_key:
            missing_cosign_key = True
        else:
            # Check if the key file exists locally
            if not os.path.isfile(cosign_key):
                print(f"\033[1mERROR: cosign_pub_key_file '{cosign_key}' is missing locally.\033[0m")
                missing_cosign_key = True
            else:
                # Optionally, check if the file is not empty
                if os.path.getsize(cosign_key) == 0:
                    print(f"\033[1mERROR: cosign_pub_key_file '{cosign_key}' is empty.\033[0m")
                    missing_cosign_key = True
        if missing_repo_url:
            print(f"\033[1mERROR: repo_url not set\033[0m")
        if missing_cosign_key:
            print(f"\033[1mERROR: cosign_pub_key_file not set\033[0m")
        if missing_cosign_key or missing_repo_url:
            return 1
        return 0
    except Exception as e:
        print(str(e))
        return 1
if not input_file_content['repo_url'] and not input_file_content['cosign_pub_key_file']:
    print("Both repo_url and cosign_pub_key_file are not set, skipping cosign checks.")
elif  cosign_params_input_check_locally():
    sys.exit(1)

# Define the Python script to be executed on the remote host
remote_script = """
import yaml
import os
import libvirt
import sys

host_ip = sys.argv[1]

with open('/tmp/input.yml', 'r') as file:
    content = yaml.safe_load(file)['vms']

with open('/tmp/input.yml', 'r') as file1:
    content_1 = yaml.safe_load(file1)



for image_info in content_1:
  if 'vmimage' in image_info:
    file = content_1['vmimage']
    if (file != None):
      path = f'/usr/local/lib/Prebuilt_kodiak/{file}'
      if os.path.exists(path):
        print("VMimage present")
      else:
        print("\033[1mERROR : VM image is not present , Please copy the image if required\033[0m")
        #sys.exit(1)
  
  if 'F5image' in image_info:
    file = content_1['F5image']
    if (file != None):
      path = f'/usr/local/lib/Prebuilt_kodiak/{file}'
      if os.path.exists(path):
        print("F5image present")
      else:
        print("\033[1mERROR : F5 image is not present , Please copy the image if required\033[0m")
        #sys.exit(1)

given_cpu = []
given_ram = []
launchable_vm = []
nonlaunchable_vm = []

def calculate_freeram():
    with open('/proc/meminfo', 'r') as file:
        for line in file:
            if line.startswith('MemTotal:'):
                total_ram_kb = int(line.split()[1])
                return total_ram_kb / 1024

def calculate_totalCPU():
    vcpu = []
    ram = []
    conn = libvirt.open('qemu:///system')
    if conn:
        for domain_id in conn.listDomainsID():
            domain = conn.lookupByID(domain_id)
            vcpu.append(domain.maxVcpus())
            ram.append(domain.info()[1] / 1024)
    conn.close()

    allocated_cpu = sum(vcpu)
    allocated_ram = sum(ram)
    return allocated_cpu, allocated_ram

allocated_cpu, allocated_ram = calculate_totalCPU()
print(f"Already running VM --> allocated CPU: {allocated_cpu}")
print(f"Already running VM --> allocated RAM: {allocated_ram} MB")

BM_cpu_count = os.cpu_count()
BM_ram_count = calculate_freeram()
cpu_limit = BM_cpu_count - (0.1 * BM_cpu_count)
ram_limit = BM_ram_count - (0.1 * BM_ram_count)

print(f"CPU limit --> {cpu_limit}")
print(f"RAM limit --> {ram_limit} MB")

for vm_info in content:
    #if 'vm_resource' in vm_info and vm_info['vm_resource'] == "custom":
    if 'vm_resource' in vm_info and vm_info['hostip'] == host_ip:
        vm_cpu = vm_info['vm_resource']['vcpu']
        vm_ram = vm_info['vm_resource']['ram']
    #else:
        #vm_cpu = content_flavor[vm_info['vm_type']][vm_info['vm_size']]['cpu']
        #vm_ram = content_flavor[vm_info['vm_type']][vm_info['vm_size']]['ram']

        if allocated_cpu + vm_cpu <= cpu_limit and allocated_ram + vm_ram <= ram_limit:
            launchable_vm.append(vm_info['name'])
            allocated_cpu += vm_cpu
            allocated_ram += vm_ram
            print(f"With VM --> {vm_info['name']} CPU consumed will be {allocated_cpu}")
            print(f"With VM --> {vm_info['name']} RAM consumed will be {allocated_ram}")
        else:
            nonlaunchable_vm.append(vm_info['name'])
            print(f"VM {vm_info['name']} is non-launchable due to resource constraints")

print("Launchable VMs:", launchable_vm)
print("Non-Launchable VMs:", nonlaunchable_vm)
"""

# Save the script to a temporary file locally
with open('remote_script.py', 'w') as script_file:
    script_file.write(remote_script)

# Iterate over each host IP in the content
uniq_host = []
for host in content:
    host_ip = host['hostip']
    if host_ip not in uniq_host:
        uniq_host.append(host_ip)
        subprocess.run(f"scp  -o LogLevel=QUIET -p input.yml autoinstall@{host_ip}:/tmp/input.yml > /dev/null 2>&1", shell=True )
        #subprocess.run(f"scp  -o LogLevel=QUIET -p vm_flavours.yml autoinstall@{host_ip}:/tmp/vm_flavours.yml", shell=True)
        subprocess.run(f"scp  -o LogLevel=QUIET -p remote_script.py autoinstall@{host_ip}:/tmp/remote_script.py > /dev/null 2>&1", shell=True)
        print(f"++++++++++++++Pre-check on resource in Baremetal: {host_ip}++++++++++++++++++++++++++++")
        execute_script_command = f"ssh  -o LogLevel=QUIET -t autoinstall@{host_ip} 'sudo python3 /tmp/remote_script.py {host_ip}'"
        result = subprocess.run(execute_script_command, shell=True)
        print("++++++++++++++++++++++++++++++++++++++++++")
        