#!/usr/bin/env bash
# ################################################################
# File: install.sh
# Created: 2026/04/12
# Updated: 2026/04/12
# Description:
#   Production-ready bootstrap installer for Fouchger/Fouchger_Homelab.
#
# Notes:
#   - Debian/Ubuntu oriented (apt-get).
#   - Clones or updates the repo using GitHub CLI (gh) when available.
#   - Falls back to plain git clone when gh is unavailable or not authenticated.
#   - Supports non-interactive runs via: NONINTERACTIVE=1.
#   - Non-interactive mode defaults to SETUP=prod when SETUP is not provided.
#   - Creates install metadata in: $ROOT_DIR/state/config/.env when missing.
#   - Update flow preserves functionality but is safer:
#       - If local changes exist, user can choose: commit, stash, or abort.
#       - In non-interactive mode, local changes are stashed automatically.
#   - Task installation is treated as part of the installer outcome.
#
# Defaults:
#   SETUP="${SETUP:-prod}"                      # prod or dev
#   HOMELAB_BRANCH="${HOMELAB_BRANCH:-main}"
#   HOMELAB_GIT_PROTOCOL="${HOMELAB_GIT_PROTOCOL:-https}"  # https or ssh
#   NONINTERACTIVE="${NONINTERACTIVE:-0}"      # 1 disables prompts where feasible
#
# Example:
#   ./install.sh
#   SETUP=dev HOMELAB_BRANCH=main ./install.sh
#   NONINTERACTIVE=1 ./install.sh
# ################################################################

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# ----------------------------
# Simple logging helpers
# ----------------------------
_info()    { printf '%s\n' "INFO: $*"; }
_warn()    { printf '%s\n' "WARN: $*"; }
_error()   { printf '%s\n' "ERROR: $*" >&2; }
_success() { printf '%s\n' "SUCCESS: $*"; }

# ----------------------------
# Globals used across steps
# ----------------------------
readonly REPO="HomeLab20260424"
readonly REPO_BRANCH="main"
readonly REPO_SLUG="Fouchger/${REPO}"

BRANCH="${HOMELAB_BRANCH:-${REPO_BRANCH}}"
TARGET_DIR=""
ROOT_DIR=""
NONINTERACTIVE="${NONINTERACTIVE:-0}"
SETUP="${SETUP:-}"
TASK_INSTALL_REQUIRED="${TASK_INSTALL_REQUIRED:-1}"
REPO_UPDATE_SKIPPED="0"

# ----------------------------
# Error handling
# ----------------------------
_on_error() {
  local exit_code="$1"
  local line_no="$2"
  _error "Install failed at line ${line_no} with exit code ${exit_code}."
  exit "${exit_code}"
}
trap '_on_error "$?" "$LINENO"' ERR

# ----------------------------
# Banner
# ----------------------------
_banner() {
  echo "=========================================================="
  echo "       Fouchger Homelab installer (bootstrap phase)       "
  echo "=========================================================="
}

# ----------------------------
# OS and privilege helpers
# ----------------------------
_is_debian_family() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID_LIKE:-}" == *debian* || "${ID:-}" == "debian" || "${ID:-}" == "ubuntu" ]]
}

_have_sudo() {
  command -v sudo >/dev/null 2>&1
}

_have_root() {
  [[ "${EUID}" -eq 0 ]]
}

_require_root_or_sudo() {
  if _have_root || _have_sudo; then
    return 0
  fi

  _error "This installer needs root privileges for package installation. Run as root or install sudo."
  exit 1
}

_as_root() {
  if _have_root; then
    "$@"
  else
    sudo -E "$@"
  fi
}

# ----------------------------
# Apt helpers
# Notes:
#   - apt-get is used for script stability.
#   - update is cached in-memory for this run to reduce repeat calls.
# ----------------------------
APT_UPDATED=0

