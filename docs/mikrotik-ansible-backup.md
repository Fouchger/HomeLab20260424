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
- Day 1 bootstrap tasks have been run through the repository task workflow.
- `task secrets:prepare` has created the age identity file used by SOPS.
- Ansible collections installed with:

```bash
task ansible:python-deps
task ansible:collections
```

`task router:deps` remains available as the router-domain dependency task.

## First backup

Run from the repository root after Day 1 bootstrap:

```bash
task router:backup
```

The task prompts for missing values, then saves them for future runs.

Non-secret values are stored in:

```text
state/config/.env
```

Saved keys:

```text
MIKROTIK_HOST
MIKROTIK_USER
MIKROTIK_NAME
MIKROTIK_PORT
MIKROTIK_HOST_KEY_CHECKING
MIKROTIK_COMMAND_TIMEOUT
```

The router password is stored in the encrypted passwords env file:

```text
state/secrets/passwords/passwords.enc.env
```

Saved key:

```text
MIKROTIK_PASSWORD
```

## One-off override

Environment variables still override saved values for a single run:

```bash
MIKROTIK_HOST='192.168.88.1' \
MIKROTIK_USER='admin' \
MIKROTIK_PASSWORD='your-router-password' \
task router:backup
```

Optional runtime values:

```bash
MIKROTIK_NAME='hap-ax2' \
MIKROTIK_PORT='22' \
MIKROTIK_HOST_KEY_CHECKING='false' \
MIKROTIK_COMMAND_TIMEOUT='60' \
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
- The Task workflow creates a temporary inventory in `state/tmp/`, stores it with mode `0600`, and removes it after the run.
- The temporary inventory contains connection credentials for the duration of the backup only.
- `MIKROTIK_PASSWORD` is persisted through the same encrypted SOPS-backed dotenv workflow used by other repo secrets.
- The Ansible task handling the export uses `no_log: true` so secrets are not printed to the terminal.
- Keep backups in encrypted storage if they are copied off the control host.
