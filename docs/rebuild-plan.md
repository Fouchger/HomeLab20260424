# Rebuild Plan

## Goal

Rebuild the uploaded homelab repository into a production-ready, Taskfile-first structure while preserving current functionality.

## Current behaviour found

The repo currently performs these main functions:

1. Installs prerequisites, clones or updates the GitHub repository, creates local config state and installs Task.
2. Uses Taskfiles as the operational entrypoint for Git/GitHub, SSH, Proxmox and secrets operations.
3. Stores non-secret local configuration in `state/config/.env`.
4. Uses generated or local-only secret files under `state/secrets/`.
5. Provides Proxmox SSH bootstrap, host-key trust and passwordless key setup.
6. Provides Proxmox API automation user and token bootstrap.
7. Provides age, SOPS and OpenBao workflows for secrets lifecycle management.
8. Provides helper scripts and runbooks for Technitium DNS and OMV disk passthrough.

## Production rebuild approach

1. Keep `install.sh` as the only pre-Task entrypoint.
2. Make `Taskfile.yml` the control plane after install.
3. Define shared paths and state variables once in the root Taskfile.
4. Add `scripts/lib/task-env.sh` because existing Taskfiles referenced shared helper functions that were missing.
5. Keep existing domain Taskfiles intact where possible to avoid functionality loss.
6. Introduce Ansible for repeatable local bootstrap and future host configuration.
7. Add production folder scaffolding for Terraform, Packer, services, templates and tools.
8. Replace committed runtime `.env` with `.env.example` and generated local state.
9. Add a current-to-new functionality map so future changes can be checked for regression.

## Variable handling rules applied

- Existing values are preserved and updated by key.
- Runtime files are created only if missing.
- Prompts are used only when required values are missing and a TTY is available.
- Secrets are not committed.
- Generated inventory and local Terraform state are ignored.

## Next development steps

1. Move service-specific shell logic into Ansible roles where the target host behaviour is known.
2. Add Terraform module definitions once Proxmox resource naming, networks and storage rules are confirmed.
3. Add domain-specific Taskfile workflows for DNS, Traefik, Cloudflare Tunnel and Plex once the required variables are defined.
4. Add CI checks for shell syntax, YAML syntax, Ansible syntax and secret scanning.
