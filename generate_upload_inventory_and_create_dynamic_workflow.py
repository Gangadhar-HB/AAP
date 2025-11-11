#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import pandas as pd
import yaml
import ipaddress
import re
import logging
from pathlib import Path
import requests

# CONFIGURATION
# ---------------------------
AAP_URL = "https://controller.example.org/api/v2"
AAP_TOKEN = "bG9RKmlxt4EsdzxUluvZfobfU4fpX2"
INVENTORY_NAME = "Dynamic_Inventory"
ORGANIZATION_ID = 1              # Update as needed
INVENTORY_FILE = "inventory.yml"
ORG_NAME = "Red Hat network organization"
CHILD_WORKFLOW_NAME = "vm-deployment-workflow-template"
PARENT_WORKFLOW_NAME = "Site_Workflow_Template"
INVENTORY_NAME = "Dynamic_Inventory"
ORGANIZATION_ID = 1              # Update as needed


HEADERS = {
    "Authorization": f"Bearer {AAP_TOKEN}",
    "Content-Type": "application/json",
    "Accept": "application/json",
}


class InventoryGenerator:
    """Generates a YAML Ansible inventory file from Excel design input, including QCOW2 vars."""

    def __init__(self, excel_file: str, output_file: str = "inventory.yml"):
        self.excel_file = Path(excel_file)
        self.output_file = Path(output_file)
        self.global_vars = {}
        self.vmlaunch_df = None
        self.vlan_df = None
        self.resource_dict = {}
        logging.basicConfig(
            format="%(asctime)s [%(levelname)s] %(message)s",
            level=logging.INFO
        )

    # ---------------------------------------------------------------------
    # Data Readers
    # ---------------------------------------------------------------------
    def read_excel_sheets(self):
        logging.info(f"Reading Excel file: {self.excel_file}")

        # Read Global sheet and fetch only QCOW2 variables
        global_df = pd.read_excel(self.excel_file, sheet_name="Global", engine="openpyxl").fillna('')
        global_df.columns = global_df.columns.str.strip()
        self.global_vars["VM_LAUNCH_QCOW2"] = ''
        self.global_vars["VM_UPGRADE_QCOW2"] = ''
        for _, row in global_df.iterrows():
            key = str(row[0]).strip()
            val = str(row[1]).strip() if len(row) > 1 else ''
            if key in ["VM_LAUNCH_QCOW2", "VM_UPGRADE_QCOW2"]:
                self.global_vars[key] = val

        logging.info(f"Loaded QCOW2 variables: {self.global_vars}")

        # Read other sheets
        self.vmlaunch_df = pd.read_excel(self.excel_file, sheet_name="VMLaunchInput", engine="openpyxl")
        self.vlan_df = pd.read_excel(self.excel_file, sheet_name="VLANGroup", engine="openpyxl")
        resource_df = pd.read_excel(self.excel_file, sheet_name="ResourceCfg", engine="openpyxl", dtype=str, keep_default_na=False).fillna('')

        # Normalize column names
        self.vmlaunch_df.columns = self.vmlaunch_df.columns.str.strip()
        self.vlan_df.columns = self.vlan_df.columns.str.strip()
        resource_df.columns = resource_df.columns.str.strip()
        if 'Vlan set' in self.vlan_df.columns:
            self.vlan_df['Vlan set'] = self.vlan_df['Vlan set'].ffill()

        # Convert ResourceCfg to dictionary
        if 'VMType' in resource_df.columns:
            self.resource_dict = (
                resource_df.drop_duplicates(subset='VMType', keep='first')
                .set_index('VMType')
                .to_dict(orient='index')
            )

        logging.info("✅ Excel sheets successfully loaded and normalized.")

    # ---------------------------------------------------------------------
    # Utility
    # ---------------------------------------------------------------------
    @staticmethod
    def expand_ip_range(ip_range_str: str) -> list:
        ips = []
        for part in str(ip_range_str).split(","):
            part = part.strip()
            if '-' in part:
                match = re.match(r'(\d+\.\d+\.\d+\.)(\d+)-(\d+)', part)
                if match:
                    prefix, start, end = match.groups()
                    ips.extend([f"{prefix}{i}" for i in range(int(start), int(end)+1)])
            elif part:
                ips.append(part)
        valid_ips = []
        for ip in ips:
            try:
                ipaddress.ip_address(ip)
                valid_ips.append(ip)
            except ValueError:
                logging.warning(f"Invalid IP skipped: {ip}")
        return valid_ips

    # ---------------------------------------------------------------------
    # Core Inventory Logic
    # ---------------------------------------------------------------------
    def build_inventory(self):
        logging.info("Building inventory data structure...")

        # Include QCOW2 vars plus your defaults
        all_vars = {
            "setup": 0,
            "thinpool_BM": 80,
            "vg_name": "vg01",
            **self.global_vars
        }

        inventory = {"all": {"vars": all_vars, "children": {}}}

        for _, vm_row in self.vmlaunch_df.iterrows():
            bm_ip = vm_row.get("BM IP")
            vlan_set = str(vm_row.get("Vlan set ID")).strip()
            vm_count = int(vm_row.get("VM Count", 0)) if not pd.isna(vm_row.get("VM Count")) else 0

            if not bm_ip or not vlan_set or vm_count == 0:
                continue

            vlan_rows = self.vlan_df[self.vlan_df["Vlan set"] == vlan_set]
            if vlan_rows.empty:
                logging.warning(f"No VLANs found for VLAN set: {vlan_set}")
                continue

            vm_config_cols = [col for col in self.vmlaunch_df.columns if "Config" in col]
            hosts_dict = {}

            for i in range(vm_count):
                vm_name = f"{vlan_set}_vm{i+1}"
                vm_type = str(vm_row.get(vm_config_cols[i], f"VMConfig{i+1}")).strip() if i < len(vm_config_cols) else f"VMConfig{i+1}"

                network_interfaces, routes = [], []

                for _, vlan in vlan_rows.iterrows():
                    start_ips_raw = None
                    for col in ["vm startips", "container startip"]:
                        if col in vlan:
                            start_ips_raw = vlan[col]
                            break
                    if pd.isna(start_ips_raw) or str(start_ips_raw).strip() == "":
                        continue

                    start_ips = self.expand_ip_range(start_ips_raw)
                    if not start_ips:
                        continue

                    bridge = vlan["Vlan"]
                    mgmt_gw = vlan.get("Management GW")
                    other_gw = vlan.get("Other VLANs GW")

                    ip_for_vm = start_ips[i % len(start_ips)]
                    ip_cidr = f"{ip_for_vm}/24"

                    iface = {"bridge": f"dpbr_{bridge}", "ipaddress": ip_cidr}
                    if pd.notna(mgmt_gw) and str(mgmt_gw).strip() != '':
                        iface["gw"] = mgmt_gw
                    network_interfaces.append(iface)

                    if pd.notna(other_gw) and str(other_gw).strip() != '':
                        network_addr = str(ipaddress.ip_network(f"{ip_for_vm}/24", strict=False).network_address)
                        routes.append(f"{network_addr}/24 via {other_gw} dev dpbr_{bridge}")

                if not network_interfaces:
                    logging.warning(f"No valid IPs found for VM {vm_name} in VLAN set {vlan_set}")
                    continue

                # VM partitions & resources
                res = self.resource_dict.get(vm_type, {})
                vm_partition = {k: int(v) if v.isdigit() else v for k,v in res.items() if k not in ["VCPU","RAM","DataDiskSize"] and v != ''}
                vm_resource = {k: int(res[k]) for k in ["VCPU","RAM","DataDiskSize"] if res.get(k, '') != ''}

                ip = network_interfaces[0]["ipaddress"].split('/')[0]
                hosts_dict[ip] = {
                    "ansible_host": bm_ip,
                    "vms": [{
                        "name": vm_name,
                        "vm_type": vm_type,
                        "networkInterface": network_interfaces,
                        "route": routes or None,
                        "vm_partition": vm_partition,
                        "vm_resource": vm_resource
                    }]
                }

            if hosts_dict:
                inventory["all"]["children"][vlan_set] = {"hosts": hosts_dict}

        logging.info("✅ Inventory dictionary structure built successfully.")
        return inventory

    # ---------------------------------------------------------------------
    # YAML Writer
    # ---------------------------------------------------------------------
    def write_inventory_file(self, inventory):
        logging.info(f"Writing inventory to {self.output_file}")
        with open(self.output_file, "w") as f:
            yaml.safe_dump(inventory, f, default_flow_style=False)
        logging.info("✅ inventory.yml successfully written.")

    # ---------------------------------------------------------------------
    # Runner
    # ---------------------------------------------------------------------
    def run(self):
        self.read_excel_sheets()
        inventory = self.build_inventory()
        self.write_inventory_file(inventory)
        logging.info("🎯 All steps completed successfully — ready for AAP upload!")

