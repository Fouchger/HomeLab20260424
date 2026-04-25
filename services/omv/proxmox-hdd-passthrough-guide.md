# Proxmox 9 HDD Passthrough to VM Guide

This guide explains how to identify physical HDDs on a Proxmox VE 9 host, allow the user to select one or more HDDs, and pass the selected HDDs through to a target VM.

The script uses friendly disk information for the user selection screen, while keeping the stable `/dev/disk/by-id/...` path internally for the actual Proxmox passthrough command.

## Purpose

The goal is to automate this manual Proxmox process:

```bash
qm set <vmid> -scsihw virtio-scsi-single
qm set <vmid> -scsi1 /dev/disk/by-id/<disk-id>
qm set <vmid> -scsi2 /dev/disk/by-id/<disk-id>
```

Instead of manually finding disk IDs and typing each `qm set` command, the script:

1. Scans the Proxmox host for physical rotational HDDs.
2. Shows the disks in a readable table.
3. Allows the user to select one or more disks.
4. Asks which VM should receive the disks.
5. Attaches the selected disks to the VM in sequence as `scsi1`, `scsi2`, `scsi3`, and so on.

## Important Notes

- Run this script on the Proxmox host, not inside a VM or LXC.
- Run it as `root` or with `sudo`.
- The script uses `/dev/disk/by-id/...` paths for passthrough because they are stable across reboots.
- Do not mount or use the same HDD on the Proxmox host after passing it through to a VM.
- The script starts from `scsi1` because `scsi0` is commonly used by the VM's operating system disk.
- Proxmox backups generally do not include raw passthrough disks. Backup the data from inside the VM or with another storage-aware backup method.

## Prerequisites

Confirm the Proxmox host can see the disks:

```bash
lsblk -dnpo NAME,TYPE,TRAN,ROTA,SIZE,MODEL,SERIAL
```

Sample output:

```text
NAME        TYPE TRAN ROTA SIZE   MODEL                   SERIAL
/dev/sda    disk sata 1    9.1T   ST10000VN000-3AK101     WP00WBAP
/dev/sdb    disk sata 1    9.1T   ST10000VN000-3AK101     WP014X13
/dev/sdc    disk sata 1    4.5T   ST5000LM000-2AN170      WCJ6V5MV
/dev/sdd    disk sata 1    3.6T   ST4000LM024-2AN17V      WCK0DD4S
/dev/sde    disk sata 1    14.6T  ST16000NM002H-3KW133    ZYD83XZA
/dev/sdf    disk usb  1    931.5G TOSHIBA MQ04UBF100      Y3RDT1FJT
/dev/sdg    disk usb  1    7.5G   Cruzer Blade            4C530001140112108591
/dev/nvme0n1 disk nvme 0   931.5G Samsung SSD 990 PRO 1TB S6Z1NF0W668384V
```

In this sample:

- `/dev/sda` to `/dev/sde` are SATA HDDs.
- `/dev/sdf` is a USB HDD.
- `/dev/sdg` is a USB stick and should not be passed through.
- `/dev/nvme0n1` is an NVMe SSD and is excluded because this process is focused on HDD passthrough.

## Create the Script

Create the script file:

```bash
nano discover-hdd-passthrough.sh
```

Paste the following script:

```bash
#!/usr/bin/env bash
# discover-hdd-passthrough.sh
# Shows HDDs in a friendly table, lets the user select one or more,
# asks for the target VM ID, and attaches selected HDDs to the VM.

set -euo pipefail

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name"
    exit 1
  fi
}

require_command lsblk
require_command find
require_command readlink
require_command qm

echo "Scanning physical HDDs..."
echo

declare -a DISK_BY_ID=()

printf "%-5s %-14s %-6s %-6s %-5s %-8s %-28s %-20s\n" \
  "NO" "NAME" "TYPE" "TRAN" "ROTA" "SIZE" "MODEL" "SERIAL"

printf "%-5s %-14s %-6s %-6s %-5s %-8s %-28s %-20s\n" \
  "--" "----" "----" "----" "----" "----" "-----" "------"

INDEX=0

while read -r NAME TYPE TRAN ROTA SIZE MODEL SERIAL; do
  [[ "$TYPE" == "disk" ]] || continue
  [[ "$ROTA" == "1" ]] || continue

  # Skip obvious USB installer sticks.
  if [[ "$TRAN" == "usb" && "$MODEL" == *"Cruzer"* ]]; then
    continue
  fi

  BY_ID_PATH=""

  while IFS= read -r LINK; do
    if [[ "$(readlink -f "$LINK")" == "$NAME" ]]; then
      BY_ID_PATH="$LINK"
      break
    fi
  done < <(
    find /dev/disk/by-id -type l \
      ! -name '*-part*' \
      \( -name 'ata-*' -o -name 'scsi-*' -o -name 'wwn-*' -o -name 'usb-*' \) \
      2>/dev/null | sort
  )

  if [[ -z "$BY_ID_PATH" ]]; then
    BY_ID_PATH="$NAME"
  fi

  INDEX=$((INDEX + 1))
  DISK_BY_ID+=("$BY_ID_PATH")

  printf "%-5s %-14s %-6s %-6s %-5s %-8s %-28s %-20s\n" \
    "$INDEX" "$NAME" "$TYPE" "$TRAN" "$ROTA" "$SIZE" "$MODEL" "$SERIAL"

done < <(lsblk -dnpo NAME,TYPE,TRAN,ROTA,SIZE,MODEL,SERIAL)

if [[ "${#DISK_BY_ID[@]}" -eq 0 ]]; then
  echo
  echo "No HDD candidates found."
  exit 0
fi

echo
read -r -p "Select HDDs, e.g. 1 or 1,3 or 1 3: " SELECTION

SELECTION="${SELECTION//,/ }"

declare -a SELECTED_HDDS=()

for ITEM in $SELECTION; do
  if ! [[ "$ITEM" =~ ^[0-9]+$ ]]; then
    echo "Invalid selection: $ITEM"
    exit 1
  fi

  SELECTED_INDEX=$((ITEM - 1))

  if (( SELECTED_INDEX < 0 || SELECTED_INDEX >= ${#DISK_BY_ID[@]} )); then
    echo "Selection out of range: $ITEM"
    exit 1
  fi

  SELECTED_HDDS+=("${DISK_BY_ID[$SELECTED_INDEX]}")
done

echo
read -r -p "Enter target VM ID, e.g. 100: " VM_ID

if ! [[ "$VM_ID" =~ ^[0-9]+$ ]]; then
  echo "Invalid VM ID: $VM_ID"
  exit 1
fi

if ! qm status "$VM_ID" >/dev/null 2>&1; then
  echo "VM ID not found: $VM_ID"
  exit 1
fi

echo
echo "Target VM: $VM_ID"
echo "Selected passthrough HDD paths:"
for HDD in "${SELECTED_HDDS[@]}"; do
  echo "$HDD"
done

echo
read -r -p "Proceed with passthrough to VM $VM_ID? Type YES to continue: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
  echo "Cancelled."
  exit 0
fi

echo
echo "Setting VM SCSI controller..."
qm set "$VM_ID" -scsihw virtio-scsi-single

BUS_NUMBER=1

for HDD in "${SELECTED_HDDS[@]}"; do
  BUS="scsi${BUS_NUMBER}"

  echo "Attaching $HDD as $BUS..."
  qm set "$VM_ID" "-$BUS" "$HDD"

  BUS_NUMBER=$((BUS_NUMBER + 1))
done

echo
echo "Done. Selected HDDs were attached to VM $VM_ID."
```

Save and exit.

## Make the Script Executable

```bash
chmod +x discover-hdd-passthrough.sh
```

## Run the Script

```bash
sudo ./discover-hdd-passthrough.sh
```

If already logged in as `root` on the Proxmox host:

```bash
./discover-hdd-passthrough.sh
```

## Sample User-Friendly Output

The script shows the user a friendly table rather than showing the internal `/dev/disk/by-id/...` paths by default.

Example:

```text
root@pve01:~# ./discover-hdd-passthrough.sh
Scanning physical HDDs...

NO    NAME           TYPE   TRAN   ROTA  SIZE     MODEL                        SERIAL
--    ----           ----   ----   ----  ----     -----                        ------
1     /dev/sda       disk   sata   1     9.1T     ST10000VN000-3AK101          WP00WBAP
2     /dev/sdb       disk   sata   1     9.1T     ST10000VN000-3AK101          WP014X13
3     /dev/sdc       disk   sata   1     4.5T     ST5000LM000-2AN170           WCJ6V5MV
4     /dev/sdd       disk   sata   1     3.6T     ST4000LM024-2AN17V           WCK0DD4S
5     /dev/sde       disk   sata   1     14.6T    ST16000NM002H-3KW133         ZYD83XZA
6     /dev/sdf       disk   usb    1     931.5G   TOSHIBA                     MQ04UBF100

Select HDDs, e.g. 1 or 1,3 or 1 3:
```

## Sample Selection

Example: select HDD 1 and HDD 3, then pass them through to VM `120`.

```text
Select HDDs, e.g. 1 or 1,3 or 1 3: 1,3
Enter target VM ID, e.g. 100: 120

Target VM: 120
Selected passthrough HDD paths:
/dev/disk/by-id/ata-ST10000VN000-3AK101_WP00WBAP
/dev/disk/by-id/ata-ST5000LM000-2AN170_WCJ6V5MV

Proceed with passthrough to VM 120? Type YES to continue: YES

Setting VM SCSI controller...
update VM 120: -scsihw virtio-scsi-single
Attaching /dev/disk/by-id/ata-ST10000VN000-3AK101_WP00WBAP as scsi1...
update VM 120: -scsi1 /dev/disk/by-id/ata-ST10000VN000-3AK101_WP00WBAP
Attaching /dev/disk/by-id/ata-ST5000LM000-2AN170_WCJ6V5MV as scsi2...
update VM 120: -scsi2 /dev/disk/by-id/ata-ST5000LM000-2AN170_WCJ6V5MV

Done. Selected HDDs were attached to VM 120.
```

## What the Script Does Internally

Although the user sees a readable disk table like this:

```text
1     /dev/sda       disk   sata   1     9.1T     ST10000VN000-3AK101          WP00WBAP
```

The script stores the stable passthrough path internally:

```text
/dev/disk/by-id/ata-ST10000VN000-3AK101_WP00WBAP
```

That path is then used by Proxmox:

```bash
qm set 120 -scsi1 /dev/disk/by-id/ata-ST10000VN000-3AK101_WP00WBAP
```

This is safer than using `/dev/sda`, because Linux device names such as `/dev/sda`, `/dev/sdb`, and `/dev/sdc` can change after reboot or hardware changes.

## Manual Equivalent Commands

If you were doing the same thing manually, the commands would look like this:

```bash
qm set 120 -scsihw virtio-scsi-single
qm set 120 -scsi1 /dev/disk/by-id/ata-ST10000VN000-3AK101_WP00WBAP
qm set 120 -scsi2 /dev/disk/by-id/ata-ST5000LM000-2AN170_WCJ6V5MV
```

## Verification

Check the VM configuration:

```bash
qm config 120
```

Expected example entries:

```text
scsihw: virtio-scsi-single
scsi1: /dev/disk/by-id/ata-ST10000VN000-3AK101_WP00WBAP,size=9T
scsi2: /dev/disk/by-id/ata-ST5000LM000-2AN170_WCJ6V5MV,size=5T
```

Start the VM:

```bash
qm start 120
```

Inside the VM, confirm the disks are visible:

```bash
lsblk
```

## Troubleshooting

### No HDD candidates found

Run:

```bash
lsblk -dnpo NAME,TYPE,TRAN,ROTA,SIZE,MODEL,SERIAL
```

Check whether the disks show `ROTA` as `1`. This script intentionally filters for rotational disks only.

### VM ID not found

List VMs:

```bash
qm list
```

Then rerun the script with the correct VM ID.

### Wrong disk selected

Cancel when prompted:

```text
Proceed with passthrough to VM 120? Type YES to continue:
```

Anything other than `YES` cancels the script.

### Disk already used by the host

Do not pass through a disk that is mounted, part of a ZFS pool, LVM volume group, or otherwise used by Proxmox.

Useful checks:

```bash
lsblk -f
pvs
vgs
zpool status
mount | grep /dev/sd
```
