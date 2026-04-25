# Technitium Homelab DNS Configuration Runbook

## Purpose

This runbook describes how to configure Technitium DNS for the homelab using the reusable script:

```bash
./configure-technitium-homelab.sh
```

The script configures a production-ready internal DNS service for the homelab with:

- Primary and secondary Technitium DNS servers
- `fouchger.uk` as the main homelab domain
- `labcore.uk` as the development domain
- Primary-to-secondary zone transfer
- TSIG-secured zone replication
- Cloudflare DNS-over-HTTPS upstream resolvers
- Internal forward and reverse DNS zones
- Repeatable configuration that can be safely rerun

## Target DNS Servers

| Role | Hostname | IP Address |
|---|---:|---:|
| Primary DNS | `dns01.fouchger.uk` | `192.168.30.10` |
| Secondary DNS | `dns02.fouchger.uk` | `192.168.30.11` |

The MikroTik router configuration is treated as the source of truth. The DNS server addresses are:

```text
192.168.30.10
192.168.30.11
```

## What the Script Does

The script connects to the local Technitium API on the server where it is run and applies the required DNS configuration.

On the primary server, it:

- Authenticates to the local Technitium API
- Handles fresh install and already-configured login states
- Sets server-level DNS configuration
- Creates or updates the main and dev DNS zones
- Creates or updates reverse lookup zones
- Adds baseline DNS records
- Configures authoritative DNS records for `dns01` and `dns02`
- Generates and stores a TSIG secret if one does not already exist
- Enables secured zone transfer to the secondary server
- Backs up existing Technitium zone data before changes

On the secondary server, it:

- Authenticates to the local Technitium API
- Handles fresh install and already-configured login states
- Sets server-level DNS configuration
- Creates secondary zones for the primary server zones
- Uses the TSIG secret from the primary server
- Pulls zone data from the primary server by zone transfer
- Can be rerun safely without duplicating records

## First Run and Rerun Behaviour

The same command pattern is used for both first run and reruns.

The script will first try to authenticate using the supplied `ADMIN_PASSWORD`.

If that fails, it will try the default fresh-install Technitium credentials:

```text
admin / admin
```

If the default login works, the script changes the local Technitium admin password to the value supplied in `ADMIN_PASSWORD`.

This means:

- For a fresh install, set `ADMIN_PASSWORD` to the password you want the server to use going forward.
- For an already configured server, set `ADMIN_PASSWORD` to the current local Technitium admin password.
- The same command can be rerun after partial failure or later configuration changes.

## Prerequisites

Before running the script, confirm the following.

### 1. Technitium DNS is already installed

Technitium should already be installed using the Proxmox community script:

```text
https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/technitiumdns.sh
```

The script expects the community-script style installation:

```text
/opt/technitium/dns
technitium.service
```

### 2. Run the script on the DNS servers only

Run the script directly on the Technitium DNS server being configured.

Do not run this script on:

- The MikroTik router
- The Proxmox host
- A workstation

### 3. Network access is available

Confirm the following:

- `dns01` can reach `dns02`
- `dns02` can reach `dns01`
- Both servers can reach the internet for upstream DNS resolution
- Port `53/tcp` and `53/udp` are allowed between clients and DNS servers
- Port `5380/tcp` is accessible locally on each DNS server
- Zone transfer traffic is allowed between `192.168.30.10` and `192.168.30.11`

### 4. The script is present and executable

Copy the script to both DNS servers and make it executable:

```bash
chmod +x ./configure-technitium-homelab.sh
```

### 5. Use a secure admin password

Avoid pasting real production passwords into shared logs or chat sessions.

After testing, rotate the Technitium admin passwords if they have been exposed in terminal output, screenshots, or chat history.

## User Actions Required

The user needs to:

1. Copy `configure-technitium-homelab.sh` to `dns01`.
2. Run the primary configuration command on `dns01`.
3. Copy the generated TSIG secret from `dns01`.
4. Copy `configure-technitium-homelab.sh` to `dns02`.
5. Run the secondary configuration command on `dns02` using the TSIG secret from `dns01`.
6. Confirm both servers resolve internal records.
7. Confirm the MikroTik DHCP configuration points clients to both DNS servers.

## Commands to Run

### 1. Run on Primary Server

Run this on `192.168.30.10` / `dns01`:

```bash
sudo ROLE=primary \
SERVER_IP=192.168.30.10 \
ADMIN_PASSWORD='your-current-admin-password' \
./configure-technitium-homelab.sh
```

For a fresh Technitium install, use the admin password you want `dns01` to use going forward.

For a rerun, use the current local Technitium admin password for `dns01`.

### 2. Get the Primary Server TSIG Secret

Run this on `192.168.30.10` / `dns01` after the primary configuration completes:

```bash
sudo cat /root/technitium-homelab/config.env
```

Copy the `TSIG_SECRET` value. It will be used when configuring the secondary server.

### 3. Run on Secondary Server

Run this on `192.168.30.11` / `dns02`:

```bash
sudo ROLE=secondary \
SERVER_IP=192.168.30.11 \
PRIMARY_IP=192.168.30.10 \
ADMIN_PASSWORD='secondary-admin-password' \
TSIG_SECRET='<copy-from-primary>' \
./configure-technitium-homelab.sh
```

For a fresh Technitium install, use the admin password you want `dns02` to use going forward.

For a rerun, use the current local Technitium admin password for `dns02`.

## Post-Configuration Checks

Run these checks from a client or from either DNS server.

### Check Primary DNS

```bash
dig @192.168.30.10 dns01.fouchger.uk
```

### Check Secondary DNS

```bash
dig @192.168.30.11 dns02.fouchger.uk
```

### Check Main Domain

```bash
dig @192.168.30.10 fouchger.uk SOA
```

### Check Dev Domain

```bash
dig @192.168.30.10 labcore.uk SOA
```

### Check Zone Transfer from Secondary

```bash
dig @192.168.30.11 fouchger.uk SOA
```

If the secondary returns the expected SOA record, it is receiving the zone successfully.

## Troubleshooting

### Invalid username or password

The script authenticates to the local Technitium instance on the server where it is run.

For `dns01`, use the local `dns01` admin password.

For `dns02`, use the local `dns02` admin password.

The TSIG secret is not the Technitium admin password.

### TSIG secret wraps onto a second line

The TSIG secret must be copied as one continuous value.

Example format:

```text
TSIG_SECRET='example-secret-ending-with-equals='
```

### Secondary does not receive zones

Check that:

- `PRIMARY_IP` is `192.168.30.10`
- `TSIG_SECRET` matches the value from `dns01`
- Both servers can reach each other
- Firewall rules allow DNS and zone transfer traffic
- The primary configuration completed successfully before running the secondary setup

## Security Notes

- Rotate exposed admin passwords after setup.
- Keep the TSIG secret private.
- Do not reuse the Technitium admin password as the TSIG secret.
- Restrict the Technitium web UI to management networks only.
- Keep the MikroTik router configuration as the source of truth for DNS client assignment.
