#!/usr/bin/env bash
# ==============================================================================
# File: scripts/technitium/technitium-run.sh
# Purpose:
#   Plan, create and configure Technitium DNS LXCs using the pinned Proxmox helper
#   script plus Ansible configuration.
# Notes:
#   - The helper script at services/proxmox_helper_scripts/technitiumdns.sh is not
#     modified by this wrapper.
#   - Non-secret runtime values are stored in state/config/.env.
#   - Secrets are read from state/secrets/passwords/passwords.enc.env when needed.
# ==============================================================================

set -Eeuo pipefail

PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"

MODE="${1:-help}"
ROOT_DIR="${ROOT_DIR:?ROOT_DIR is required}"
CONFIG_ENV_FILE="${CONFIG_ENV_FILE:?CONFIG_ENV_FILE is required}"
ANSIBLE_INVENTORY_FILE="${ANSIBLE_INVENTORY_FILE:?ANSIBLE_INVENTORY_FILE is required}"
TASK_HELPERS_FILE="${TASK_HELPERS_FILE:?TASK_HELPERS_FILE is required}"
TMP_DIR="${TMP_DIR:?TMP_DIR is required}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:?SSH_PRIVATE_KEY is required}"
PASSWORDS_ENC_ENV_FILE="${PASSWORDS_ENC_ENV_FILE:-}"
PASSWORDS_ENC_ENV_FILE_REL="${PASSWORDS_ENC_ENV_FILE_REL:-$PASSWORDS_ENC_ENV_FILE}"
AGE_KEYS_FILE="${AGE_KEYS_FILE:-}"

# shellcheck source=/dev/null
. "$TASK_HELPERS_FILE"

HELPER_SCRIPT="${ROOT_DIR}/services/proxmox_helper_scripts/technitiumdns.sh"
SERVER_PLAN_FILE="${TMP_DIR}/technitium-servers.json"

log_step() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}


ensure_python_yaml() {
  if "$PYTHON_BIN" - <<'PY_CHECK' >/dev/null 2>&1
import yaml
PY_CHECK
  then
    return 0
  fi

  log_step 'PyYAML is missing; installing python3-yaml for inventory safety checks.'
  if command -v apt-get >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      apt-get update -y
      apt-get install -y --no-install-recommends python3-yaml
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y --no-install-recommends python3-yaml
    else
      echo 'ERROR: PyYAML is missing and sudo is unavailable.' >&2
      exit 1
    fi
  else
    echo 'ERROR: PyYAML is missing and this host does not use apt-get.' >&2
    exit 1
  fi
}

usage() {
  cat <<'EOF'
Technitium DNS LXC workflow

Commands:
  plan       Prompt for variables, validate uniqueness, update inventory
  apply      Run plan, create missing LXCs, configure with Ansible
  configure  Configure existing inventory hosts with Ansible only
  report     Show saved Technitium variables without exposing secrets
EOF
}

prompt_default() {
  key_name="$1"
  prompt_text="$2"
  default_value="${3-}"
  current_value="${!key_name:-}"

  if [ -z "$current_value" ]; then
    current_value="$(get_env_value "$CONFIG_ENV_FILE" "$key_name" || true)"
  fi

  if [ -n "$current_value" ]; then
    ensure_env_key_value "$CONFIG_ENV_FILE" "$key_name" "$current_value"
    printf '%s\n' "$current_value"
    return 0
  fi

  require_tty "$key_name"
  if [ -n "$default_value" ]; then
    answer="$(tty_prompt "${prompt_text} [${default_value}]: ")"
    answer="${answer:-$default_value}"
  else
    answer="$(tty_prompt "${prompt_text}: ")"
  fi
  if [ -z "$answer" ]; then
    printf 'ERROR: %s cannot be empty.\n' "$key_name" >&2
    exit 1
  fi
  ensure_env_key_value "$CONFIG_ENV_FILE" "$key_name" "$answer"
  printf '%s\n' "$answer"
}

