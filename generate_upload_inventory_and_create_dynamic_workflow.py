#!/usr/bin/env python3
"""
Inventory Generator - Simplified with Standard Library

A streamlined tool for generating Ansible inventory from Excel design sheets.
"""

import argparse
import logging
from collections import defaultdict
from ipaddress import IPv4Network
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
import pandas as pd
import yaml,requests
from config import AAP_URL, AAP_TOKEN, INVENTORY_NAME, ORGANIZATION_ID, INVENTORY_FILE
import sys

# ---------------------------
# HEADERS
# ---------------------------
HEADERS = {
    "Authorization": f"Bearer {AAP_TOKEN}",
    "Content-Type": "application/json",
    "Accept": "application/json",
}


# Configuration
DEFAULT_OUTPUT = "inventory.yml"
logger = logging.getLogger("inventory-generator")


class InventoryGenerator:
    """Generate Ansible inventory from Excel with comprehensive error handling."""

    def __init__(self, excel_path: Path, output_path: Path = Path(DEFAULT_OUTPUT)):
        """Initialize the inventory generator.

        Args:
            excel_path: Path to input Excel file
            output_path: Path for output YAML inventory
        """
        self.excel_path = excel_path
        self.output_path = output_path
        self.ip_counters = defaultdict(int)
        self.vm_counters = defaultdict(int)

    @staticmethod
    def load_global_config(df: pd.DataFrame) -> Dict[str, Any]:
        """Parse global configuration from DataFrame.

        Args:
            df: DataFrame containing global configuration

        Returns:
            Dictionary with global configuration parameters

        Raises:
            ValueError: If required configuration is missing
        """
        try:
            df = df.fillna("")
            config = dict(zip(df.iloc[:, 0], df.iloc[:, 1]))

            def safe_int(value, default=0):
                try:
                    if pd.isna(value) or value == "" or value is None:
                        return default
                    return int(float(value))
                except (ValueError, TypeError):
                    logger.warning(f"Could not convert '{value}' to int, using default {default}")
                    return default

            return {
                "setup": safe_int(config.get("SETUP_TYPE", 0)),
                "thinpool_BM": 80,
                "vg_name": "vg01",
                "VM_LAUNCH_QCOW2": config.get("VM_LAUNCH_QCOW2", ""),
                "VM_UPGRADE_QCOW2": config.get("VM_UPGRADE_QCOW2", ""),
                "RHELIDM_VM_LAUNCH_QCOW2": config.get("RHELIDM_VM_LAUNCH_QCOW2", ""),
                "F5_VM_LAUNCH_QCOW2": config.get("F5_VM_LAUNCH_QCOW2", ""),
                "INTERNAL_HOST_DOMAIN": config.get("INTERNAL_HOST_DOMAIN", ""),
            }
        except Exception as e:
            logger.error(f"Error loading global config: {e}")
            raise ValueError(f"Failed to load global configuration: {e}") from e

    @staticmethod
    def expand_ip_range(ip_range_str: str) -> List[str]:
        """Expand IP ranges or return single IPs.

        Args:
            ip_range_str: IP range string (e.g., '10.225.26.166-167,10.225.26.186-187')

        Returns:
            List of expanded IP addresses
        """
        try:
            if pd.isna(ip_range_str) or not str(ip_range_str).strip():
                return []

            ips = []
            for part in str(ip_range_str).split(","):
                part = part.strip()
                if not part:
                    continue

                try:
                    if "-" in part:
                        if part.count(".") == 3:
                            prefix, last_octet_range = part.rsplit(".", 1)
                            start_str, end_str = last_octet_range.split("-")
                            start, end = map(int, (start_str, end_str))
                            ips.extend([f"{prefix}.{i}" for i in range(start, end + 1)])
                    else:
                        ips.append(part)
                except (ValueError, IndexError) as e:
                    logger.warning(f"Error parsing IP part '{part}': {e}")
                    continue

            return ips
        except Exception as e:
            logger.error(f"Error expanding IP range '{ip_range_str}': {e}")
            return []

    def load_sheets(self) -> Tuple[Dict[str, Any], pd.DataFrame, pd.DataFrame, Dict]:
        """Load all required Excel sheets.

        Returns:
            Tuple containing (global_config, vmlaunch_df, vlan_df, resources)

        Raises:
            FileNotFoundError: If Excel file doesn't exist
            ValueError: If required sheets are missing
        """
        try:
            logger.info(f"Loading Excel: {self.excel_path}")

            if not self.excel_path.exists():
                raise FileNotFoundError(f"Excel file not found: {self.excel_path}")

            excel = pd.ExcelFile(self.excel_path, engine="openpyxl")

            # Validate required sheets
            required_sheets = ["Global", "VMLaunchInput", "VLANGroup", "ResourceCfg"]
            missing_sheets = [s for s in required_sheets if s not in excel.sheet_names]
            if missing_sheets:
                raise ValueError(f"Missing required sheets: {missing_sheets}")

            # Load sheets
            global_config = self.load_global_config(pd.read_excel(excel, "Global"))
            vmlaunch_df = pd.read_excel(excel, "VMLaunchInput")
            vlan_df = pd.read_excel(excel, "VLANGroup")
            resource_df = pd.read_excel(excel, "ResourceCfg", dtype=str).fillna("")

            # Normalize column names
            for df in [vmlaunch_df, vlan_df, resource_df]:
                df.columns = df.columns.str.strip()

            # Normalize VLANGroup
            vlan_df = vlan_df.rename(columns={
                "SITE Name": "Vlan set",
                "VLANs GW": "Other VLANs GW"
            })

            if "Vlan set" in vlan_df.columns:
                vlan_df["Vlan set"].ffill(inplace=True)

            # Build resource lookup
            resources = {}
            if "VMType" in resource_df.columns:
                resource_df_clean = resource_df.drop_duplicates(subset=["VMType"], keep="first")
                resource_df_clean = resource_df_clean[resource_df_clean["VMType"].str.strip().astype(bool)]
                resources = resource_df_clean.set_index("VMType").to_dict(orient="index")

            logger.info(f"Successfully loaded {len(vmlaunch_df)} VM launch entries")
            return global_config, vmlaunch_df, vlan_df, resources

        except FileNotFoundError:
            raise
        except Exception as e:
            logger.error(f"Failed to load Excel sheets: {e}")
            raise ValueError(f"Error loading Excel data: {e}") from e

    def allocate_ip(self, vlan_set: str, bridge: str, ip_pool: List[str]) -> str:
        """Allocate next IP from pool using round-robin.

        Args:
            vlan_set: VLAN set identifier
            bridge: Bridge name
            ip_pool: Available IP addresses

        Returns:
            Allocated IP address

        Raises:
            ValueError: If IP pool is empty
        """
        try:
            if not ip_pool:
                raise ValueError(f"Empty IP pool for {vlan_set}/{bridge}")

            key = (vlan_set, bridge)
            index = self.ip_counters[key] % len(ip_pool)
            self.ip_counters[key] += 1
            allocated_ip = ip_pool[index]

            logger.debug(f"Allocated IP {allocated_ip} for {vlan_set}/{bridge}")
            return allocated_ip

        except Exception as e:
            logger.error(f"Error allocating IP for {vlan_set}/{bridge}: {e}")
            raise

    def create_network_interface(self, vlan_set: str, vlan: pd.Series) -> Optional[Dict[str, Any]]:
        """Create network interface configuration for VLAN.

        Args:
            vlan_set: VLAN set identifier
            vlan: Series containing VLAN configuration

        Returns:
            Dictionary with interface and route configuration, or None if invalid
        """
        try:
            # Get IP pool
            ip_col_name = next((col for col in ["VM startips", "Container startip"]
                                if col in vlan and str(vlan[col]).strip()), None)

            if not ip_col_name:
                logger.debug(f"No IP column found for {vlan_set}")
                return None

            ip_pool = self.expand_ip_range(vlan[ip_col_name])
            if not ip_pool:
                logger.warning(f"Empty IP pool for {vlan_set}")
                return None

            # Create interface
            bridge = str(int(float(vlan["VlanID"])))
            ip = self.allocate_ip(vlan_set, bridge, ip_pool)

            interface = {
                "bridge": f"dpbr_{bridge}",
                "ipaddress": f"{ip}/24",
            }

            # Add gateway
            vmlaunch_gw = str(vlan.get("VMLaunch GW", "")).strip()
            if vmlaunch_gw and vmlaunch_gw.lower() != 'nan':
                interface["gw"] = vmlaunch_gw

            # Add route if needed
            route = None
            other_vlans_gw = str(vlan.get("Other VLANs GW", "")).strip()
            vlan_subnet = str(vlan.get("VLAN Subnet", "")).strip()

            if other_vlans_gw and other_vlans_gw != vmlaunch_gw and vlan_subnet:
                try:
                    network = IPv4Network(vlan_subnet, strict=False)
                    route = f"{network.network_address}/24 via {other_vlans_gw} dev dpbr_{bridge}"
                except Exception as e:
                    logger.warning(f"Error creating route for {ip}: {e}")

            return {"interface": interface, "route": route}

        except Exception as e:
            logger.error(f"Error creating network interface for {vlan_set}: {e}")
            return None

    def create_vm_config(self, vlan_set: str, vlan_rows: pd.DataFrame,
                         vm_type: str, resources: Dict) -> Optional[Dict[str, Any]]:
        """Create VM configuration.

        Args:
            vlan_set: VLAN set identifier
            vlan_rows: DataFrame with VLAN configurations
            vm_type: Type of VM to create
            resources: Resource configuration dictionary

        Returns:
            VM configuration dictionary, or None if creation failed
        """
        try:
            self.vm_counters[vlan_set] += 1
            vm_name = f"{vlan_set}_vm{self.vm_counters[vlan_set]}"

            # Build network interfaces
            interfaces = []
            routes = []

            for _, vlan in vlan_rows.iterrows():
                try:
                    net_config = self.create_network_interface(vlan_set, vlan)
                    if net_config:
                        interfaces.append(net_config["interface"])
                        if net_config["route"]:
                            routes.append(net_config["route"])
                except Exception as e:
                    logger.warning(f"Error processing VLAN for {vm_name}: {e}")
                    continue

            if not interfaces:
                logger.warning(f"No interfaces for {vm_name}, skipping")
                self.vm_counters[vlan_set] -= 1
                return None

            # Get resource config
            res = resources.get(vm_type, {})

            def safe_convert(value):
                try:
                    if pd.isna(value) or value == "" or value is None:
                        return None
                    if str(value).replace('.', '', 1).isdigit():
                        return int(float(value))
                    return value
                except (ValueError, TypeError):
                    return value

            # Build partition and resource configs
            partition = {k: safe_convert(v)
                         for k, v in res.items()
                         if k not in ("VCPU", "RAM", "DataDiskSize", "VMType")
                         and v is not None and safe_convert(v) is not None}

            vm_resources = {}
            for k in ("VCPU", "RAM", "DataDiskSize"):
                if k in res and res[k] is not None:
                    try:
                        if not pd.isna(res[k]) and res[k] != "":
                            vm_resources[k] = int(float(res[k]))
                    except (ValueError, TypeError):
                        logger.warning(f"Invalid {k} value for {vm_type}")
                        continue

            logger.info(f"Created VM config for {vm_name} ({vm_type})")

            return {
                "name": vm_name,
                "vm_type": vm_type,
                "networkInterface": interfaces,
                "route": routes or None,
                "vm_partition": partition,
                "vm_resource": vm_resources,
            }

        except Exception as e:
            logger.error(f"Error creating VM config for {vlan_set}/{vm_type}: {e}")
            self.vm_counters[vlan_set] -= 1
            return None

    def build_inventory(self) -> Dict[str, Any]:
        """Build complete inventory structure.

        Returns:
            Complete inventory dictionary

        Raises:
            ValueError: If inventory building fails
        """
        try:
            global_config, vmlaunch_df, vlan_df, resources = self.load_sheets()

            inventory = {
                "all": {
                    "vars": global_config,
                    "children": {}
                }
            }

            vm_config_cols = [c for c in vmlaunch_df.columns if "Config" in c]
            total_vms = 0

            for _, row in vmlaunch_df.iterrows():
                try:
                    bm_ip = row.get("BM IP")
                    vlan_set = str(row.get("Vlan set ID", "")).strip()

                    try:
                        vm_count = int(float(row.get("VM Count", 0)))
                    except (ValueError, TypeError):
                        vm_count = 0

                    if not all([bm_ip, vlan_set, vm_count]):
                        logger.debug(f"Skipping incomplete row: BM={bm_ip}, VLAN={vlan_set}, Count={vm_count}")
                        continue

                    vlan_rows = vlan_df[vlan_df["Vlan set"] == vlan_set]
                    if vlan_rows.empty:
                        logger.warning(f"No VLANs found for {vlan_set}")
                        continue

                    # Create VMs
                    for i in range(vm_count):
                        try:
                            vm_type = str(row[vm_config_cols[i]]).strip() if i < len(vm_config_cols) else ""
                            if not vm_type or vm_type == 'nan':
                                continue

                            vm = self.create_vm_config(vlan_set, vlan_rows, vm_type, resources)

                            if vm:
                                host_ip = vm["networkInterface"][0]["ipaddress"].split("/")[0]

                                if vlan_set not in inventory["all"]["children"]:
                                    inventory["all"]["children"][vlan_set] = {"hosts": {}}

                                hosts = inventory["all"]["children"][vlan_set]["hosts"]
                                if host_ip not in hosts:
                                    hosts[host_ip] = {"ansible_host": bm_ip, "vms": []}

                                hosts[host_ip]["vms"].append(vm)
                                total_vms += 1
                                logger.info(f"Added {vm['name']} on {bm_ip} ({host_ip})")

                        except Exception as e:
                            logger.error(f"Error creating VM {i+1} for {vlan_set}: {e}")
                            continue

                except Exception as e:
                    logger.error(f"Error processing VMLaunchInput row: {e}")
                    continue

            logger.info(f"Built inventory with {total_vms} VMs across {len(inventory['all']['children'])} groups")
            return inventory

        except Exception as e:
            logger.error(f"Failed to build inventory: {e}")
            raise ValueError(f"Inventory build failed: {e}") from e

    def run(self) -> None:
        """Execute the complete inventory generation workflow.

        Raises:
            SystemExit: If generation fails
        """
        try:
            logger.info("Starting inventory generation")
            inventory = self.build_inventory()

            self.output_path.parent.mkdir(parents=True, exist_ok=True)

            with open(self.output_path, "w") as f:
                yaml.safe_dump(inventory, f, default_flow_style=False)

            logger.info(f"✓ Inventory written to {self.output_path}")

        except Exception as e:
            logger.error(f"Generation workflow failed: {e}")
            raise



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
    # Delete hosts
    hosts_resp = requests.get(f"{AAP_URL}/inventories/{inv_id}/hosts/", headers=HEADERS, verify=False)
    for host in hosts_resp.json().get("results", []):
        h_id = host.get("id")
        requests.delete(f"{AAP_URL}/hosts/{h_id}/", headers=HEADERS, verify=False)

    # Delete groups
    groups_resp = requests.get(f"{AAP_URL}/inventories/{inv_id}/groups/", headers=HEADERS, verify=False)
    for group in groups_resp.json().get("results", []):
        g_id = group.get("id")
        requests.delete(f"{AAP_URL}/groups/{g_id}/", headers=HEADERS, verify=False)

    print("✅ Inventory cleared.")