# ---------------------------
# STEP 1: GET OR CREATE INVENTORY
# ---------------------------
def get_inventory_id():
    resp = requests.get(f"{AAP_URL}/inventories/?name={INVENTORY_NAME}", headers=HEADERS, verify=False)
    if resp.status_code == 200 and resp.json().get("count", 0) > 0:
        inv_id = resp.json()["results"][0]["id"]
        print(f"✅ Found existing inventory '{INVENTORY_NAME}' (ID: {inv_id})")
        return inv_id
    return None

def create_inventory():
    payload = {
        "name": INVENTORY_NAME,
        "description": "Auto-uploaded inventory from inventory.py",
        "organization": ORGANIZATION_ID,
        "kind": ""
    }
    resp = requests.post(f"{AAP_URL}/inventories/", headers=HEADERS, json=payload, verify=False)
    if resp.status_code in [200, 201]:
        inv_id = resp.json().get("id")
        print(f"✅ Created new inventory '{INVENTORY_NAME}' (ID: {inv_id})")
        return inv_id
    else:
        print(f"❌ Failed to create inventory: {resp.status_code} {resp.text}")
        sys.exit(1)

# ---------------------------
# STEP 2: CLEAR EXISTING INVENTORY
# ---------------------------
def clear_inventory(inv_id):
    print("🧹 Clearing existing hosts and groups for overwrite...")
    # Delete all hosts
    hosts_resp = requests.get(f"{AAP_URL}/inventories/{inv_id}/hosts/", headers=HEADERS, verify=False)
    for host in hosts_resp.json().get("results", []):
        h_id = host.get("id")
        requests.delete(f"{AAP_URL}/hosts/{h_id}/", headers=HEADERS, verify=False)
    # Delete all groups
    groups_resp = requests.get(f"{AAP_URL}/inventories/{inv_id}/groups/", headers=HEADERS, verify=False)
    for group in groups_resp.json().get("results", []):
        g_id = group.get("id")
        requests.delete(f"{AAP_URL}/groups/{g_id}/", headers=HEADERS, verify=False)
    print("✅ Inventory cleared.")

