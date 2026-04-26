# Router Automation Change Manifest

## Added

- `.github/workflows/router.yml`
- `ansible/playbooks/router/apply.yml`
- `ansible/roles/mikrotik_router/defaults/main.yml`
- `ansible/roles/mikrotik_router/tasks/main.yml`
- `ansible/roles/mikrotik_router/tasks/validate.yml`
- `ansible/roles/mikrotik_router/tasks/render.yml`
- `ansible/roles/mikrotik_router/tasks/diff.yml`
- `ansible/roles/mikrotik_router/tasks/apply.yml`
- `ansible/roles/mikrotik_router/templates/routeros-install.rsc.j2`
- `docs/mikrotik-router-desired-state.md`
- `docs/router-change-manifest.md`
- `scripts/router/mikrotik-run.sh`
- `services/router/README.md`
- `services/router/config/homelab.yml`
- `services/router/inventory/README.md`
- `terraform/environments/homelab/router.tf`
- `terraform/environments/homelab/variables.tf`
- `terraform/modules/mikrotik-router/main.tf`
- `terraform/modules/mikrotik-router/variables.tf`
- `terraform/modules/mikrotik-router/outputs.tf`

## Changed

- `taskfile/router.Taskfile.yml`
  - Added `router:render`, `router:plan`, and `router:apply`.
  - Preserved the existing `router:backup` workflow.
  - Extended help text for the new desired-state workflow.

## Deleted

- None.

## Safety notes

- Existing backup workflow is preserved.
- Router inventory and secret vars are generated into `state/tmp` and removed after each run.
- Generated RouterOS scripts and diffs are written under `state/mikrotik/generated`.
- Apply requires explicit confirmation by typing `APPLY`.

## 2026-04-26 Role resolution fix

### Added
- `ansible.cfg` to anchor repository-local role and collection paths.

### Changed
- `scripts/router/mikrotik-run.sh` now exports `ANSIBLE_CONFIG`, `ANSIBLE_ROLES_PATH`, and `ANSIBLE_COLLECTIONS_PATH` before running the desired-state playbook.

### Reason
- Playbooks under `ansible/playbooks/router/` do not automatically search `ansible/roles/`, so Ansible could not resolve the `mikrotik_router` role without explicit configuration.

## 2026-04-26 Production safety hardening

### Changed
- `ansible/roles/mikrotik_router/defaults/main.yml`
  - Added `wifi2-mgmt` to the MGMT bridge VLAN tagged members.
  - Restored differentiated DHCP lease policy: `1d` for managed/internal VLANs and `8h` for guest.
  - Added defaults for plan-before-apply and redacted preview behaviour.
- `ansible/roles/mikrotik_router/templates/routeros-install.rsc.j2`
  - Changed DHCP client cleanup to remove all DHCP clients before recreating the managed WAN DHCP client.
  - Added explicit WAN-to-LANS forward drop before the remaining forward-chain drops.
  - Added a generated-file warning that rendered install scripts contain secrets.
- `ansible/roles/mikrotik_router/tasks/render.yml`
  - Added redacted install preview generation.
  - Updated manifest output to identify sensitive and redacted files separately.
- `ansible/roles/mikrotik_router/tasks/diff.yml`
  - Added redacted current export and redacted diff generation.
  - Kept sensitive diff local with mode `0600`.
  - Added a plan marker consumed by apply.
- `ansible/roles/mikrotik_router/tasks/apply.yml`
  - Added plan marker validation before import.
  - Wrapped import in a block/rescue so failed imports remove the uploaded script where possible and stop with rollback guidance.
- `.github/workflows/router.yml`
  - Added controlled self-hosted runner operation for render, plan, and apply.
  - Apply remains protected by the `homelab-router` GitHub Environment.
  - Router secrets are sourced from GitHub Secrets, not repository files.
- `services/router/README.md`
  - Documented the redacted review flow, sensitive artefacts, and apply safety model.
- `taskfile/router.Taskfile.yml`
  - Updated help text for redacted files, sensitive files, and stored router secrets.

### Deleted
- None.

### Safety notes
- `task router:apply` now renders and plans in the same operation before import.
- Normal review should use `*-install.redacted.rsc` and `*-diff.redacted.patch`.
- Sensitive generated files remain under `state/mikrotik/generated` and must not be committed.

## 2026-04-26 Elite production hardening

### Changed
- `ansible/playbooks/router/apply.yml`
  - Added serialised router execution with `MIKROTIK_APPLY_SERIAL` so multiple routers are applied one at a time by default.
  - Added runtime controls for best-effort Safe Mode and rollback behaviour.
- `ansible/roles/mikrotik_router/defaults/main.yml`
  - Added defaults for post-plan confirmation, best-effort rollback, and apply serialisation.
- `ansible/roles/mikrotik_router/tasks/apply.yml`
  - Moved confirmation to after render and diff generation.
  - Requires typing `APPLY <router-name>` for each router before importing config.
  - Allows `APPLY_ALL` only for protected automation environments.
  - Attempts RouterOS Safe Mode when enabled and reports whether it was available.
  - Attempts best-effort restore from `pre-ansible-apply.backup` if import fails and rollback is enabled.
  - Disables Safe Mode after successful import when it was successfully enabled.
- `scripts/router/mikrotik-run.sh`
  - Added `MIKROTIK_ROUTERS` support for multi-router render, plan and apply.
  - Added per-router config and secret key support using normalised router names.
  - Stores per-router secrets in the existing encrypted dotenv method.
  - Defers apply confirmation to Ansible after the redacted plan is generated.
- `.github/workflows/router.yml`
  - Added multi-router, Safe Mode, rollback, and serial controls.
  - Uses `APPLY_ALL` only inside the protected `homelab-router` environment.
- `taskfile/router.Taskfile.yml`
  - Documented multi-router usage and post-plan confirmation.
- `services/router/README.md`
  - Documented Safe Mode limitations, rollback behaviour, confirmation gate, and multi-router operation.

### Deleted
- None.

### Safety notes
- True RouterOS Safe Mode is terminal-session dependent. The role attempts to use it when enabled, but production safety does not rely on it being available.
- The default production guard is: render, live diff, post-plan confirmation, pre-apply backup, serialised apply, best-effort rollback on failed import.
- For local operators, confirmation is per-router: `APPLY hap-ax2`.
- For protected CI only, `ROUTER_APPLY_CONFIRM=APPLY_ALL` can be used after GitHub Environment approval.
