#!/usr/bin/env bash
# ==============================================================================
# File: scripts/router/mikrotik-run.sh
# Purpose:
#   Prepare MikroTik runtime inventory, secrets and Ansible execution modes.
# Notes:
#   - Uses repository helper functions for idempotent config and secret storage.
#   - Prompts only when a value is missing from the environment or saved state.
#   - Supports a single router through MIKROTIK_NAME/MIKROTIK_HOST or multiple
#     routers through MIKROTIK_ROUTERS="hap-ax2,lab-rtr" with per-router keys.
#   - Temporary inventory and extra-vars files are removed after each run.
# ==============================================================================

set -euo pipefail

mode="${1:-render}"
root_dir="${ROOT_DIR:-$(pwd)}"
config_env_file="${CONFIG_ENV_FILE:-${root_dir}/state/config/.env}"
passwords_enc_file="${PASSWORDS_ENC_ENV_FILE:-${root_dir}/state/secrets/passwords/passwords.enc.env}"
passwords_enc_file_rel="${PASSWORDS_ENC_ENV_FILE_REL:-state/secrets/passwords/passwords.enc.env}"
age_keys_file="${AGE_KEYS_FILE:-${root_dir}/state/secrets/age/keys.txt}"
tmp_dir="${TMP_DIR:-${root_dir}/state/tmp}"
mikrotik_dir="${MIKROTIK_DIR:-${root_dir}/state/mikrotik}"
helper_file="${TASK_HELPERS_FILE:-${root_dir}/scripts/lib/task-env.sh}"

. "$helper_file"

mkdir -p "$tmp_dir" "$mikrotik_dir/generated"
chmod 700 "$tmp_dir" "$mikrotik_dir" "$mikrotik_dir/generated" 2>/dev/null || true

ansible_playbook_cmd="$(resolve_command_path ansible-playbook)"

inventory_file="${tmp_dir}/mikrotik-inventory.yml"
extra_vars_file="${tmp_dir}/mikrotik-runtime-vars.yml"
output_dir="${mikrotik_dir}/generated/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$output_dir"
chmod 700 "$output_dir"

cleanup_runtime_files() {
  rm -f "$inventory_file" "$extra_vars_file"
}
trap cleanup_runtime_files EXIT

normalise_router_key() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]+/_/g; s/^_+//; s/_+$//'
}

get_config_key() {
  key_name="${1:?Missing key name}"
  get_env_value "$config_env_file" "$key_name" || true
}

prompt_config_default() {
  key_name="${1:?Missing key name}"
  prompt_text="${2:?Missing prompt}"
  default_value="${3:-}"
  current_value="${!key_name:-}"

  if [ -n "$current_value" ]; then
    ensure_env_key_value "$config_env_file" "$key_name" "$current_value"
    printf '%s\n' "$current_value"
    return 0
  fi

  current_value="$(get_config_key "$key_name")"
  if [ -n "$current_value" ]; then
    printf '%s\n' "$current_value"
    return 0
  fi

  if [ -n "$default_value" ]; then
    ensure_env_key_value "$config_env_file" "$key_name" "$default_value"
    printf '%s\n' "$default_value"
    return 0
  fi

  prompt_if_missing_env_key "$config_env_file" "$key_name" "$prompt_text"
}