_apt_update() {
  local -a env_args=()

  _require_root_or_sudo

  if [[ "${APT_UPDATED}" -eq 1 ]]; then
    return 0
  fi

  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    env_args=("DEBIAN_FRONTEND=noninteractive")
  fi

  _info "Refreshing apt package metadata..."
  _as_root env "${env_args[@]}" apt-get update -y
  APT_UPDATED=1
}

_apt_install() {
  local -a env_args=()

  _require_root_or_sudo

  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    env_args=("DEBIAN_FRONTEND=noninteractive")
  fi

  # shellcheck disable=SC2068
  _as_root env "${env_args[@]}" apt-get install -y --no-install-recommends "$@"
}

_pkg_installed() {
  local pkg="${1:?Missing package name}"
  dpkg -s "${pkg}" >/dev/null 2>&1
}

_ensure_pkg_installed() {
  local pkg="${1:?Missing package name}"

  if _pkg_installed "${pkg}"; then
    return 0
  fi

  _info "Package not found. Installing: ${pkg}"
  _apt_update
  _apt_install "${pkg}"
}

_ensure_cmd_or_install() {
  local cmd="${1:?Missing command name}"
  local pkg="${2:?Missing package name}"

  if command -v "${cmd}" >/dev/null 2>&1; then
    return 0
  fi

  _info "Command not found. Installing package '${pkg}' for '${cmd}'."
  _apt_update
  _apt_install "${pkg}"
}

# ----------------------------
# Determine if gh is usable
# Notes:
#   - Supports token-based non-interactive auth.
#   - Falls back cleanly to git clone when unavailable.
# ----------------------------
_gh_usable() {
  command -v gh >/dev/null 2>&1 || return 1

  if [[ -n "${GITHUB_TOKEN:-}" || -n "${GH_TOKEN:-}" ]]; then
    return 0
  fi

  gh auth status -h github.com >/dev/null 2>&1
}

# ----------------------------
# Ensure base prerequisites
# ----------------------------
_ensure_prereqs() {
  if ! _is_debian_family; then
    _error "Unsupported operating system. This installer is intended for Debian or Ubuntu."
    exit 1
  fi

  _ensure_cmd_or_install git git
  _ensure_cmd_or_install curl curl
  _ensure_pkg_installed ca-certificates
}

# ----------------------------
# Optional helper: validate a git branch name
# Notes:
#   - Prevents obvious bad input reaching git commands.
# ----------------------------
_validate_branch_name() {
  if ! git check-ref-format --branch "${BRANCH}" >/dev/null 2>&1; then
    _error "Invalid branch name: ${BRANCH}"
    exit 1
  fi
}

# ----------------------------
# Choose SETUP unless already provided
# ----------------------------
_set_environment() {
  if [[ -n "${SETUP}" ]]; then
    case "${SETUP}" in
      prod|dev)
        _info "SETUP already set to: ${SETUP}"
        export SETUP
        return 0
        ;;
      *)
        _error "Invalid SETUP='${SETUP}'. Must be 'prod' or 'dev'."
        exit 1
        ;;
    esac
  fi

  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    SETUP="prod"
    export SETUP
    _info "NONINTERACTIVE=1 detected. Defaulting SETUP to: ${SETUP}"
    return 0
  fi

  while true; do
    read -r -p "Select SETUP environment [prod/dev] (default: prod): " SETUP < /dev/tty
    SETUP="${SETUP:-prod}"
    case "${SETUP}" in
      prod|dev)
        export SETUP
        _info "SETUP set to: ${SETUP}"
        return 0
        ;;
      *)
        echo "Invalid choice. Please enter 'prod' or 'dev'."
        ;;
    esac
  done
}

# ----------------------------
# Resolve install directory
# ----------------------------
_set_target_dir() {
  case "${SETUP}" in
    prod) TARGET_DIR="${HOME}/app/${REPO}" ;;
    dev)  TARGET_DIR="${HOME}/Github/${REPO}" ;;
    *)
      _error "SETUP must be 'prod' or 'dev'."
      exit 1
      ;;
  esac

  mkdir -p "$(dirname "${TARGET_DIR}")"
}