# ---------------------------
# STEP 3: UPLOAD INVENTORY LEVEL VARS
# ---------------------------
def upload_inventory_vars(inv_id, all_vars):
    if not all_vars:
        print("ℹ️ No inventory-level vars found in YAML.")
        return
    print("📤 Uploading inventory-level vars...")
    resp = requests.patch(
        f"{AAP_URL}/inventories/{inv_id}/variable_data/",
        headers=HEADERS,
        json=all_vars,
        verify=False
    )
    if resp.status_code in [200, 201, 204]:
        print("✅ Inventory-level vars uploaded successfully.")
    else:
        print(f"⚠️ Failed to upload inventory vars: {resp.status_code} {resp.text}")

# ---------------------------
# STEP 4: UPLOAD GROUPS AND HOSTS
# ---------------------------
def upload_inventory(inv_id, inv_yaml):
    print(f"📤 Uploading groups and hosts to inventory ID {inv_id}...")

    def add_group(name, data):
        # Create group
        payload = {"name": name}
        g_create = requests.post(f"{AAP_URL}/inventories/{inv_id}/groups/", headers=HEADERS, json=payload, verify=False)
        if g_create.status_code not in [200, 201]:
            print(f"⚠️ Failed to create group '{name}': {g_create.status_code} {g_create.text}")
            return
        group_id = g_create.json().get("id")
        if not group_id:
            print(f"⚠️ No group ID returned for '{name}'")
            return

        # Add hosts
        hosts = data.get("hosts", {})
        for hostname, details in hosts.items():
            payload = {"name": hostname, "inventory": inv_id, "variables": yaml.safe_dump(details)}
            h_resp = requests.post(f"{AAP_URL}/inventories/{inv_id}/hosts/", headers=HEADERS, json=payload, verify=False)
            if h_resp.status_code not in [200, 201]:
                print(f"⚠️ Could not create host {hostname}: {h_resp.status_code} {h_resp.text}")
                continue
            host_id = h_resp.json().get("id")
            if host_id:
                # Attach host to group
                requests.post(f"{AAP_URL}/groups/{group_id}/hosts/", headers=HEADERS, json={"id": host_id}, verify=False)

        # Recurse into children
        children = data.get("children", {})
        for child_name, child_data in children.items():
            add_group(child_name, child_data)

    all_children = inv_yaml.get("all", {}).get("children", {})
    for group_name, group_data in all_children.items():
        add_group(group_name, group_data)

    print("✅ Inventory groups and hosts uploaded successfully.")


# ---------------------------
# FUNCTIONS
# ---------------------------

def get_org_id(org_name):
    resp = requests.get(f"{AAP_URL}/organizations/", headers=HEADERS, verify=False)
    resp.raise_for_status()
    for org in resp.json()["results"]:
        if org["name"] == org_name:
            return org["id"]
    raise ValueError(f"Organization '{org_name}' not found in AAP.")