prompt_optional() {
  key_name="$1"
  prompt_text="$2"
  default_value="${3-}"
  current_value="${!key_name:-}"
  if [ -z "$current_value" ]; then
    current_value="$(get_env_value "$CONFIG_ENV_FILE" "$key_name" || true)"
  fi
  if [ -n "$current_value" ]; then
    ensure_env_key_value "$CONFIG_ENV_FILE" "$key_name" "$current_value"
    printf '%s\n' "$current_value"
    return 0
  fi
  require_tty "$key_name"
  answer="$(tty_prompt "${prompt_text} [${default_value}]: ")"
  answer="${answer:-$default_value}"
  ensure_env_key_value "$CONFIG_ENV_FILE" "$key_name" "$answer"
  printf '%s\n' "$answer"
}

require_yes_no() {
  value="$1"
  key_name="$2"
  case "$value" in
    yes|no) ;;
    *) printf 'ERROR: %s must be yes or no.\n' "$key_name" >&2; exit 1 ;;
  esac
}

increment_ip_cidr() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import ipaddress, sys
interface = ipaddress.ip_interface(sys.argv[1])
offset = int(sys.argv[2])
print(f"{interface.ip + offset}/{interface.network.prefixlen}")
PY
}

increment_ctid() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import sys
print(int(sys.argv[1]) + int(sys.argv[2]))
PY
}

increment_hostname() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import re, sys
name = sys.argv[1]
offset = int(sys.argv[2])
match = re.search(r'(\d+)$', name)
if not match:
    print(f"{name}-{offset + 1}")
else:
    prefix = name[:match.start(1)]
    width = len(match.group(1))
    print(f"{prefix}{int(match.group(1)) + offset:0{width}d}")
PY
}

increment_mac() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import sys
base = sys.argv[1].replace(':', '')
offset = int(sys.argv[2])
value = int(base, 16) + offset
hexed = f"{value:012x}"[-12:]
print(':'.join(hexed[i:i+2] for i in range(0, 12, 2)).upper())
PY
}