# ----------------------------
# Build repository URL for plain git
# ----------------------------
_repo_url_from_protocol() {
  local protocol="${HOMELAB_GIT_PROTOCOL:-https}"

  case "${protocol}" in
    ssh)
      printf '%s\n' "git@github.com:${REPO_SLUG}.git"
      ;;
    https)
      printf '%s\n' "https://github.com/${REPO_SLUG}.git"
      ;;
    *)
      _warn "Unknown HOMELAB_GIT_PROTOCOL='${protocol}'. Defaulting to https."
      printf '%s\n' "https://github.com/${REPO_SLUG}.git"
      ;;
  esac
}

# ----------------------------
# Clone repo
# Notes:
#   - gh path is used when available.
#   - Branch is explicitly fetched and checked out after clone.
#   - This keeps branch handling consistent and easier to diagnose.
# ----------------------------
_clone_repo() {
  local url=""

  if _gh_usable; then
    _info "Using GitHub CLI to clone ${REPO_SLUG}"
    gh repo clone "${REPO_SLUG}" "${TARGET_DIR}"

    pushd "${TARGET_DIR}" >/dev/null
    _info "Fetching and checking out branch '${BRANCH}'..."
    git fetch --prune origin

    if git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
      git checkout -B "${BRANCH}" "origin/${BRANCH}"
      popd >/dev/null
      return 0
    fi

    popd >/dev/null
    _error "Branch '${BRANCH}' was not found on origin."
    return 1
  fi

  _warn "GitHub CLI is unavailable or not authenticated. Falling back to git clone."
  url="$(_repo_url_from_protocol)"

  _info "Cloning via git from: ${url}"
  git clone --branch "${BRANCH}" --single-branch "${url}" "${TARGET_DIR}"
}

# ----------------------------
# Update existing repo safely
# Notes:
#   - Handles dirty working trees.
#   - In non-interactive mode, local changes are stashed automatically.
#   - If the user selects abort, the installer continues with the
#     existing local repository without pulling updates.
# ----------------------------
_update_repo() {
  local action=""
  local commit_msg=""

  if [[ ! -d "${TARGET_DIR}/.git" ]]; then
    _error "Target exists but is not a git repository: ${TARGET_DIR}"
    return 1
  fi

  pushd "${TARGET_DIR}" >/dev/null

  _info "Fetching updates from origin..."
  git fetch --prune origin

  _info "Checking out branch '${BRANCH}'..."
  if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    git checkout "${BRANCH}"
  elif git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
    git checkout -b "${BRANCH}" "origin/${BRANCH}"
  else
    popd >/dev/null
    _error "Branch '${BRANCH}' was not found on origin."
    return 1
  fi

  _info "Current branch status:"
  git status --short --branch || true

  if [[ -n "$(git status --porcelain)" ]]; then
    _warn "Local changes detected in ${TARGET_DIR}."

    if [[ "${NONINTERACTIVE}" == "1" ]]; then
      action="s"
      _warn "NONINTERACTIVE=1 detected. Defaulting to: stash local changes."
    else
      echo "Choose how to handle local changes:"
      echo "  [c] Commit changes and continue"
      echo "  [s] Stash changes and continue"
      echo "  [a] Abort update and continue with local files"
      while true; do
        read -r -p "Action [c/s/a] (default: a): " action < /dev/tty
        action="${action:-a}"
        case "${action}" in
          c|C|s|S|a|A) break ;;
          *) echo "Please enter c, s, or a." ;;
        esac
      done
    fi

    case "${action}" in
      a|A)
        REPO_UPDATE_SKIPPED="1"
        popd >/dev/null
        _warn "Update skipped at user request. Continuing with existing local repository."
        return 0
        ;;
      s|S)
        _info "Stashing local changes..."
        git stash push -u -m "bootstrap: auto-stash before update ($(date -Is))"
        _success "Changes stashed."
        ;;
      c|C)
        if [[ "${NONINTERACTIVE}" == "1" ]]; then
          commit_msg="WIP: local changes"
        else
          read -r -p "Commit message (default: 'WIP: local changes'): " commit_msg < /dev/tty
          commit_msg="${commit_msg:-WIP: local changes}"
        fi

        git add -A
        if git diff --cached --quiet; then
          popd >/dev/null
          _warn "Nothing staged to commit. Continuing without update."
          REPO_UPDATE_SKIPPED="1"
          return 0
        fi

        git commit -m "${commit_msg}"
        _info "Changes committed."
        ;;
    esac
  fi

  _info "Pulling latest changes with rebase and autostash..."
  git pull --rebase --autostash origin "${BRANCH}"

  popd >/dev/null
  return 0
}