prompt_config_scoped() {
  router_name="${1:?Missing router name}"
  suffix="${2:?Missing suffix}"
  prompt_text="${3:?Missing prompt}"
  default_value="${4:-}"
  router_key="$(normalise_router_key "$router_name")"
  scoped_key="MIKROTIK_${router_key}_${suffix}"
  common_key="MIKROTIK_${suffix}"
  allow_common_fallback="true"
  if [ "${router_target_count:-1}" != "1" ] && [ "$suffix" = "HOST" ]; then
    allow_common_fallback="false"
  fi
  scoped_env_value="${!scoped_key:-}"
  common_env_value="${!common_key:-}"

  if [ -n "$scoped_env_value" ]; then
    ensure_env_key_value "$config_env_file" "$scoped_key" "$scoped_env_value"
    printf '%s\n' "$scoped_env_value"
    return 0
  fi

  scoped_saved_value="$(get_config_key "$scoped_key")"
  if [ -n "$scoped_saved_value" ]; then
    printf '%s\n' "$scoped_saved_value"
    return 0
  fi

  if [ "$allow_common_fallback" = "true" ] && [ -n "$common_env_value" ]; then
    ensure_env_key_value "$config_env_file" "$scoped_key" "$common_env_value"
    printf '%s\n' "$common_env_value"
    return 0
  fi

  common_saved_value=""
  if [ "$allow_common_fallback" = "true" ]; then
    common_saved_value="$(get_config_key "$common_key")"
  fi
  if [ -n "$common_saved_value" ]; then
    ensure_env_key_value "$config_env_file" "$scoped_key" "$common_saved_value"
    printf '%s\n' "$common_saved_value"
    return 0
  fi

  if [ -n "$default_value" ]; then
    ensure_env_key_value "$config_env_file" "$scoped_key" "$default_value"
    printf '%s\n' "$default_value"
    return 0
  fi

  prompt_if_missing_env_key "$config_env_file" "$scoped_key" "$router_name $prompt_text"
}

prompt_secret_scoped() {
  router_name="${1:?Missing router name}"
  suffix="${2:?Missing suffix}"
  prompt_text="${3:?Missing prompt}"
  default_to_common="${4:-true}"
  router_key="$(normalise_router_key "$router_name")"
  scoped_key="MIKROTIK_${router_key}_${suffix}"
  common_key="MIKROTIK_${suffix}"
  allow_common_fallback="true"
  if [ "${router_target_count:-1}" != "1" ] && [ "$suffix" = "HOST" ]; then
    allow_common_fallback="false"
  fi
  scoped_env_value="${!scoped_key:-}"
  common_env_value="${!common_key:-}"

  if [ -n "$scoped_env_value" ]; then
    encrypted_dotenv_upsert "$scoped_key" "$scoped_env_value" "$passwords_enc_file" "$age_keys_file" "$passwords_enc_file_rel"
    printf '%s\n' "$scoped_env_value"
    return 0
  fi

  scoped_saved_value="$(decrypt_env_key_value "$passwords_enc_file" "$scoped_key" "$age_keys_file" || true)"
  if [ -n "$scoped_saved_value" ]; then
    printf '%s\n' "$scoped_saved_value"
    return 0
  fi

  if [ "$default_to_common" = "true" ] && [ -n "$common_env_value" ]; then
    encrypted_dotenv_upsert "$scoped_key" "$common_env_value" "$passwords_enc_file" "$age_keys_file" "$passwords_enc_file_rel"
    printf '%s\n' "$common_env_value"
    return 0
  fi

  if [ "$default_to_common" = "true" ]; then
    common_saved_value="$(decrypt_env_key_value "$passwords_enc_file" "$common_key" "$age_keys_file" || true)"
    if [ -n "$common_saved_value" ]; then
      encrypted_dotenv_upsert "$scoped_key" "$common_saved_value" "$passwords_enc_file" "$age_keys_file" "$passwords_enc_file_rel"
      printf '%s\n' "$common_saved_value"
      return 0
    fi
  fi

  prompt_if_missing_encrypted_env_key "$passwords_enc_file" "$scoped_key" "$router_name $prompt_text" "$age_keys_file" "$passwords_enc_file_rel"
}

split_router_targets() {
  routers_raw="${MIKROTIK_ROUTERS:-}"
  if [ -z "$routers_raw" ]; then
    routers_raw="${MIKROTIK_NAME:-$(get_config_key MIKROTIK_NAME)}"
  fi
  if [ -z "$routers_raw" ]; then
    routers_raw='hap-ax2'
  fi
  printf '%s' "$routers_raw" | tr ',' '\n' | sed -E 's/^ +//; s/ +$//; /^$/d'
}

echo 'Step 1/6: Resolve MikroTik connection and desired-state settings.'

router_targets="$(split_router_targets)"
router_target_count="$(printf '%s\n' "$router_targets" | sed '/^$/d' | wc -l | tr -d ' ')"

