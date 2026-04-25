---
# ==============================================================================
# File: templates/inventory.yml.tpl
# Purpose:
#   Starter Ansible inventory copied to state/ansible/inventory.yml during bootstrap.
# Notes:
#   - state/ansible/inventory.yml is local runtime state and is not committed.
#   - Host and group names are intentionally distinct to avoid Ansible ambiguity.
# ==============================================================================

all:
  hosts:
    localhost:
      ansible_connection: local
      ansible_python_interpreter: /usr/bin/python3
  children:
    proxmox_hosts:
      hosts: {}
    mikrotik:
      hosts: {}
    lxc:
      hosts: {}
    vm:
      hosts: {}
