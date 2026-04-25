---
# ==============================================================================
# File: templates/inventory.yml.tpl
# Purpose:
#   Starter Ansible inventory copied to state/ansible/inventory.yml during bootstrap.
# Notes:
#   - state/ansible/inventory.yml is local runtime state and is not committed.
# ==============================================================================

all:
  hosts:
    localhost:
      ansible_connection: local
  children:
    proxmox:
      hosts: {}
    mikrotik:
      hosts: {}
    lxc:
      hosts: {}
    vm:
      hosts: {}