mikrotik_host_key_checking="$(prompt_config_default MIKROTIK_HOST_KEY_CHECKING 'MikroTik host key checking true/false: ' 'false')"
mikrotik_command_timeout_default="$(prompt_config_default MIKROTIK_COMMAND_TIMEOUT 'MikroTik command timeout seconds: ' '120')"
mikrotik_safe_mode="$(prompt_config_default MIKROTIK_SAFE_MODE 'Enable best-effort RouterOS safe mode true/false: ' 'false')"
mikrotik_auto_rollback="$(prompt_config_default MIKROTIK_AUTO_ROLLBACK_ON_FAILURE 'Auto rollback on failed import true/false: ' 'true')"
mikrotik_apply_serial="$(prompt_config_default MIKROTIK_APPLY_SERIAL 'Router apply serial count: ' '1')"

reject_multiline_value MIKROTIK_HOST_KEY_CHECKING "$mikrotik_host_key_checking"
reject_multiline_value MIKROTIK_COMMAND_TIMEOUT "$mikrotik_command_timeout_default"
reject_multiline_value MIKROTIK_SAFE_MODE "$mikrotik_safe_mode"
reject_multiline_value MIKROTIK_AUTO_ROLLBACK_ON_FAILURE "$mikrotik_auto_rollback"
reject_multiline_value MIKROTIK_APPLY_SERIAL "$mikrotik_apply_serial"

echo 'Step 2/6: Prepare temporary Ansible inventory and secret vars.'

touch "$inventory_file" "$extra_vars_file"
chmod 600 "$inventory_file" "$extra_vars_file"

cat > "$inventory_file" <<EOF_INVENTORY
---
# ==============================================================================
# File: state/tmp/mikrotik-inventory.yml
# Purpose:
#   Temporary Ansible inventory for MikroTik desired-state operations.
# Notes:
#   - Generated by scripts/router/mikrotik-run.sh.
#   - Removed automatically after the run.
#   - Stored with mode 0600 because it includes connection and desired-state secrets.
# ==============================================================================
all:
  children:
    mikrotik:
      hosts:
EOF_INVENTORY

while IFS= read -r router_name; do
  [ -n "$router_name" ] || continue
  router_key="$(normalise_router_key "$router_name")"
  router_host="$(prompt_config_scoped "$router_name" HOST 'host or IP: ' '')"
  router_user="$(prompt_config_scoped "$router_name" USER 'SSH username: ' 'admin')"
  router_port="$(prompt_config_scoped "$router_name" PORT 'SSH port: ' '22')"
  router_identity="$(prompt_config_scoped "$router_name" ROUTER_IDENTITY 'Router identity: ' 'RTR-MAIN')"
  router_timeout="$(prompt_config_scoped "$router_name" COMMAND_TIMEOUT 'command timeout seconds: ' "$mikrotik_command_timeout_default")"

  router_password="$(prompt_secret_scoped "$router_name" PASSWORD 'SSH password: ' true)"
  router_admin_password="$(prompt_secret_scoped "$router_name" ROUTER_ADMIN_PASSWORD 'admin password to set after apply: ' true)"
  wifi_users_passphrase="$(prompt_secret_scoped "$router_name" WIFI_USERS_PASSPHRASE 'Users WiFi passphrase: ' true)"
  wifi_mgmt_passphrase="$(prompt_secret_scoped "$router_name" WIFI_MGMT_PASSPHRASE 'Management WiFi passphrase: ' true)"
  wifi_iot_passphrase="$(prompt_secret_scoped "$router_name" WIFI_IOT_PASSPHRASE 'IoT WiFi passphrase: ' true)"
  wifi_guest_passphrase="$(prompt_secret_scoped "$router_name" WIFI_GUEST_PASSPHRASE 'Guest WiFi passphrase: ' true)"

  for pair in \
    "MIKROTIK_${router_key}_HOST:$router_host" \
    "MIKROTIK_${router_key}_USER:$router_user" \
    "MIKROTIK_${router_key}_PASSWORD:$router_password" \
    "MIKROTIK_${router_key}_PORT:$router_port" \
    "MIKROTIK_${router_key}_COMMAND_TIMEOUT:$router_timeout" \
    "MIKROTIK_${router_key}_ROUTER_IDENTITY:$router_identity"; do
    key_name="${pair%%:*}"
    key_value="${pair#*:}"
    reject_multiline_value "$key_name" "$key_value"
  done

  cat >> "$inventory_file" <<EOF_HOST
        $(yaml_single_quote_value "$router_name"):
          ansible_host: $(yaml_single_quote_value "$router_host")
          ansible_user: $(yaml_single_quote_value "$router_user")
          ansible_password: $(yaml_single_quote_value "$router_password")
          ansible_port: $(yaml_single_quote_value "$router_port")
          ansible_connection: ansible.netcommon.network_cli
          ansible_network_os: community.routeros.routeros
          ansible_command_timeout: $(yaml_single_quote_value "$router_timeout")
          mikrotik_router_identity: $(yaml_single_quote_value "$router_identity")
          mikrotik_router_admin_password: $(yaml_single_quote_value "$router_admin_password")
          mikrotik_router_wifi_passphrase_users: $(yaml_single_quote_value "$wifi_users_passphrase")
          mikrotik_router_wifi_passphrase_mgmt: $(yaml_single_quote_value "$wifi_mgmt_passphrase")
          mikrotik_router_wifi_passphrase_iot: $(yaml_single_quote_value "$wifi_iot_passphrase")
          mikrotik_router_wifi_passphrase_guest: $(yaml_single_quote_value "$wifi_guest_passphrase")