# ----------------------------
# Clone-or-update wrapper
# ----------------------------
_clone_or_update_homelab_repo() {
  _ensure_prereqs
  _validate_branch_name
  _set_target_dir

  if [[ ! -e "${TARGET_DIR}" ]]; then
    _info "Cloning ${REPO_SLUG} (${BRANCH}) into ${TARGET_DIR}"
    _clone_repo
    _success "Repository cloned: ${TARGET_DIR}"
    return 0
  fi

  if [[ -f "${TARGET_DIR}" ]]; then
    _error "Target path exists and is a file, not a directory: ${TARGET_DIR}"
    return 1
  fi

  _info "Repository directory exists. Updating: ${TARGET_DIR}"
  _update_repo

  if [[ "${REPO_UPDATE_SKIPPED}" == "1" ]]; then
    _warn "Repository update skipped. Using local working tree: ${TARGET_DIR}"
  else
    _success "Repository updated: ${TARGET_DIR}"
  fi
}

# ----------------------------
# Find ROOT_DIR by marker
# Notes:
#   - Falls back to TARGET_DIR when the marker is not found.
#   - This keeps behaviour flexible for nested execution models.
# ----------------------------
_find_root_dir() {
  local marker=".root_marker"
  local dir=""

  dir="$(cd "${TARGET_DIR}" 2>/dev/null && pwd)" || return 1

  while :; do
    if [[ -f "${dir}/${marker}" ]]; then
      ROOT_DIR="${dir}"
      export ROOT_DIR
      _info "ROOT_DIR detected: ${ROOT_DIR}"
      return 0
    fi

    if [[ "${dir}" == "/" ]]; then
      break
    fi

    dir="$(dirname "${dir}")"
  done

  ROOT_DIR="${TARGET_DIR}"
  export ROOT_DIR
  _warn "Marker ${marker} not found. Falling back to ROOT_DIR=${ROOT_DIR}"
  return 0
}

