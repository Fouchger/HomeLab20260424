# MikroTik Router Desired State

This repository now includes a production-aligned MikroTik RouterOS desired-state workflow.

The current router backup is treated as the factual baseline for defaults, including VLANs, interface lists, DHCP pools, firewall posture, WiFi networks and management services. The gold-build sample is preserved as the shape of the rendered output.

## Operator tasks

```bash
task router:render
task router:plan
task router:apply
```

`router:render` writes a generated install script to `state/mikrotik/generated/`.

`router:plan` renders the script, exports the live router config and writes a local diff patch.

`router:apply` requires explicit confirmation by typing `APPLY`. It backs up the router, uploads the generated install script, imports it, and removes the uploaded script from the router.

## Secrets

Runtime secrets are stored through the existing encrypted dotenv method under:

```text
state/secrets/passwords/passwords.enc.env
```

The task prompts only when a value is missing. Existing values are reused on later runs.

## Safety

The generated RouterOS script performs a clean managed rebuild. It removes existing configurable router objects that are part of this managed domain and recreates the declared state. This is the mechanism used to remove drift and settings that are not part of the homelab configuration.

For the first run, use `task router:render` and inspect the generated `.rsc` before using `task router:plan` or `task router:apply`.
