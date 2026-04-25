# Current to Production Functionality Map

This document records the functionality found in the uploaded `HomeLab20260424-10.zip` and how it is preserved in the production-ready structure.

## Review summary

The uploaded repo already contained more than the original small baseline. The working files reviewed were:

- `install.sh`
- `Taskfile.yml`
- `.gitignore`
- `README.md`
- `scripts/lib/ensure-executable-scripts.sh`
- `taskfile/git_gh.Taskfile.yml`
- `taskfile/proxmox.Taskfile.yml`
- `taskfile/secrets.Taskfile.yml`
- `taskfile/ssh.Taskfile.yml`
- `services/omv/discover-hdd-passthrough.sh`
- `services/omv/proxmox-hdd-passthrough-guide.md`
- `services/proxmox_helper_scripts/coder-code-server.sh`
- `services/proxmox_helper_scripts/technitiumdns.sh`
- `services/technitium/configure-technitium.sh`
- `services/technitium/configure-technitium.md`
- `services/technitium/technitium-homelab-dns-runbook.md`
- `state/config/.env`

The `.git` folder was not treated as application functionality.

## Functionality map

| Current functionality | Current location | Production location | Status |
| --- | --- | --- | --- |
| Clone or update repository | `install.sh` | `install.sh` | Preserved and tightened. Installer remains download/update only, then hands off to Task. |
| Choose prod/dev target path | `install.sh` | `install.sh` | Preserved. `prod` uses `~/app/HomeLab20260424`; `dev` uses `~/Github/HomeLab20260424`, unless `TARGET_DIR` is set. |
| Install prerequisites | `install.sh` | `install.sh` and `ansible/playbooks/local_bootstrap.yml` | Preserved. Installer installs minimum required tools; Ansible handles repeatable local package bootstrap after install. |
| Install Task | `install.sh` | `install.sh` | Preserved. |
| Preserve/update local `.env` | `install.sh`, Taskfiles | `install.sh`, `Taskfile.yml`, `scripts/lib/task-env.sh` | Preserved and centralised. Existing values are updated by key, not overwritten wholesale. |
| Root Taskfile entrypoint | `Taskfile.yml` | `Taskfile.yml` | Preserved and expanded into the control plane. |
| Include domain Taskfiles | `Taskfile.yml` | `Taskfile.yml` | Preserved and expanded to include planned production domains. |
| Shared variables | Partly missing from root | `Taskfile.yml` | Fixed. Variables are now defined once in root and reused by child Taskfiles. |
| Shared env helper functions | Referenced but missing | `scripts/lib/task-env.sh` | Fixed. Provides `get_env_value`, `ensure_env_key_value`, `require_tty`, `tty_prompt`, `tty_prompt_secret`. |
| Make scripts executable | `scripts/lib/ensure-executable-scripts.sh` | Same location | Preserved. |
| Git installation and config | `taskfile/git_gh.Taskfile.yml` | Same location | Preserved. |
| GitHub CLI install/auth/report | `taskfile/git_gh.Taskfile.yml` | Same location | Preserved. |
| SSH key generation | `taskfile/ssh.Taskfile.yml` | Same location | Preserved. |
| Proxmox SSH host-key trust | `taskfile/ssh.Taskfile.yml` | Same location | Preserved. |
| Proxmox SSH key copy | `taskfile/ssh.Taskfile.yml` | Same location | Preserved. |
| known_hosts reconciliation | `taskfile/ssh.Taskfile.yml` | Same location | Preserved. |
| Proxmox API automation user/token | `taskfile/proxmox.Taskfile.yml` | Same location | Preserved. |
| Proxmox node discovery and env update | `taskfile/proxmox.Taskfile.yml` | Same location | Preserved. |
| Proxmox report | `taskfile/proxmox.Taskfile.yml` | Same location | Preserved. |
| age key generation | `taskfile/secrets.Taskfile.yml` | Same location | Preserved. |
| SOPS config and sample secret flows | `taskfile/secrets.Taskfile.yml` | Same location | Preserved. |
| OpenBao install/config/systemd/bootstrap | `taskfile/secrets.Taskfile.yml` | Same location | Preserved. |
| OpenBao backup, audit, cert renewal, DR helpers | `taskfile/secrets.Taskfile.yml` | Same location | Preserved. |
| Password storage helpers | `taskfile/secrets.Taskfile.yml` | Same location | Preserved. |
| Interactive secret view/edit helpers | `taskfile/secrets.Taskfile.yml` | Same location | Preserved. |
| Technitium DNS configuration script | `services/technitium/configure-technitium.sh` | Same location | Preserved. |
| Technitium DNS runbook | `services/technitium/technitium-homelab-dns-runbook.md` | Same location | Preserved. |
| OMV HDD passthrough discovery | `services/omv/discover-hdd-passthrough.sh` | Same location | Preserved. |
| OMV HDD passthrough guide | `services/omv/proxmox-hdd-passthrough-guide.md` | Same location | Preserved. |
| Proxmox helper script for Code Server | `services/proxmox_helper_scripts/coder-code-server.sh` | Same location | Preserved. |
| Proxmox helper script for Technitium DNS | `services/proxmox_helper_scripts/technitiumdns.sh` | Same location | Preserved. |
| Local Ansible inventory state | Not fully structured | `state/ansible/inventory.yml` generated from `templates/inventory.yml.tpl` | Added without removing current functionality. |
| Terraform, Packer and future domain folders | Not present or incomplete | `terraform/`, `packer/`, domain Taskfiles | Added as production scaffolding. No destructive actions added. |

## Important rebuild decisions

- No live `.env` or `passwords.env` is committed. Example files are committed instead.
- User-provided values are stored once in `state/config/.env` or `state/secrets/passwords.env` and then reused.
- Tasks should prompt only when required values are missing or empty.
- Ansible is introduced for repeatable local bootstrap while Task remains the main operator entrypoint.
- Existing large domain Taskfiles are preserved to avoid functionality loss.
- New domain Taskfiles are scaffolds only until their required variables and behaviours are explicitly defined.

## Known constraints

- The current Proxmox, OpenBao, GitHub and SSH flows require real infrastructure and credentials to fully integration-test.
- Destructive operations remain behind the existing Taskfile safeguards and confirmation variables.
