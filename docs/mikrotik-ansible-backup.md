# MikroTik Ansible Backup

## Purpose

This workflow uses Ansible to connect to a MikroTik hAP ax2 over SSH and save a RouterOS configuration export under:

```text
state/mikrotik/YYYYMMDD-HHMM/
```

The export command includes sensitive values. Treat every generated `.rsc` file as secret material.

## Prerequisites

- SSH enabled on the MikroTik router.
- A RouterOS user that can run `/export show-sensitive terse`.
- SSH enabled on the control host.
- Python 3 and pipx-capable package support on the control host.
- Ansible installed through the repository task workflow.
- Ansible collections installed with:

```bash
task ansible:collections
```

`task router:deps` remains available as a router-domain alias.

## One-off backup

Run from the repository root:

```bash
MIKROTIK_HOST='192.168.88.1' \
MIKROTIK_USER='admin' \
MIKROTIK_PASSWORD='your-router-password' \
task router:backup
```

Optional values:

```bash
MIKROTIK_NAME='hap-ax2' \
MIKROTIK_PORT='22' \
MIKROTIK_HOST_KEY_CHECKING='false' \
task router:backup
```

## Output

Each run creates:

```text
state/mikrotik/YYYYMMDD-HHMM/<router-name>.rsc
state/mikrotik/YYYYMMDD-HHMM/manifest.txt
```

The `.rsc` file is created with mode `0600`. The backup folder is created with mode `0700`.

## Security notes

- `state/mikrotik/` is ignored by Git.
- The Task workflow creates a temporary inventory in `state/tmp/` and removes it after the run.
- The Ansible task handling the export uses `no_log: true` so secrets are not printed to the terminal.
- Keep backups in encrypted storage if they are copied off the control host.
