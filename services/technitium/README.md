# Technitium DNS LXC Service

This service provisions Technitium DNS LXCs on Proxmox using the pinned community helper script at `services/proxmox_helper_scripts/technitiumdns.sh` and then configures the containers with Ansible.

## Entry points

```bash
task technitium:plan
task technitium:apply
task technitium:configure
task technitium:report
```

## Runtime state

The workflow stores non-secret values in `state/config/.env` with `TECHNITIUM_*` keys and writes managed hosts to `state/ansible/inventory.yml` under both `lxc` and `technitium` groups.

Before any container is created, the reusable Proxmox LXC inventory checker validates requested CTIDs, hostnames, IP addresses and MAC addresses against the current Ansible inventory and local Proxmox `pct list` output where available.

## Creation behaviour

Existing containers are not destroyed automatically. When a requested CTID already exists, the task asks whether to recreate it. If you choose not to recreate it, the configuration phase still runs so the server can be converged to the latest settings.

## Upstream helper script

The Technitium LXC is created by `services/proxmox_helper_scripts/technitiumdns.sh`. This file is intentionally left unchanged so it can track the downstream Proxmox community-scripts behaviour cleanly.