def get_workflow_template_id(name, org_id):
    """Return workflow job template ID for a given name."""
    resp = requests.get(
        f"{AAP_URL}/workflow_job_templates/?organization={org_id}",
        headers=HEADERS,
        verify=False,
    )
    resp.raise_for_status()
    for wf in resp.json()["results"]:
        if wf["name"] == name:
            return wf["id"]
    raise ValueError(f"Workflow template '{name}' not found in organization {org_id}.")


def read_sites_from_inventory(file_path):
    with open(file_path, "r") as f:
        inv_yaml = yaml.safe_load(f)
    return list(inv_yaml.get("all", {}).get("children", {}).keys())


def create_workflow_template(name, org_id):
    """Create or get an existing parent workflow template."""
    resp = requests.get(f"{AAP_URL}/workflow_job_templates/?organization={org_id}", headers=HEADERS, verify=False)
    resp.raise_for_status()
    for wf in resp.json()["results"]:
        if wf["name"] == name:
            print(f"ℹ️ Workflow template '{name}' already exists (ID: {wf['id']}).")
            return wf["id"]

    data = {
        "name": name,
        "organization": org_id,
        "description": "Auto-created parent workflow for site orchestration",
    }
    resp = requests.post(f"{AAP_URL}/workflow_job_templates/", headers=HEADERS, json=data, verify=False)
    resp.raise_for_status()
    wf_id = resp.json()["id"]
    print(f"✅ Created new workflow template '{name}' with ID {wf_id}")
    return wf_id


def get_existing_nodes(workflow_id):
    """Return existing nodes (identifiers) from a workflow."""
    resp = requests.get(
        f"{AAP_URL}/workflow_job_template_nodes/?workflow_job_template={workflow_id}",
        headers=HEADERS,
        verify=False,
    )
    resp.raise_for_status()
    nodes = resp.json()["results"]
    return {n["identifier"]: n["id"] for n in nodes if n.get("identifier")}


def add_node_if_missing(workflow_id, child_workflow_id, site_name, existing_nodes):
    """Add site node to workflow if it does not exist."""
    identifier = f"{site_name}_node"

    if identifier in existing_nodes:
        print(f"⏭️ Node for site '{site_name}' already exists (ID: {existing_nodes[identifier]}), skipping.")
        return

    node_data = {
        "unified_job_template": child_workflow_id,
        "workflow_job_template": workflow_id,
        "identifier": identifier,
        "extra_data": {"site": site_name},  # optional, if child supports site var
    }

    resp = requests.post(f"{AAP_URL}/workflow_job_template_nodes/", headers=HEADERS, json=node_data, verify=False)

    if resp.status_code != 201:
        print(f"⚠️ Could not add site '{site_name}': {resp.status_code} - {resp.text}")
    else:
        node_id = resp.json()["id"]
        print(f"✅ Added site '{site_name}' as node {node_id}")


# ---------------------------
# MAIN
# ---------------------------
if __name__ == "__main__":
    generator = InventoryGenerator("Sample_STC_Design_Input.xlsx", "inventory.yml")
    generator.run()

    requests.packages.urllib3.disable_warnings()

    if not Path(INVENTORY_FILE).exists():
        print(f"❌ {INVENTORY_FILE} not found.")
        sys.exit(1)

    with open(INVENTORY_FILE, "r") as f:
        inv_yaml = yaml.safe_load(f)

    inv_id = get_inventory_id()
    if not inv_id:
        inv_id = create_inventory()
    else:
        clear_inventory(inv_id)

    # Upload vars
    all_vars = inv_yaml.get("all", {}).get("vars", {})
    upload_inventory_vars(inv_id, all_vars)

    # Upload groups & hosts
    upload_inventory(inv_id, inv_yaml)

    org_id = get_org_id(ORG_NAME)
    print(f"Organization '{ORG_NAME}' has ID {org_id}")

    child_workflow_id = get_workflow_template_id(CHILD_WORKFLOW_NAME, org_id)
    print(f"Found child workflow '{CHILD_WORKFLOW_NAME}' with ID {child_workflow_id}")

    parent_workflow_id = create_workflow_template(PARENT_WORKFLOW_NAME, org_id)

    sites = read_sites_from_inventory(INVENTORY_FILE)
    print(f"Found sites in inventory: {sites}")

    existing_nodes = get_existing_nodes(parent_workflow_id)
    print(f"Existing workflow nodes: {list(existing_nodes.keys())}")

    for site in sites:
        add_node_if_missing(parent_workflow_id, child_workflow_id, site, existing_nodes)

    print("✅ Parent workflow verified/updated successfully!")

