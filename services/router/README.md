# Router Service

This folder documents the MikroTik RouterOS desired-state service for the homelab.

The implementation lives in:

- `ansible/roles/mikrotik_router`
- `ansible/playbooks/router/apply.yml`
- `scripts/router/mikrotik-run.sh`
- `taskfile/router.Taskfile.yml`
- `terraform/modules/mikrotik-router`

## Operator workflow

Use the Taskfile entrypoints from the repository root:

```bash
task router:render
task router:plan
task router:apply
```

`router:render` creates two files under `state/mikrotik/generated/<timestamp>/`:

- `<router>-install.rsc`: sensitive install script used for apply; do not commit.
- `<router>-install.redacted.rsc`: redacted review copy for normal inspection.

`router:plan` also exports the live router configuration and writes:

- `<router>-diff.redacted.patch`: normal operator review diff.
- `<router>-diff.sensitive.patch`: sensitive diff retained locally with mode `0600`.

`router:apply` now renders and plans first. After the redacted diff exists, Ansible asks for a per-router confirmation phrase:

```text
APPLY <router-name>
```

For the main router this is usually:

```text
APPLY hap-ax2
```

Protected automation may use `ROUTER_APPLY_CONFIRM=APPLY_ALL`, but only inside the protected `homelab-router` environment.

## Safety model

The generated RouterOS script:

1. Creates a local backup on the router.
2. Removes managed configurable objects.
3. Rebuilds the declared desired state.
4. Enables bridge VLAN filtering last.

The Ansible apply task also creates a `pre-ansible-apply` backup before import. If an import fails, the uploaded script is removed where possible and the role attempts a best-effort restore from `pre-ansible-apply.backup` when rollback is enabled.

RouterOS Safe Mode is terminal-session dependent and cannot be guaranteed through every Ansible network session. Set `MIKROTIK_SAFE_MODE=true` to attempt it. The role reports whether Safe Mode was actually enabled and still relies on backup-based recovery as the baseline safety mechanism.

## Multi-router support

Single-router operation still works with the existing variables:

```bash
task router:plan
```

Multi-router operation uses a comma-separated target list:

```bash
MIKROTIK_ROUTERS=hap-ax2,lab-rtr task router:plan
MIKROTIK_ROUTERS=hap-ax2,lab-rtr task router:apply
```

Per-router config and secret keys use the router name uppercased with punctuation changed to underscores:

```bash
MIKROTIK_HAP_AX2_HOST=192.168.20.1
MIKROTIK_HAP_AX2_ROUTER_IDENTITY=RTR-MAIN
MIKROTIK_LAB_RTR_HOST=192.168.20.2
MIKROTIK_LAB_RTR_ROUTER_IDENTITY=RTR-LAB
```

Per-router secrets are stored in the existing encrypted dotenv file. Common keys such as `MIKROTIK_PASSWORD` or `MIKROTIK_WIFI_USERS_PASSPHRASE` are used as defaults when a per-router secret is not already set.

Applies are serialised by default. Keep `MIKROTIK_APPLY_SERIAL=1` for production so only one router changes at a time.

## Secrets

Runtime secrets are supplied through the repository encrypted dotenv workflow or CI secrets. Do not commit files from `state/mikrotik/generated`.
