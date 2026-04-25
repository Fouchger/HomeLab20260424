#!/usr/bin/env bash
# configure-technitium-homelab.sh
# Production configuration for Technitium DNS in the fouchger.uk / labcore.uk homelab.
# Assumes Technitium is already installed by the ProxmoxVE community-scripts Technitium LXC installer.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="${LOG_FILE:-/var/log/technitium-homelab-config.log}"
STATE_DIR="${STATE_DIR:-/root/technitium-homelab}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/config.env}"
API_BASE="${API_BASE:-http://127.0.0.1:5380}"
TECHNITIUM_SERVICE="${TECHNITIUM_SERVICE:-technitium.service}"

ROLE="${ROLE:-primary}" # primary or secondary
SERVER_IP="${SERVER_IP:-}"
PRIMARY_IP="${PRIMARY_IP:-192.168.30.10}"
SECONDARY_IP="${SECONDARY_IP:-192.168.30.11}"
PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-fouchger.uk}"
DEV_DOMAIN="${DEV_DOMAIN:-labcore.uk}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
API_TOKEN="${API_TOKEN:-}"
NEW_ADMIN_PASSWORD="${NEW_ADMIN_PASSWORD:-}"
BOOTSTRAP_DEFAULT_ADMIN="${BOOTSTRAP_DEFAULT_ADMIN:-true}"
DEFAULT_ADMIN_PASSWORD="${DEFAULT_ADMIN_PASSWORD:-admin}"
TSIG_KEY_NAME="${TSIG_KEY_NAME:-homelab-xfr}"
TSIG_SECRET="${TSIG_SECRET:-}"
CONFIGURE_UFW="${CONFIGURE_UFW:-false}"
ENABLE_BLOCKLISTS="${ENABLE_BLOCKLISTS:-false}"
ENABLE_QUERY_LOGGING="${ENABLE_QUERY_LOGGING:-true}"
FORWARDER_PROTOCOL="${FORWARDER_PROTOCOL:-Https}"
FORWARDERS="${FORWARDERS:-https://cloudflare-dns.com/dns-query (1.1.1.1),https://cloudflare-dns.com/dns-query (1.0.0.1)}"
RECURSION_ACL="${RECURSION_ACL:-192.168.20.0/24,192.168.30.0/24,192.168.40.0/24,192.168.50.0/24,192.168.60.0/24,192.168.70.0/24,192.168.90.0/24}"
ZONE_TRANSFER_ACL="${ZONE_TRANSFER_ACL:-${SECONDARY_IP}/32}"
NOTIFY_ACL="${NOTIFY_ACL:-${PRIMARY_IP}/32}"
TTL="${TTL:-300}"
NS_TTL="${NS_TTL:-3600}"
SOA_TTL="${SOA_TTL:-900}"
RESPONSIBLE_PERSON="${RESPONSIBLE_PERSON:-hostmaster@${PRIMARY_DOMAIN}}"

# Optional comma-separated hosts: fqdn=ip,fqdn=ip
EXTRA_A_RECORDS="${EXTRA_A_RECORDS:-}"
# Optional comma-separated CNAMEs: alias.fqdn=target.fqdn,alias2.fqdn=target2.fqdn
EXTRA_CNAME_RECORDS="${EXTRA_CNAME_RECORDS:-}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root or with sudo." >&2
    exit 1
  fi
}

log() {
  local message="$1"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" | tee -a "$LOG_FILE"
}

fail() {
  log "ERROR: $1"
  exit 1
}

usage() {
  cat <<USAGE
${SCRIPT_NAME}

Configures an existing Technitium DNS Server for the homelab.

Required environment:
  ROLE=primary|secondary
  SERVER_IP=<this server IP>
  ADMIN_PASSWORD=<current password, or desired final password on fresh install> OR API_TOKEN=<existing token>

Common examples:
  sudo ROLE=primary SERVER_IP=192.168.30.10 ADMIN_PASSWORD='your-current-admin-password' ./${SCRIPT_NAME}
  sudo ROLE=secondary SERVER_IP=192.168.30.11 PRIMARY_IP=192.168.30.10 ADMIN_PASSWORD='secondary-admin-password' TSIG_SECRET='...' ./${SCRIPT_NAME}

Optional environment:
  PRIMARY_DOMAIN=fouchger.uk
  DEV_DOMAIN=labcore.uk
  PRIMARY_IP=192.168.30.10
  SECONDARY_IP=192.168.30.11
  TSIG_SECRET=<shared secret; generated on primary if omitted>
  CONFIGURE_UFW=true|false
  ENABLE_BLOCKLISTS=true|false
  EXTRA_A_RECORDS='host.fouchger.uk=192.168.30.20,app.labcore.uk=192.168.30.21'
  EXTRA_CNAME_RECORDS='www.fouchger.uk=proxy.fouchger.uk'
USAGE
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

json_status() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))'
}