# ---------------------------
# STEP 3: UPLOAD INVENTORY VARS
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
        print("✅ Inventory vars uploaded.")
    else:
        print(f"⚠️ Failed to upload vars: {resp.status_code} {resp.text}")

# ---------------------------
# STEP 4: UPLOAD GROUPS & HOSTS
# ---------------------------
def upload_inventory(inv_id, inv_yaml):
    print(f"📤 Uploading groups & hosts into inventory ID {inv_id}...")

    def add_group(name, data):
        # Create group
        payload = {"name": name}
        g_create = requests.post(
            f"{AAP_URL}/inventories/{inv_id}/groups/",
            headers=HEADERS,
            json=payload,
            verify=False
        )
        if g_create.status_code not in [200, 201]:
            print(f"⚠️ Failed to create group '{name}': {g_create.text}")
            return

        group_id = g_create.json().get("id")
        if not group_id:
            print(f"⚠️ No group ID returned for '{name}'")
            return

        # Add hosts
        hosts = data.get("hosts", {})
        for hostname, details in hosts.items():
            payload = {
                "name": hostname,
                "inventory": inv_id,
                "variables": yaml.safe_dump(details)
            }

            h_resp = requests.post(
                f"{AAP_URL}/inventories/{inv_id}/hosts/",
                headers=HEADERS,
                json=payload,
                verify=False
            )

            if h_resp.status_code not in [200, 201]:
                print(f"⚠️ Could not create host {hostname}: {h_resp.text}")
                continue

            host_id = h_resp.json().get("id")
            if host_id:
                requests.post(
                    f"{AAP_URL}/groups/{group_id}/hosts/",
                    headers=HEADERS,
                    json={"id": host_id},
                    verify=False
                )

        # Process children recursively
        for child_name, child_data in data.get("children", {}).items():
            add_group(child_name, child_data)

    # Start from root `all.children`
    all_children = inv_yaml.get("all", {}).get("children", {})
    for group_name, group_data in all_children.items():
        add_group(group_name, group_data)

    print("✅ Inventory upload complete.")


# ---------------------------
# MAIN
# ---------------------------
if __name__ == "__main__":
    """CLI entry point."""
    parser = argparse.ArgumentParser(description="Generate Ansible inventory from Excel")
    parser.add_argument("excel", type=Path, help="Input Excel file")
    parser.add_argument("-o", "--output", type=Path, default=Path(DEFAULT_OUTPUT))
    parser.add_argument("-v", "--verbose", action="store_true")

    args = parser.parse_args()

    logging.basicConfig(
        format="%(asctime)s [%(levelname)-8s] %(message)s",
        level=logging.DEBUG if args.verbose else logging.INFO
    )

    try:
        generator = InventoryGenerator(args.excel, args.output)
        generator.run()
    except Exception as e:
        logger.error(f"✗ Failed: {e}", exc_info=args.verbose)
        raise SystemExit(1) from e

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
    upload_inventory_vars(inv_id, inv_yaml.get("all", {}).get("vars", {}))

    # Upload groups & hosts
    upload_inventory(inv_id, inv_yaml)

