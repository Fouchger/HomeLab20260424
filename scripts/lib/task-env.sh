#!/usr/bin/env sh
# ==============================================================================
# File: scripts/lib/task-env.sh
# Purpose:
#   Shared POSIX shell helpers for Taskfile command blocks.
# Notes:
#   - Supports simple KEY=VALUE dotenv files only.
#   - Prompts only when callers request input and a TTY is available.
#   - Keeps local configuration idempotent by updating existing keys in place.
# ==============================================================================

set -eu

get_env_value() {
  file_path="${1:?Missing env file path}"
  key_name="${2:?Missing key name}"

  if [ ! -f "$file_path" ]; then
    return 1
  fi

  awk -F= -v key="$key_name" '
    $0 ~ "^[[:space:]]*#" { next }
    $1 == key {
      sub(/^[^=]*=/, "")
      print
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file_path"
}

ensure_env_key_value() {
  file_path="${1:?Missing env file path}"
  key_name="${2:?Missing key name}"
  key_value="${3-}"
  tmp_file=""

  case "$key_value" in
    *"
"*)
      printf '%s\n' "ERROR: Multi-line values are not supported for $key_name" >&2
      return 1
      ;;
  esac

  mkdir -p "$(dirname "$file_path")"
  if [ ! -f "$file_path" ]; then
    : > "$file_path"
    chmod 600 "$file_path" 2>/dev/null || true
  fi

  tmp_file="$(mktemp)"
  if grep -q "^${key_name}=" "$file_path"; then
    awk -v key="$key_name" -v value="$key_value" '
      $0 ~ "^" key "=" { print key "=" value; next }
      { print }
    ' "$file_path" > "$tmp_file"
  else
    cat "$file_path" > "$tmp_file"
    printf '%s=%s\n' "$key_name" "$key_value" >> "$tmp_file"
  fi

  cat "$tmp_file" > "$file_path"
  rm -f "$tmp_file"
  chmod 600 "$file_path" 2>/dev/null || true
}

require_tty() {
  prompt_name="${1:-input}"
  if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
    printf '%s\n' "ERROR: $prompt_name is required but no interactive TTY is available." >&2
    return 1
  fi
}

tty_prompt() {
  prompt_text="${1:-Value: }"
  answer=""
  if [ -r /dev/tty ]; then
    printf '%s' "$prompt_text" > /dev/tty
    IFS= read -r answer < /dev/tty
  else
    printf '%s' "$prompt_text" >&2
    IFS= read -r answer
  fi
  printf '%s\n' "$answer"
}

tty_prompt_secret() {
  prompt_text="${1:-Secret: }"
  answer=""
  if [ -r /dev/tty ]; then
    printf '%s' "$prompt_text" > /dev/tty
    stty -echo < /dev/tty || true
    IFS= read -r answer < /dev/tty
    stty echo < /dev/tty || true
    printf '\n' > /dev/tty
  else
    printf '%s' "$prompt_text" >&2
    IFS= read -r answer
  fi
  printf '%s\n' "$answer"
}

prompt_if_missing_env_key() {
  file_path="${1:?Missing env file path}"
  key_name="${2:?Missing key name}"
  prompt_text="${3:-Value: }"

  existing_value="$(get_env_value "$file_path" "$key_name" || true)"

  if [ -n "$existing_value" ]; then
    printf '%s\n' "$existing_value"
    return 0
  fi

  require_tty "$key_name"

  input_value="$(tty_prompt "$prompt_text")"

  if [ -z "$input_value" ]; then
    printf '%s\n' "ERROR: $key_name cannot be empty." >&2
    return 1
  fi

  ensure_env_key_value "$file_path" "$key_name" "$input_value"
  printf '%s\n' "$input_value"
}

encrypted_dotenv_upsert() {
  key_name="${1:?Missing key name}"
  key_value="${2-}"
  encrypted_file="${3:?Missing encrypted dotenv file path}"
  age_keys_file="${4:?Missing age keys file path}"
  filename_override="${5:-$encrypted_file}"

  tmp_plain="$(mktemp)"
  tmp_encrypted="$(mktemp)"

  cleanup_encrypted_dotenv_upsert() {
    rm -f "$tmp_plain" "$tmp_encrypted"
  }
  trap cleanup_encrypted_dotenv_upsert EXIT

  mkdir -p "$(dirname "$encrypted_file")"

  if [ -f "$encrypted_file" ]; then
    SOPS_AGE_KEY_FILE="$age_keys_file" sops --decrypt --input-type dotenv --output-type dotenv "$encrypted_file" > "$tmp_plain"
  else
    : > "$tmp_plain"
  fi

  ensure_env_key_value "$tmp_plain" "$key_name" "$key_value"

  SOPS_AGE_KEY_FILE="$age_keys_file" sops --encrypt \
    --filename-override "$filename_override" \
    --input-type dotenv \
    --output-type dotenv \
    "$tmp_plain" > "$tmp_encrypted"

  cat "$tmp_encrypted" > "$encrypted_file"
  chmod 600 "$encrypted_file"
}

ensure_parent_dir() {
  file_path="${1:?Missing file path}"
  mkdir -p "$(dirname "$file_path")"
}

require_command() {
  command_name="${1:?Missing command name}"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf '%s\n' "ERROR: Required command not found: $command_name" >&2
    printf '%s\n' "Install $command_name and rerun the task." >&2
    return 1
  fi
}