json_quote() {
  "$PYTHON_BIN" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

prepare_plan() {
  log_step 'Step 1/5: Resolve Technitium LXC variables.'
  ensure_python_yaml
  mkdir -p "$TMP_DIR" "$(dirname "$CONFIG_ENV_FILE")" "$(dirname "$ANSIBLE_INVENTORY_FILE")"

  var_no_servers="$(prompt_default TECHNITIUM_VAR_NO_SERVERS 'Number of Technitium servers to create' '2')"
  var_same_setup="$(prompt_default TECHNITIUM_VAR_SAME_SETUP 'Use same setup for all servers, incrementing CTID/IP/MAC/hostname? yes/no' 'yes')"
  require_yes_no "$var_same_setup" TECHNITIUM_VAR_SAME_SETUP

  case "$var_no_servers" in
    ''|*[!0-9]*) echo 'ERROR: TECHNITIUM_VAR_NO_SERVERS must be a positive integer.' >&2; exit 1 ;;
  esac
  [ "$var_no_servers" -gt 0 ] || { echo 'ERROR: TECHNITIUM_VAR_NO_SERVERS must be greater than zero.' >&2; exit 1; }

  base_unprivileged="$(prompt_default TECHNITIUM_VAR_UNPRIVILEGED 'Unprivileged container flag' '1')"
  base_cpu="$(prompt_default TECHNITIUM_VAR_CPU 'CPU cores' '1')"
  base_ram="$(prompt_default TECHNITIUM_VAR_RAM 'RAM in MB' '1024')"
  base_disk="$(prompt_default TECHNITIUM_VAR_DISK 'Disk in GB' '5')"
  base_brg="$(prompt_default TECHNITIUM_VAR_BRG 'Bridge' 'vmbr0')"
  base_net="$(prompt_default TECHNITIUM_VAR_NET 'First server IP/CIDR' '192.168.30.10/24')"
  base_gateway="$(prompt_default TECHNITIUM_VAR_GATEWAY 'Gateway IP' '192.168.30.1')"
  base_mtu="$(prompt_optional TECHNITIUM_VAR_MTU 'MTU' '')"
  base_vlan="$(prompt_default TECHNITIUM_VAR_VLAN 'VLAN tag' '30')"
  base_mac="$(prompt_default TECHNITIUM_VAR_MAC 'First server MAC address' 'BC:24:11:86:A2:AA')"
  base_ns="$(prompt_default TECHNITIUM_VAR_NS 'DNS server for container setup' '192.168.30.1')"
  base_ipv6_method="$(prompt_default TECHNITIUM_VAR_IPV6_METHOD 'IPv6 method' 'auto')"
  base_ssh="$(prompt_default TECHNITIUM_VAR_SSH 'Enable SSH? yes/no' 'yes')"
  base_ssh_authorized_key="$(prompt_default TECHNITIUM_VAR_SSH_AUTHORIZED_KEY 'SSH authorised public key' "$(cat "${SSH_PRIVATE_KEY}.pub" 2>/dev/null || true)")"
  base_apt_cacher="$(prompt_default TECHNITIUM_VAR_APT_CACHER 'Use apt cacher? yes/no' 'no')"
  base_fuse="$(prompt_default TECHNITIUM_VAR_FUSE 'Enable fuse? yes/no' 'no')"
  base_tun="$(prompt_default TECHNITIUM_VAR_TUN 'Enable tun? yes/no' 'no')"
  base_gpu="$(prompt_default TECHNITIUM_VAR_GPU 'Enable GPU? yes/no' 'no')"
  base_nesting="$(prompt_default TECHNITIUM_VAR_NESTING 'Enable nesting flag' '1')"
  base_keyctl="$(prompt_default TECHNITIUM_VAR_KEYCTL 'Enable keyctl flag' '0')"
  base_mknod="$(prompt_default TECHNITIUM_VAR_MKNOD 'Enable mknod flag' '0')"
  base_mount_fs="$(prompt_optional TECHNITIUM_VAR_MOUNT_FS 'Mount filesystem setting' ' ' )"
  base_protection="$(prompt_default TECHNITIUM_VAR_PROTECTION 'Enable Proxmox protection? yes/no' 'no')"
  base_timezone="$(prompt_default TECHNITIUM_VAR_TIMEZONE 'Timezone' 'Pacific/Auckland')"
  base_tags="$(prompt_optional TECHNITIUM_VAR_TAGS 'Proxmox tags' 'dns;technitium')"
  base_verbose="$(prompt_default TECHNITIUM_VAR_VERBOSE 'Verbose helper output? yes/no' 'no')"
  base_ctid="$(prompt_default TECHNITIUM_VAR_CTID 'First server CTID' '21000')"
  base_hostname="$(prompt_default TECHNITIUM_VAR_HOSTNAME 'First server hostname' 'dns01')"
  base_primary_nic="$(prompt_default TECHNITIUM_VAR_PRIMARY_NIC 'Primary NIC name' 'net0')"
  base_searchdomain="$(prompt_default TECHNITIUM_VAR_SEARCHDOMAIN 'Search domain' 'home.arpa')"
  base_template_storage="$(prompt_default TECHNITIUM_VAR_TEMPLATE_STORAGE 'Template storage' 'local')"
  base_container_storage="$(prompt_default TECHNITIUM_VAR_CONTAINER_STORAGE 'Container storage' 'local-lvm')"

  log_step 'Step 2/5: Build requested server plan.'
  : > "$SERVER_PLAN_FILE"
  printf '[\n' > "$SERVER_PLAN_FILE"
  index=0
  while [ "$index" -lt "$var_no_servers" ]; do
    if [ "$index" -eq 0 ] || [ "$var_same_setup" = 'yes' ]; then
      server_net="$(increment_ip_cidr "$base_net" "$index")"
      server_ctid="$(increment_ctid "$base_ctid" "$index")"
      server_hostname="$(increment_hostname "$base_hostname" "$index")"
      server_mac="$(increment_mac "$base_mac" "$index")"
    else
      server_num=$((index + 1))
      server_net="$(prompt_default "TECHNITIUM_SERVER_${server_num}_VAR_NET" "Server ${server_num} IP/CIDR" '')"
      server_ctid="$(prompt_default "TECHNITIUM_SERVER_${server_num}_VAR_CTID" "Server ${server_num} CTID" '')"
      server_hostname="$(prompt_default "TECHNITIUM_SERVER_${server_num}_VAR_HOSTNAME" "Server ${server_num} hostname" '')"
      server_mac="$(prompt_default "TECHNITIUM_SERVER_${server_num}_VAR_MAC" "Server ${server_num} MAC address" '')"
    fi

    role='secondary'
    if [ "$index" -eq 0 ]; then
      role='primary'
    fi

    [ "$index" -eq 0 ] || printf ',\n' >> "$SERVER_PLAN_FILE"
    printf '  {' >> "$SERVER_PLAN_FILE"
    printf '"hostname":%s,' "$(json_quote "$server_hostname")" >> "$SERVER_PLAN_FILE"
    printf '"ip_cidr":%s,' "$(json_quote "$server_net")" >> "$SERVER_PLAN_FILE"
    printf '"mac":%s,' "$(json_quote "$server_mac")" >> "$SERVER_PLAN_FILE"
    printf '"ctid":%s,' "$(json_quote "$server_ctid")" >> "$SERVER_PLAN_FILE"
    printf '"ansible_user":"root",' >> "$SERVER_PLAN_FILE"
    printf '"ssh_private_key":%s,' "$(json_quote "$SSH_PRIVATE_KEY")" >> "$SERVER_PLAN_FILE"
    printf '"technitium_role":%s,' "$(json_quote "$role")" >> "$SERVER_PLAN_FILE"
    printf '"primary_ip":%s,' "$(json_quote "$("$PYTHON_BIN" -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).ip)' "$base_net")")" >> "$SERVER_PLAN_FILE"
    printf '"secondary_ip":%s,' "$(json_quote "$("$PYTHON_BIN" -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).ip)' "$(increment_ip_cidr "$base_net" 1)")")" >> "$SERVER_PLAN_FILE"
    printf '"searchdomain":%s' "$(json_quote "$base_searchdomain")" >> "$SERVER_PLAN_FILE"
    printf '}' >> "$SERVER_PLAN_FILE"
    index=$((index + 1))
  done
  printf '\n]\n' >> "$SERVER_PLAN_FILE"

  log_step 'Step 3/5: Run reusable homelab uniqueness checks and update inventory.'
  "$PYTHON_BIN" "$ROOT_DIR/scripts/proxmox-lxc/proxmox-lxc-inventory.py" \
    --inventory "$ANSIBLE_INVENTORY_FILE" \
    --servers-json "$SERVER_PLAN_FILE" \
    --service-group technitium

  log_step 'Step 4/5: Technitium plan ready.'
  cat "$SERVER_PLAN_FILE"
  log_step 'Step 5/5: Plan completed successfully.'
}

