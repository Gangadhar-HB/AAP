#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
upload_inventory_to_aap.py
---------------------------------
Uploads a generated Ansible inventory.yml file (with vars) to Ansible Automation Platform (AAP).
Clears existing inventory if already present.
"""

import requests
import yaml
import sys
from pathlib import Path

# ---------------------------
# CONFIGURATION
# ---------------------------
AAP_URL = "https://controller.example.org/api/v2"
AAP_TOKEN = "bG9RKmlxt4EsdzxUluvZfobfU4fpX2"
INVENTORY_NAME = "Dynamic_Inventory"
ORGANIZATION_ID = 1              # Update as needed
INVENTORY_FILE = "inventory.yml"

HEADERS = {
    "Authorization": f"Bearer {AAP_TOKEN}",
    "Content-Type": "application/json",
    "Accept": "application/json",
}

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
# MAIN
# ---------------------------
if __name__ == "__main__":
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