json_value() {
  local expression="$1"
  python3 -c "import json,sys; data=json.load(sys.stdin); print(${expression})"
}

install_tools() {
  local missing=()
  for command_name in curl python3 dig systemctl openssl; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing+=("$command_name")
    fi
  done

  if (( ${#missing[@]} > 0 )) || ! command -v ss >/dev/null 2>&1; then
    log "Installing required tools."
    apt-get update -y
    apt-get install -y curl python3 dnsutils iproute2 ca-certificates openssl
  fi

  if [[ "${CONFIGURE_UFW}" == "true" ]] && ! command -v ufw >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y ufw
  fi
}

validate_inputs() {
  [[ "$ROLE" == "primary" || "$ROLE" == "secondary" ]] || fail "ROLE must be primary or secondary."
  [[ -n "$SERVER_IP" ]] || fail "SERVER_IP is required."
  [[ -n "$ADMIN_PASSWORD" || -n "$API_TOKEN" ]] || fail "Set ADMIN_PASSWORD or API_TOKEN."
  [[ -f /etc/systemd/system/technitium.service || -f /lib/systemd/system/technitium.service ]] || fail "technitium.service was not found. Confirm the community-scripts installer completed successfully."
}

wait_for_api() {
  log "Checking Technitium service and API."
  systemctl enable --now "$TECHNITIUM_SERVICE" >/dev/null 2>&1 || fail "Unable to start ${TECHNITIUM_SERVICE}."

  for _ in {1..40}; do
    if curl -fsS "${API_BASE}/api/user/session/get?token=invalid" >/dev/null 2>&1 || curl -fsS "${API_BASE}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail "Technitium API did not become reachable at ${API_BASE}."
}

api_call() {
  local endpoint="$1"
  shift
  local url="${API_BASE}${endpoint}"
  local sep="?"

  if [[ "$endpoint" == *\?* ]]; then
    sep="&"
  fi

  for arg in "$@"; do
    url="${url}${sep}${arg}"
    sep="&"
  done

  curl -fsS --retry 3 --retry-delay 1 "$url"
}

api_call_token() {
  local endpoint="$1"
  shift
  api_call "$endpoint" "token=$(urlencode "$TOKEN")" "$@"
}

api_ok_or_fail() {
  local description="$1"
  local response="$2"
  local status
  status="$(printf '%s' "$response" | json_status)"
  if [[ "$status" != "ok" ]]; then
    log "${description}: ${response}"
    fail "${description} failed."
  fi
}

try_login_with_password() {
  local candidate_password="$1"
  local response
  if ! response="$(api_call "/api/user/login" "user=$(urlencode "$ADMIN_USER")" "pass=$(urlencode "$candidate_password")" "includeInfo=true" 2>/dev/null)"; then
    return 1
  fi

  if [[ "$(printf '%s' "$response" | json_status)" != "ok" ]]; then
    return 1
  fi

  TOKEN="$(printf '%s' "$response" | json_value 'data["token"]')"
  AUTHENTICATED_PASSWORD="$candidate_password"
  return 0
}

login_or_use_token() {
  USED_DEFAULT_ADMIN="false"
  AUTHENTICATED_PASSWORD=""

  if [[ -n "$API_TOKEN" ]]; then
    TOKEN="$API_TOKEN"
    local response
    response="$(api_call_token "/api/user/session/get")"
    api_ok_or_fail "Validate API token" "$response"
    log "Using supplied API token."
    return 0
  fi

  if [[ -n "$ADMIN_PASSWORD" ]] && try_login_with_password "$ADMIN_PASSWORD"; then
    log "Authenticated to Technitium API using supplied admin password."
    return 0
  fi

  if [[ "$BOOTSTRAP_DEFAULT_ADMIN" == "true" ]] && try_login_with_password "$DEFAULT_ADMIN_PASSWORD"; then
    USED_DEFAULT_ADMIN="true"
    log "Authenticated to Technitium API using fresh-install default credentials."

    # Keep the run command stable: ADMIN_PASSWORD is treated as the desired
    # final password when the local server is still on admin/admin.
    if [[ -n "$ADMIN_PASSWORD" && "$ADMIN_PASSWORD" != "$DEFAULT_ADMIN_PASSWORD" ]]; then
      NEW_ADMIN_PASSWORD="$ADMIN_PASSWORD"
      log "Will rotate fresh-install admin password to the supplied ADMIN_PASSWORD value."
      return 0
    fi

    if [[ -n "$NEW_ADMIN_PASSWORD" && "$NEW_ADMIN_PASSWORD" != "$DEFAULT_ADMIN_PASSWORD" ]]; then
      log "Will rotate fresh-install admin password to NEW_ADMIN_PASSWORD."
      return 0
    fi

    fail "Fresh-install default credentials were detected. Re-run with ADMIN_PASSWORD set to the desired final non-default admin password."
  fi

  fail "Unable to authenticate to Technitium. For configured servers, ADMIN_PASSWORD must be the current local admin password. For fresh servers, set ADMIN_PASSWORD to the desired final non-default password; the script will fall back to admin/admin and rotate it."
}

change_admin_password_if_requested() {
  if [[ -z "$NEW_ADMIN_PASSWORD" || -n "$API_TOKEN" ]]; then
    return 0
  fi

  if [[ "$NEW_ADMIN_PASSWORD" == "$AUTHENTICATED_PASSWORD" ]]; then
    log "Skipping admin password change; NEW_ADMIN_PASSWORD matches current password."
    return 0
  fi

  local response
  response="$(api_call_token "/api/user/changePassword" "pass=$(urlencode "$AUTHENTICATED_PASSWORD")" "newPass=$(urlencode "$NEW_ADMIN_PASSWORD")")"
  api_ok_or_fail "Change admin password" "$response"
  AUTHENTICATED_PASSWORD="$NEW_ADMIN_PASSWORD"
  ADMIN_PASSWORD="$NEW_ADMIN_PASSWORD"
  log "Changed Technitium admin password."
}

ensure_tsig_secret() {
  if [[ -n "$TSIG_SECRET" ]]; then
    return 0
  fi

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    if [[ -n "${TSIG_SECRET:-}" ]]; then
      return 0
    fi
  fi

  if [[ "$ROLE" == "secondary" ]]; then
    fail "TSIG_SECRET is required on the secondary. Run the primary first and copy the TSIG_SECRET from ${STATE_FILE}."
  fi

  TSIG_SECRET="$(openssl rand -base64 32)"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  cat > "$STATE_FILE" <<STATE
# Technitium homelab configuration state
TSIG_KEY_NAME='${TSIG_KEY_NAME}'
TSIG_SECRET='${TSIG_SECRET}'
PRIMARY_DOMAIN='${PRIMARY_DOMAIN}'
DEV_DOMAIN='${DEV_DOMAIN}'
PRIMARY_IP='${PRIMARY_IP}'
SECONDARY_IP='${SECONDARY_IP}'
STATE
  chmod 600 "$STATE_FILE"
  log "Generated TSIG secret and stored it in ${STATE_FILE}. Copy this value to the secondary run."
}

configure_settings() {
  local server_name="dns01.${PRIMARY_DOMAIN}"
  local xfr_acl="$ZONE_TRANSFER_ACL"
  local notify_acl=""

  if [[ "$ROLE" == "secondary" ]]; then
    server_name="dns02.${PRIMARY_DOMAIN}"
    xfr_acl="false"
    notify_acl="$NOTIFY_ACL"
  fi

  local blocklist_urls="false"
  if [[ "$ENABLE_BLOCKLISTS" == "true" ]]; then
    blocklist_urls="https://big.oisd.nl,https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
  fi

  local tsig_rows="${TSIG_KEY_NAME}|${TSIG_SECRET}|hmac-sha256"

  local response
  response="$(api_call_token "/api/settings/set" \
    "dnsServerDomain=$(urlencode "$server_name")" \
    "dnsServerLocalEndPoints=$(urlencode "0.0.0.0:53")" \
    "webServiceLocalAddresses=$(urlencode "0.0.0.0")" \
    "webServiceHttpPort=5380" \
    "webServiceEnableTls=false" \
    "defaultRecordTtl=${TTL}" \
    "defaultNsRecordTtl=${NS_TTL}" \
    "defaultSoaRecordTtl=${SOA_TTL}" \
    "defaultResponsiblePerson=$(urlencode "$RESPONSIBLE_PERSON")" \
    "useSoaSerialDateScheme=true" \
    "dnssecValidation=true" \
    "recursion=UseSpecifiedNetworkACL" \
    "recursionNetworkACL=$(urlencode "$RECURSION_ACL")" \
    "zoneTransferAllowedNetworks=$(urlencode "$xfr_acl")" \
    "notifyAllowedNetworks=$(urlencode "$notify_acl")" \
    "tsigKeys=$(urlencode "$tsig_rows")" \
    "forwarders=$(urlencode "$FORWARDERS")" \
    "forwarderProtocol=${FORWARDER_PROTOCOL}" \
    "concurrentForwarding=true" \
    "qnameMinimization=true" \
    "randomizeName=true" \
    "udpPayloadSize=1232" \
    "logQueries=${ENABLE_QUERY_LOGGING}" \
    "blockListUrls=$(urlencode "$blocklist_urls")")"
  api_ok_or_fail "Configure server settings" "$response"
  log "Configured secure recursive resolver settings for ${server_name}."
}

zone_exists() {
  local zone="$1"
  local response
  response="$(api_call_token "/api/zones/list" "pageNumber=1" "zonesPerPage=500")"
  RESPONSE_JSON="$response" python3 - "$zone" <<'PYZONE'
import json, os, sys
zone = sys.argv[1]
data = json.loads(os.environ["RESPONSE_JSON"])
zones = data.get("response", {}).get("zones", [])
sys.exit(0 if any(item.get("name") == zone for item in zones) else 1)
PYZONE
}

create_zone_if_missing() {
  local zone="$1"
  local type="$2"
  local extra=()

  if zone_exists "$zone"; then
    log "Zone exists: ${zone}."
    return 0
  fi

  if [[ "$type" == "Secondary" ]]; then
    extra+=("primaryNameServerAddresses=$(urlencode "$PRIMARY_IP")")
    extra+=("zoneTransferProtocol=Tcp")
    extra+=("tsigKeyName=$(urlencode "$TSIG_KEY_NAME")")
  else
    extra+=("useSoaSerialDateScheme=true")
  fi

  local response
  response="$(api_call_token "/api/zones/create" "zone=$(urlencode "$zone")" "type=${type}" "${extra[@]}")"
  api_ok_or_fail "Create ${type} zone ${zone}" "$response"
  log "Created ${type} zone: ${zone}."
}

set_primary_zone_options() {
  local zone="$1"
  local response
  response="$(api_call_token "/api/zones/options/set" \
    "zone=$(urlencode "$zone")" \
    "disabled=false" \
    "queryAccess=Allow" \
    "zoneTransfer=UseSpecifiedNetworkACL" \
    "zoneTransferNetworkACL=$(urlencode "${SECONDARY_IP}/32")" \
    "zoneTransferTsigKeyNames=$(urlencode "$TSIG_KEY_NAME")" \
    "notify=SpecifiedNameServers" \
    "notifyNameServers=$(urlencode "$SECONDARY_IP")" \
    "update=Deny")"
  api_ok_or_fail "Set primary zone options ${zone}" "$response"
}

delete_record_if_present() {
  local fqdn="$1"
  local zone="$2"
  local type="$3"
  local value="$4"
  api_call_token "/api/zones/records/delete" \
    "domain=$(urlencode "$fqdn")" \
    "zone=$(urlencode "$zone")" \
    "type=${type}" \
    "value=$(urlencode "$value")" >/dev/null 2>&1 || true
}

add_a() {
  local fqdn="$1"
  local zone="$2"
  local ip="$3"
  local comment="${4:-Managed by homelab configuration script}"
  local ptr="${5:-true}"
  local response
  response="$(api_call_token "/api/zones/records/add" \
    "domain=$(urlencode "$fqdn")" \
    "zone=$(urlencode "$zone")" \
    "type=A" \
    "ttl=${TTL}" \
    "overwrite=true" \
    "ipAddress=$(urlencode "$ip")" \
    "ptr=${ptr}" \
    "createPtrZone=true" \
    "comments=$(urlencode "$comment")")"
  api_ok_or_fail "Add A record ${fqdn}" "$response"
}

add_cname() {
  local fqdn="$1"
  local zone="$2"
  local target="$3"
  local response
  response="$(api_call_token "/api/zones/records/add" \
    "domain=$(urlencode "$fqdn")" \
    "zone=$(urlencode "$zone")" \
    "type=CNAME" \
    "ttl=${TTL}" \
    "overwrite=true" \
    "cname=$(urlencode "$target")" \
    "comments=$(urlencode "Managed by homelab configuration script")")"
  api_ok_or_fail "Add CNAME record ${fqdn}" "$response"
}

add_ns() {
  local zone="$1"
  local ns="$2"
  delete_record_if_present "$zone" "$zone" "NS" "$ns"
  local response
  response="$(api_call_token "/api/zones/records/add" \
    "domain=$(urlencode "$zone")" \
    "zone=$(urlencode "$zone")" \
    "type=NS" \
    "ttl=${NS_TTL}" \
    "overwrite=false" \
    "nameServer=$(urlencode "$ns")" \
    "comments=$(urlencode "Managed by homelab configuration script")")"
  api_ok_or_fail "Add NS record ${zone} -> ${ns}" "$response"
}

configure_primary_zones_and_records() {
  create_zone_if_missing "$PRIMARY_DOMAIN" "Primary"
  create_zone_if_missing "$DEV_DOMAIN" "Primary"
  set_primary_zone_options "$PRIMARY_DOMAIN"
  set_primary_zone_options "$DEV_DOMAIN"

  add_a "dns01.${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN" "$PRIMARY_IP" "Primary Technitium DNS" true
  add_a "dns02.${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN" "$SECONDARY_IP" "Secondary Technitium DNS" true

  for zone in "$PRIMARY_DOMAIN" "$DEV_DOMAIN"; do
    add_ns "$zone" "dns01.${PRIMARY_DOMAIN}"
    add_ns "$zone" "dns02.${PRIMARY_DOMAIN}"
  done
  add_a "router.${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN" "192.168.30.1" "VLAN30 gateway" true
  add_a "router-mgmt.${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN" "192.168.20.1" "VLAN20 gateway" true
  add_a "router-users.${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN" "192.168.40.1" "VLAN40 gateway" true
  add_a "router-iot.${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN" "192.168.50.1" "VLAN50 gateway" true
  add_a "router-guest.${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN" "192.168.60.1" "VLAN60 gateway" true
  add_a "router-storage.${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN" "192.168.70.1" "VLAN70 gateway" true
  add_a "router-dmz.${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN" "192.168.90.1" "VLAN90 gateway" true
  add_a "proxmox.${PRIMARY_DOMAIN}" "$PRIMARY_DOMAIN" "192.168.20.10" "Proxmox management address from router reservation" true

  add_a "dns01.${DEV_DOMAIN}" "$DEV_DOMAIN" "$PRIMARY_IP" "Primary Technitium DNS dev alias" true
  add_a "dns02.${DEV_DOMAIN}" "$DEV_DOMAIN" "$SECONDARY_IP" "Secondary Technitium DNS dev alias" true
  add_cname "router.${DEV_DOMAIN}" "$DEV_DOMAIN" "router.${PRIMARY_DOMAIN}"
  add_cname "proxmox.${DEV_DOMAIN}" "$DEV_DOMAIN" "proxmox.${PRIMARY_DOMAIN}"

  if [[ -n "$EXTRA_A_RECORDS" ]]; then
    IFS=',' read -ra pairs <<< "$EXTRA_A_RECORDS"
    for pair in "${pairs[@]}"; do
      local fqdn="${pair%%=*}"
      local ip="${pair##*=}"
      local zone="$PRIMARY_DOMAIN"
      [[ "$fqdn" == *."$DEV_DOMAIN" ]] && zone="$DEV_DOMAIN"
      add_a "$fqdn" "$zone" "$ip" "Extra A record" true
    done
  fi

  if [[ -n "$EXTRA_CNAME_RECORDS" ]]; then
    IFS=',' read -ra pairs <<< "$EXTRA_CNAME_RECORDS"
    for pair in "${pairs[@]}"; do
      local fqdn="${pair%%=*}"
      local target="${pair##*=}"
      local zone="$PRIMARY_DOMAIN"
      [[ "$fqdn" == *."$DEV_DOMAIN" ]] && zone="$DEV_DOMAIN"
      add_cname "$fqdn" "$zone" "$target"
    done
  fi

  log "Configured primary zones and baseline records."
}

configure_secondary_zones() {
  create_zone_if_missing "$PRIMARY_DOMAIN" "Secondary"
  create_zone_if_missing "$DEV_DOMAIN" "Secondary"
  log "Configured secondary zones. Zone data will be pulled from ${PRIMARY_IP}."
}

configure_firewall() {
  [[ "$CONFIGURE_UFW" == "true" ]] || return 0

  log "Configuring UFW firewall rules."
  ufw allow from 192.168.20.0/24 to any port 5380 proto tcp comment 'Technitium Web UI from MGMT'
  ufw allow from 192.168.20.0/24 to any port 53 comment 'DNS from MGMT'
  ufw allow from 192.168.30.0/24 to any port 53 comment 'DNS from SERVERS'
  ufw allow from 192.168.40.0/24 to any port 53 comment 'DNS from USERS'
  ufw allow from 192.168.50.0/24 to any port 53 comment 'DNS from IOT'
  ufw allow from 192.168.60.0/24 to any port 53 comment 'DNS from GUEST'
  ufw allow from 192.168.70.0/24 to any port 53 comment 'DNS from STORAGE'
  ufw allow from 192.168.90.0/24 to any port 53 comment 'DNS from DMZ'

  if [[ "$ROLE" == "primary" ]]; then
    ufw allow from "$SECONDARY_IP" to any port 53 proto tcp comment 'AXFR from secondary'
  fi

  ufw --force enable
}

smoke_test() {
  log "Running DNS smoke tests."
  sleep 2
  dig @127.0.0.1 "dns01.${PRIMARY_DOMAIN}" A +short | tee -a "$LOG_FILE" >/dev/null || fail "DNS A record test failed."
  dig @127.0.0.1 cloudflare.com A +short | tee -a "$LOG_FILE" >/dev/null || fail "Recursive resolver test failed."

  if [[ "$ROLE" == "primary" ]]; then
    local answer
    answer="$(dig @127.0.0.1 "dns01.${PRIMARY_DOMAIN}" A +short | head -n1)"
    [[ "$answer" == "$PRIMARY_IP" ]] || fail "Expected dns01.${PRIMARY_DOMAIN} to resolve to ${PRIMARY_IP}, got '${answer}'."
  fi

  log "Smoke tests passed."
}

print_summary() {
  cat <<SUMMARY

Configuration complete.

Role:             ${ROLE}
Server IP:        ${SERVER_IP}
Primary domain:   ${PRIMARY_DOMAIN}
Dev domain:       ${DEV_DOMAIN}
Primary DNS:      dns01.${PRIMARY_DOMAIN} / ${PRIMARY_IP}
Secondary DNS:    dns02.${PRIMARY_DOMAIN} / ${SECONDARY_IP}
Web UI:           http://${SERVER_IP}:5380
Log file:         ${LOG_FILE}
State file:       ${STATE_FILE}

Important:
- Keep Cloudflare authoritative for public Internet DNS.
- Keep these Technitium zones for internal split-horizon records only unless you intentionally delegate public DNS to Technitium.
- On the secondary, pass the same TSIG_SECRET generated on the primary.

SUMMARY
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  require_root
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  validate_inputs
  install_tools
  wait_for_api
  login_or_use_token
  change_admin_password_if_requested
  ensure_tsig_secret
  configure_settings

  if [[ "$ROLE" == "primary" ]]; then
    configure_primary_zones_and_records
  else
    configure_secondary_zones
  fi

  configure_firewall
  systemctl restart "$TECHNITIUM_SERVICE"
  wait_for_api
  smoke_test
  print_summary
}

main "$@"