container_exists() {
  pct status "$1" >/dev/null 2>&1
}

create_containers() {
  [ -f "$HELPER_SCRIPT" ] || { echo "Required helper script not found: $HELPER_SCRIPT" >&2; exit 1; }
  require_command jq

  total="$(jq 'length' "$SERVER_PLAN_FILE")"
  idx=0
  while [ "$idx" -lt "$total" ]; do
    item="$(jq -c ".[$idx]" "$SERVER_PLAN_FILE")"
    ctid="$(printf '%s' "$item" | jq -r '.ctid')"
    hostname="$(printf '%s' "$item" | jq -r '.hostname')"
    ip_cidr="$(printf '%s' "$item" | jq -r '.ip_cidr')"
    mac="$(printf '%s' "$item" | jq -r '.mac')"

    if container_exists "$ctid"; then
      log_step "Container ${ctid} (${hostname}) already exists."
      require_tty "recreate decision for ${ctid}"
      answer="$(tty_prompt "Recreate CT ${ctid} (${hostname})? This destroys and rebuilds it. yes/no [no]: ")"
      answer="${answer:-no}"
      if [ "$answer" = 'yes' ]; then
        log_step "Stopping and destroying existing CT ${ctid}."
        pct stop "$ctid" >/dev/null 2>&1 || true
        pct destroy "$ctid" --purge 1
      else
        log_step "Keeping existing CT ${ctid}; configuration will still be updated."
        idx=$((idx + 1))
        continue
      fi
    fi

    log_step "Creating CT ${ctid} (${hostname}) with pinned Technitium helper script."
    export var_unprivileged="$base_unprivileged"
    export var_cpu="$base_cpu"
    export var_ram="$base_ram"
    export var_disk="$base_disk"
    export var_brg="$base_brg"
    export var_net="$ip_cidr"
    export var_gateway="$base_gateway"
    export var_mtu="$base_mtu"
    export var_vlan="$base_vlan"
    export var_mac="$mac"
    export var_ns="$base_ns"
    export var_ipv6_method="$base_ipv6_method"
    export var_ssh="$base_ssh"
    export var_ssh_authorized_key="$base_ssh_authorized_key"
    export var_apt_cacher="$base_apt_cacher"
    export var_fuse="$base_fuse"
    export var_tun="$base_tun"
    export var_gpu="$base_gpu"
    export var_nesting="$base_nesting"
    export var_keyctl="$base_keyctl"
    export var_mknod="$base_mknod"
    export var_mount_fs="$base_mount_fs"
    export var_protection="$base_protection"
    export var_timezone="$base_timezone"
    export var_tags="$base_tags"
    export var_verbose="$base_verbose"
    export var_ctid="$ctid"
    export var_hostname="$hostname"
    export var_primary_nic="$base_primary_nic"
    export var_searchdomain="$base_searchdomain"
    export var_template_storage="$base_template_storage"
    export var_container_storage="$base_container_storage"
    bash "$HELPER_SCRIPT"
    idx=$((idx + 1))
  done
}

