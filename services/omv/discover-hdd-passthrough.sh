#!/usr/bin/env bash
# discover-hdd-passthrough.sh
# Shows HDDs in a friendly table, lets the user select one or more,
# and prints the selected stable passthrough paths.

set -euo pipefail

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

  # Skip obvious USB installer sticks
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
echo "Selected passthrough HDD paths:"
for HDD in "${SELECTED_HDDS[@]}"; do
  echo "$HDD"
done

#______________________________________________________

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