# HomeLab20260424

Taskfile-first homelab operations repository for repeatable workstation bootstrap, SSH trust setup, secrets management, Proxmox automation, DNS and service deployment.

## Install

Run the installer to clone or update the repo and install Task:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Fouchger/HomeLab20260424/refs/heads/main/install.sh)"
```

Then use Task as the entrypoint:

```bash
cd ~/app/HomeLab20260424
task bootstrap
```

For a development checkout:

```bash
SETUP=dev ./install.sh
cd ~/Github/HomeLab20260424
task bootstrap
```

## Operating model

`install.sh` is intentionally limited to repository download/update, local state creation and Task installation. All operational workflows run through `Taskfile.yml`.

The root Taskfile defines shared variables once and includes domain Taskfiles under `taskfile/`. Ansible is used where practical for repeatable host configuration; Task remains the control plane for orchestration, prompting, reporting and safety checks.

## Important local state

Real runtime files are intentionally ignored by Git:

- `state/config/.env`
- `state/secrets/passwords.env`
- `state/ansible/inventory.yml`
- Terraform state files
- OpenBao runtime/bootstrap material

Examples are committed so the repo can be rebuilt safely:

- `state/config/.env.example`
- `state/secrets/passwords.env.example`
- `templates/inventory.yml.tpl`

## First commands

```bash
task help
task doctor
task bootstrap
task validate
```

## Current preserved domains

- Git and GitHub CLI bootstrap
- SSH identity and Proxmox SSH trust bootstrap
- Proxmox API user/token and node discovery
- Secrets management with age, SOPS and OpenBao
- Technitium DNS configuration helper
- OMV disk passthrough discovery helper
- Proxmox helper scripts for Code Server and Technitium DNS