EOF_HOST
done <<EOF_TARGETS
$router_targets
EOF_TARGETS

cat > "$extra_vars_file" <<EOF_VARS
---
# ==============================================================================
# File: state/tmp/mikrotik-runtime-vars.yml
# Purpose:
#   Temporary non-secret runtime variables for MikroTik desired-state operations.
# Notes:
#   - Generated by scripts/router/mikrotik-run.sh.
#   - Removed automatically after the run.
#   - Must contain at least one mapping entry because ansible-playbook -e @file
#     rejects YAML documents that resolve to null.
# ==============================================================================
mikrotik_runtime_vars_generated: true
EOF_VARS

echo 'Step 3/6: Select execution mode.'

case "$mode" in
  render)
    export MIKROTIK_RENDER_ONLY=true
    export MIKROTIK_APPLY_CONFIG=false
    ;;
  plan)
    export MIKROTIK_RENDER_ONLY=false
    export MIKROTIK_APPLY_CONFIG=false
    ;;
  apply)
    export MIKROTIK_RENDER_ONLY=false
    export MIKROTIK_APPLY_CONFIG=true
    echo 'Apply mode selected. The playbook will render and plan first, then ask for post-plan confirmation.'
    ;;
  *)
    echo "ERROR: Unknown MikroTik mode: $mode" >&2
    echo 'Use render, plan, or apply.' >&2
    exit 1
    ;;
esac

export MIKROTIK_OUTPUT_DIR="$output_dir"
export MIKROTIK_SAFE_MODE="$mikrotik_safe_mode"
export MIKROTIK_AUTO_ROLLBACK_ON_FAILURE="$mikrotik_auto_rollback"
export MIKROTIK_APPLY_SERIAL="$mikrotik_apply_serial"
export ANSIBLE_CONFIG="${root_dir}/ansible.cfg"
export ANSIBLE_ROLES_PATH="${root_dir}/ansible/roles${ANSIBLE_ROLES_PATH:+:${ANSIBLE_ROLES_PATH}}"
export ANSIBLE_COLLECTIONS_PATH="${root_dir}/ansible/collections:${HOME}/.ansible/collections:/usr/share/ansible/collections${ANSIBLE_COLLECTIONS_PATH:+:${ANSIBLE_COLLECTIONS_PATH}}"

echo 'Step 4/6: Run MikroTik Ansible desired-state playbook.'

ANSIBLE_HOST_KEY_CHECKING="$mikrotik_host_key_checking" \
  "$ansible_playbook_cmd" \
    -i "$inventory_file" \
    "${root_dir}/ansible/playbooks/router/apply.yml" \
    -e "@${extra_vars_file}"

echo 'Step 5/6: Remove temporary inventory and secret vars.'
cleanup_runtime_files
trap - EXIT

echo 'Step 6/6: MikroTik operation completed.'
echo "Output folder: $output_dir"