# ----------------------------
# Normalise executable permissions
# Notes:
#   - Makes all *.sh files executable.
#   - Also applies config/executable.list when present.
# ----------------------------
_ensure_executables() {
  local root="${ROOT_DIR}"
  local list_file="${root}/config/executable.list"
  local file_path=""
  local line=""
  local target_path=""

  _info "Normalising executable permissions under: ${root}"

  while IFS= read -r -d '' file_path; do
    chmod +x "${file_path}" 2>/dev/null || true
  done < <(find "${root}" -type f -name "*.sh" -print0)

  if [[ -f "${list_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line%$'\r'}"
      [[ -z "${line}" ]] && continue
      [[ "${line}" =~ ^[[:space:]]*# ]] && continue

      target_path="${root}/${line}"
      if [[ -f "${target_path}" ]]; then
        chmod +x "${target_path}" 2>/dev/null || true
      else
        _warn "executable.list entry not found: ${line}"
      fi
    done < "${list_file}"
  fi

  _success "Executable permissions normalised."
}

# ----------------------------
# Dotenv helper
# Notes:
#   - Supports simple KEY=VALUE writes.
#   - Avoids multi-line values for dotenv compatibility.
# ----------------------------
_dotenv_upsert() {
  local key="${1:?Missing key}"
  local value="${2-}"
  local file="${3:?Missing file}"
  local tmp=""

  if [[ "${value}" == *$'\n'* ]]; then
    _warn "Skipping dotenv update for ${key}. Multi-line values are not supported."
    return 0
  fi

  if grep -qE "^[[:space:]]*${key}=" "${file}"; then
    tmp="$(mktemp)"
    awk -v k="${key}" -v v="${value}" '
      $0 ~ "^[[:space:]]*" k "=" { print k "=" v; next }
      { print }
    ' "${file}" > "${tmp}"
    mv "${tmp}" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

# ----------------------------
# Render local state env content
# Notes:
#   - Generates installer bootstrap content only when the file is missing.
# ----------------------------
_render_state_env_content() {
  local root_dir_value="${TARGET_DIR}"
  local github_repo_value="${REPO_SLUG}"
  local github_branch_value="${BRANCH}"
  local setup_value="${SETUP}"
  local noninteractive_value="${NONINTERACTIVE}"

  cat <<EOF
# ################################################################
# File: state/config/.env
# Created: 2026/03/07
# Updated: 2026/03/30
# Description:
#   Local environment settings for homelab bootstrap and runtime.
# Notes:
#   - Created by install.sh for this host only when missing.
#   - Keep values simple KEY=VALUE format.
#   - Multi-line values are intentionally not supported here.
# ################################################################

ROOT_DIR=${root_dir_value}
GITHUB_REPO=${github_repo_value}
GITHUB_BRANCH=${github_branch_value}
SETUP=${setup_value}
NONINTERACTIVE=${noninteractive_value}
EOF
}

# ----------------------------
# Create canonical env file if missing
# ----------------------------
_create_env_file_if_missing() {
  local env_dir="${ROOT_DIR}/state/config"
  local env_file="${env_dir}/.env"
  local tmp_env=""

  mkdir -p "${env_dir}"

  if [[ -f "${env_file}" ]]; then
    _info "Existing env file preserved: ${env_file}"
    return 0
  fi

  tmp_env="$(mktemp)"
  _render_state_env_content > "${tmp_env}"
  install -m 0600 "${tmp_env}" "${env_file}"
  rm -f "${tmp_env}"

  _success "Created ${env_file}"
}

# ----------------------------
# Install Task (taskfile) securely and idempotently
# Notes:
#   - Uses upstream repository setup script with HTTPS and retry guardrails.
#   - Ensures required packages exist before execution.
#   - Treated as part of overall installer completion.
# ----------------------------
_taskfile_install() {
  if [[ "${TASK_INSTALL_REQUIRED}" != "1" ]]; then
    _info "TASK_INSTALL_REQUIRED=${TASK_INSTALL_REQUIRED}. Skipping Task installation."
    return 0
  fi

  if command -v task >/dev/null 2>&1; then
    _info "Task is already installed."
    return 0
  fi

  _info "Installing Task (taskfile)..."

  _ensure_cmd_or_install gpg gnupg

  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 \
    'https://dl.cloudsmith.io/public/task/task/setup.deb.sh' \
    | _as_root bash

  _apt_update
  _apt_install task

  if command -v task >/dev/null 2>&1; then
    _success "Task installed."
    return 0
  fi

  _error "Task installation failed."
  return 1
}

# ----------------------------
# Summary
# ----------------------------
_print_summary() {
  _info "Bootstrap summary:"
  _info "  TARGET_DIR: ${TARGET_DIR}"
  _info "  ROOT_DIR:   ${ROOT_DIR}"
  _info "  BRANCH:     ${BRANCH}"
  _info "  SETUP:      ${SETUP}"
  _info "  ENV_FILE:   ${ROOT_DIR}/state/config/.env"
  _info "  TASK_REQ:   ${TASK_INSTALL_REQUIRED}"
  _info "  REPO_UPDATE_SKIPPED: ${REPO_UPDATE_SKIPPED}"
}

# ----------------------------
# Main
# ----------------------------
main() {
  _banner
  _set_environment
  _clone_or_update_homelab_repo
  _find_root_dir
  _ensure_executables
  _create_env_file_if_missing
  _taskfile_install
  _print_summary
  _success "Installer complete. Repository is ready at: ${TARGET_DIR}"
}

main "$@"
