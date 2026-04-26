#!/usr/bin/env python3
# ==============================================================================
# File: scripts/proxmox-lxc/proxmox-lxc-inventory.py
# Purpose:
#   Reusable safety checks and Ansible inventory updates for Proxmox LXC services.
# Notes:
#   - Designed for pre-create validation so duplicate CTIDs, names, IPs and MACs
#     are caught before Proxmox helper scripts are executed.
#   - Updates state/ansible/inventory.yml only after validation succeeds.
# ==============================================================================

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError as exc:
    print("ERROR: PyYAML is required. Install python3-yaml or run task ansible:python-deps.", file=sys.stderr)
    raise SystemExit(1) from exc


def load_yaml(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"all": {"hosts": {}, "children": {}}}
    data = yaml.safe_load(path.read_text())
    if data is None:
        return {"all": {"hosts": {}, "children": {}}}
    if not isinstance(data, dict):
        raise ValueError(f"Inventory is not a YAML mapping: {path}")
    return data


def ensure_inventory_shape(data: dict[str, Any]) -> dict[str, Any]:
    data.setdefault("all", {})
    data["all"].setdefault("hosts", {})
    data["all"].setdefault("children", {})
    for group_name in ("proxmox_hosts", "lxc", "vm", "technitium"):
        data["all"]["children"].setdefault(group_name, {"hosts": {}})
        data["all"]["children"][group_name].setdefault("hosts", {})
    return data


def normalise_ip(value: str) -> str:
    return str(ipaddress.ip_interface(value).ip)


def normalise_mac(value: str) -> str:
    return value.lower()


def pct_inventory() -> list[dict[str, str]]:
    if subprocess.run(["sh", "-c", "command -v pct >/dev/null 2>&1"], check=False).returncode != 0:
        return []
    result = subprocess.run(["pct", "list"], check=False, capture_output=True, text=True)
    if result.returncode != 0:
        return []
    rows: list[dict[str, str]] = []
    for line in result.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 3:
            rows.append({"ctid": parts[0], "status": parts[1], "hostname": parts[2]})
    return rows


def collect_existing(data: dict[str, Any]) -> dict[str, dict[str, str]]:
    existing = {"hostname": {}, "ip": {}, "mac": {}, "ctid": {}}
    children = data.get("all", {}).get("children", {})
    for group in children.values():
        for host_name, vars_map in group.get("hosts", {}).items():
            vars_map = vars_map or {}
            existing["hostname"][host_name] = host_name
            if vars_map.get("ansible_host"):
                existing["ip"][normalise_ip(str(vars_map["ansible_host"]))] = host_name
            if vars_map.get("mac"):
                existing["mac"][normalise_mac(str(vars_map["mac"]))] = host_name
            if vars_map.get("ctid"):
                existing["ctid"][str(vars_map["ctid"])] = host_name
    for item in pct_inventory():
        existing["ctid"].setdefault(item["ctid"], item["hostname"])
        existing["hostname"].setdefault(item["hostname"], item["hostname"])
    return existing


def validate_servers(data: dict[str, Any], servers: list[dict[str, Any]], service_group: str) -> None:
    errors: list[str] = []
    seen: dict[str, set[str]] = {"hostname": set(), "ip": set(), "mac": set(), "ctid": set()}
    existing = collect_existing(data)
    service_hosts = data["all"]["children"].setdefault(service_group, {"hosts": {}}).setdefault("hosts", {})

    for server in servers:
        hostname = str(server["hostname"])
        ip_address = normalise_ip(str(server["ip_cidr"]))
        mac = normalise_mac(str(server["mac"])) if server.get("mac") else ""
        ctid = str(server["ctid"])

        checks = {"hostname": hostname, "ip": ip_address, "ctid": ctid}
        if mac:
            checks["mac"] = mac
        for key, value in checks.items():
            if value in seen[key]:
                errors.append(f"Duplicate requested {key}: {value}")
            seen[key].add(value)
            owner = existing[key].get(value)
            if owner and owner not in service_hosts and owner != hostname:
                errors.append(f"{key} already used by {owner}: {value}")

    if errors:
        print("ERROR: Homelab safety checks failed before LXC creation.", file=sys.stderr)
        for error in errors:
            print(f" - {error}", file=sys.stderr)
        raise SystemExit(1)


def update_inventory(inventory_path: Path, servers: list[dict[str, Any]], service_group: str) -> None:
    data = ensure_inventory_shape(load_yaml(inventory_path))
    validate_servers(data, servers, service_group)
    lxc_hosts = data["all"]["children"]["lxc"]["hosts"]
    service_hosts = data["all"]["children"].setdefault(service_group, {"hosts": {}}).setdefault("hosts", {})

    for server in servers:
        hostname = str(server["hostname"])
        host_vars = {
            "ansible_host": normalise_ip(str(server["ip_cidr"])),
            "ansible_user": server.get("ansible_user", "root"),
            "ansible_ssh_private_key_file": server.get("ssh_private_key", "~/.ssh/homelab_ed25519"),
            "ctid": int(server["ctid"]),
            "mac": server.get("mac", ""),
            "service_role": service_group,
            "technitium_role": server.get("technitium_role", "secondary"),
            "technitium_server_ip": normalise_ip(str(server["ip_cidr"])),
            "technitium_primary_ip": server.get("primary_ip", ""),
            "technitium_secondary_ip": server.get("secondary_ip", ""),
            "technitium_searchdomain": server.get("searchdomain", ""),
        }
        lxc_hosts[hostname] = host_vars
        service_hosts[hostname] = host_vars

    inventory_path.parent.mkdir(parents=True, exist_ok=True)
    inventory_path.write_text(yaml.safe_dump(data, sort_keys=False, explicit_start=True))
    print(f"Inventory updated: {inventory_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate and update Proxmox LXC Ansible inventory.")
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--servers-json", required=True)
    parser.add_argument("--service-group", required=True)
    args = parser.parse_args()

    servers = json.loads(Path(args.servers_json).read_text())
    if not isinstance(servers, list) or not servers:
        raise ValueError("servers-json must contain a non-empty list")
    update_inventory(Path(args.inventory), servers, args.service_group)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