resolve_technitium_secrets() {
  if [ -z "${TECHNITIUM_ADMIN_PASSWORD:-}" ] && [ -z "${TECHNITIUM_API_TOKEN:-}" ]; then
    if [ -n "$PASSWORDS_ENC_ENV_FILE" ] && [ -n "$AGE_KEYS_FILE" ]; then
      TECHNITIUM_ADMIN_PASSWORD="$(prompt_if_missing_encrypted_env_key \
        "$PASSWORDS_ENC_ENV_FILE" \
        TECHNITIUM_ADMIN_PASSWORD \
        'Technitium admin password: ' \
        "$AGE_KEYS_FILE" \
        "$PASSWORDS_ENC_ENV_FILE_REL")"
      export TECHNITIUM_ADMIN_PASSWORD
    else
      echo 'ERROR: Set TECHNITIUM_ADMIN_PASSWORD or TECHNITIUM_API_TOKEN before configuration.' >&2
      exit 1
    fi
  fi

  if [ -z "${TECHNITIUM_TSIG_SECRET:-}" ] && [ -n "$PASSWORDS_ENC_ENV_FILE" ] && [ -n "$AGE_KEYS_FILE" ]; then
    existing_tsig="$(decrypt_env_key_value "$PASSWORDS_ENC_ENV_FILE" TECHNITIUM_TSIG_SECRET "$AGE_KEYS_FILE" || true)"
    if [ -n "$existing_tsig" ]; then
      TECHNITIUM_TSIG_SECRET="$existing_tsig"
      export TECHNITIUM_TSIG_SECRET
    fi
  fi
}

configure_containers() {
  log_step 'Running Ansible Technitium configuration playbook.'
  require_command ansible-playbook
  resolve_technitium_secrets
  ansible-playbook -i "$ANSIBLE_INVENTORY_FILE" "$ROOT_DIR/ansible/playbooks/technitium/configure.yml"
}

report() {
  log_step 'Saved Technitium non-secret variables.'
  if [ -f "$CONFIG_ENV_FILE" ]; then
    grep '^TECHNITIUM_' "$CONFIG_ENV_FILE" || true
  else
    echo 'No state/config/.env file found yet.'
  fi
}

case "$MODE" in
  help|-h|--help) usage ;;
  plan) prepare_plan ;;
  apply) prepare_plan; create_containers; configure_containers ;;
  configure) configure_containers ;;
  report) report ;;
  *) usage; exit 1 ;;
esac
