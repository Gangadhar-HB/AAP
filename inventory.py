#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
inventory_generator.py
---------------------------------
Generates a YAML Ansible inventory file (inventory.yml) from Excel design input.
Reads sheets: Global, VMLaunchInput, VLANGroup, ResourceCfg
and outputs structured inventory with hosts, groups, and variables.
"""

import pandas as pd
import yaml
import ipaddress
import re
import logging
from pathlib import Path


class InventoryGenerator:
    """Generates a structured inventory.yml file from Excel-based VM configuration."""

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
    def read_excel_sheets(self) -> None:
        """Reads required Excel sheets and normalizes column names."""
        logging.info(f"Reading Excel file: {self.excel_file}")

        # Global variables
        global_df = pd.read_excel(
            self.excel_file, sheet_name="Global", engine="openpyxl"
        ).fillna('')
        global_df.columns = global_df.columns.str.strip()
        if 'Key' in global_df.columns and 'Value' in global_df.columns:
            self.global_vars = global_df.set_index('Key')['Value'].to_dict()
        logging.info(f"Loaded Global variables: {self.global_vars}")

        # Main sheets
        self.vmlaunch_df = pd.read_excel(
            self.excel_file, sheet_name="VMLaunchInput", engine="openpyxl"
        )
        self.vlan_df = pd.read_excel(
            self.excel_file, sheet_name="VLANGroup", engine="openpyxl"
        )

        # Resource configuration
        resource_df = pd.read_excel(
            self.excel_file,
            sheet_name="ResourceCfg",
            engine="openpyxl",
            dtype=str,
            keep_default_na=False
        ).fillna('')

        # Normalize
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
    # Utility Functions
    # ---------------------------------------------------------------------
    @staticmethod
    def expand_ip_range(ip_range_str: str) -> list:
        """Expand IP ranges like '10.225.26.10-12,10.225.26.20' into individual IPs."""
        ips = []
        for part in str(ip_range_str).split(","):
            part = part.strip()
            if '-' in part:
                match = re.match(r'(\d+\.\d+\.\d+\.)(\d+)-(\d+)', part)
                if match:
                    prefix, start, end = match.groups()
                    ips.extend([f"{prefix}{i}" for i in range(int(start), int(end) + 1)])
            elif part:
                ips.append(part)
        # Validate IPs
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
    def build_inventory(self) -> dict:
        """Generate inventory structure for Ansible based on Excel input."""
        logging.info("Building inventory data structure...")

        inventory = {
            "all": {
                "vars": {
                    **self.global_vars,
                    "setup": 0,
                    "thinpool_BM": 80,
                    "vg_name": "vg01"
                },
                "children": {}
            }
        }

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
                vm_name = f"{vlan_set}_vm{i + 1}"
                vm_type = str(vm_row.get(vm_config_cols[i], f"VMConfig{i + 1}")).strip() if i < len(vm_config_cols) else f"VMConfig{i + 1}"

                network_interfaces, routes = [], []

                for _, vlan in vlan_rows.iterrows():
                    # Try both columns for IPs
                    start_ips_raw = None
                    for col in ["vm startips", "container startip"]:
                        if col in vlan:
                            start_ips_raw = vlan[col]
                            break

                    if pd.isna(start_ips_raw) or str(start_ips_raw).strip() == "":
                        continue  # skip rows with empty startips

                    start_ips = self.expand_ip_range(start_ips_raw)
                    if not start_ips:
                        continue

                    bridge = vlan["Vlan"]
                    mgmt_gw = vlan.get("Management GW")
                    other_gw = vlan.get("Other VLANs GW")

                    # Assign IP for this VM in this VLAN (wrap around if fewer IPs than VMs)
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

                # VM partitions: only non-empty fields except VCPU/RAM/DataDiskSize
                res = self.resource_dict.get(vm_type, {})
                vm_partition = {}
                for k, v in res.items():
                    if k not in ["VCPU", "RAM", "DataDiskSize"] and v != '':
                        try:
                            vm_partition[k] = int(v)
                        except ValueError:
                            vm_partition[k] = v

                # VM resources: only VCPU, RAM, DataDiskSize
                vm_resource = {}
                for k in ["VCPU", "RAM", "DataDiskSize"]:
                    val = res.get(k, '')
                    if val != '':
                        vm_resource[k] = int(val)

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
    # YAML Output Writer
    # ---------------------------------------------------------------------
    def write_inventory_file(self, inventory: dict) -> None:
        """Writes the inventory dictionary to YAML file."""
        logging.info(f"Writing inventory to {self.output_file}")
        with open(self.output_file, "w") as f:
            yaml.safe_dump(inventory, f, default_flow_style=False)
        logging.info("✅ inventory.yml successfully written.")

    # ---------------------------------------------------------------------
    # Runner
    # ---------------------------------------------------------------------
    def run(self) -> None:
        """End-to-end runner for reading, generating, and writing inventory."""
        self.read_excel_sheets()
        inventory = self.build_inventory()
        self.write_inventory_file(inventory)
        logging.info("🎯 All steps completed successfully — ready for AAP upload!")


# -------------------------------------------------------------------------
# Main Entrypoint
# -------------------------------------------------------------------------
if __name__ == "__main__":
    generator = InventoryGenerator("Sample_STC_Design_Input.xlsx", "inventory.yml")
    generator.run()

