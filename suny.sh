#!/bin/bash
# suny - Cloudflare IP Rotate Manager
# /opt/suny/suny.sh

set -euo pipefail

CONFIG_DIR="/etc/suny"
STATE_DIR="/var/lib/suny"
CONFIG_FILE="$CONFIG_DIR/config.env"
DOMAINS_FILE="$CONFIG_DIR/domains.list"
LOG_FILE="/var/log/suny.log"

mkdir -p "$CONFIG_DIR" "$STATE_DIR"
touch "$DOMAINS_FILE" "$LOG_FILE"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo suny"
    exit 1
  fi
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN="${CF_API_TOKEN:-}"
DEFAULT_TTL="${DEFAULT_TTL:-120}"
DEFAULT_PROXIED="${DEFAULT_PROXIED:-true}"
EOF
  chmod 600 "$CONFIG_FILE"
}

require_token() {
  load_config
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    echo "Set API Token first (menu option 1)."
    return 1
  fi
}

cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -s -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -s -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

# domains.list line format:
# name|zone_id|record_id|ip1,ip2,ip3|ttl|proxied
list_domains() {
  echo
  echo "===== Domain List ====="
  if [[ ! -s "$DOMAINS_FILE" ]]; then
    echo "No domains configured."
    return
  fi
  local i=1
  while IFS='|' read -r name zone_id record_id ips ttl proxied; do
    [[ -z "$name" || "$name" =~ ^# ]] && continue
    local state_file="$STATE_DIR/${name}.idx"
    local idx=0
    [[ -f "$state_file" ]] && idx=$(cat "$state_file")
    IFS=',' read -r -a arr <<< "$ips"
    local current="${arr[$idx]:-?}"
    echo "$i) $name"
    echo "   IPs: $ips"
    echo "   Current: $current | TTL: $ttl | Proxied: $proxied"
    echo
    i=$((i+1))
  done < "$DOMAINS_FILE"
}

add_domain() {
  require_token || return
  load_config
  echo
  read -rp "Domain/subdomain (e.g. cdn.example.com): " name
  read -rp "Cloudflare Zone ID: " zone_id
  read -rp "DNS Record ID (A record): " record_id
  read -rp "IP list comma-separated (e.g. 1.1.1.1,2.2.2.2,3.3.3.3): " ips
  read -rp "TTL seconds [${DEFAULT_TTL:-120}]: " ttl
  ttl=${ttl:-${DEFAULT_TTL:-120}}
  read -rp "Proxied true/false [${DEFAULT_PROXIED:-true}]: " proxied
  proxied=${proxied:-${DEFAULT_PROXIED:-true}}

  if [[ -f "$DOMAINS_FILE" ]]; then
    grep -v "^${name}|" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp" || true
    mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
  fi

  echo "${name}|${zone_id}|${record_id}|${ips}|${ttl}|${proxied}" >> "$DOMAINS_FILE"
  echo 0 > "$STATE_DIR/${name}.idx"
  log "Domain added: $name"
  echo "Saved."
}

delete_domain() {
  list_domains
  read -rp "Domain name to delete: " name
  if grep -q "^${name}|" "$DOMAINS_FILE" 2>/dev/null; then
    grep -v "^${name}|" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp" || true
    mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
    rm -f "$STATE_DIR/${name}.idx"
    log "Domain deleted: $name"
    echo "Deleted."
  else
    echo "Not found."
  fi
}

rotate_one() {
  local name="$1"
  local line
  line=$(grep "^${name}|" "$DOMAINS_FILE" || true)
  if [[ -z "$line" ]]; then
    echo "Domain not found: $name"
    return 1
  fi

  IFS='|' read -r dname zone_id record_id ips ttl proxied <<< "$line"
  IFS=',' read -r -a arr <<< "$ips"
  local count=${#arr[@]}
  if [[ $count -lt 1 ]]; then
    echo "No IPs for $name"
    return 1
  fi

  local state_file="$STATE_DIR/${name}.idx"
  local idx=0
  [[ -f "$state_file" ]] && idx=$(cat "$state_file")
  idx=$(( (idx + 1) % count ))
  echo "$idx" > "$state_file"
  local new_ip="${arr[$idx]}"

  local payload
  payload=$(cat <<EOF
{"type":"A","name":"${dname}","content":"${new_ip}","ttl":${ttl},"proxied":${proxied}}
EOF
)

  local res
  res=$(cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$payload")
  if echo "$res" | grep -q '"success":true'; then
    log "OK $dname -> $new_ip"
    echo "OK: $dname -> $new_ip"
  else
    log "FAIL $dname -> $new_ip | $res"
    echo "Update failed for $dname"
    echo "$res"
    return 1
  fi
}

rotate_all() {
  require_token || return
  if [[ ! -s "$DOMAINS_FILE" ]]; then
    echo "No domains configured."
    return
  fi
  while IFS='|' read -r name _rest; do
    [[ -z "$name" || "$name" =~ ^# ]] && continue
    rotate_one "$name" || true
  done < "$DOMAINS_FILE"
}

set_token() {
  load_config
  echo
  read -rp "Cloudflare API Token: " token
  CF_API_TOKEN="$token"
  read -rp "Default TTL [120]: " ttl
  DEFAULT_TTL=${ttl:-120}
  read -rp "Default Proxied true/false [true]: " prox
  DEFAULT_PROXIED=${prox:-true}
  save_config
  echo "Saved."
}

install_cron() {
  local hour_interval="${1:-1}"
  local cron_line="0 */${hour_interval} * * * root /usr/local/bin/suny --rotate-all >> /var/log/suny.log 2>&1"
  echo "$cron_line" > /etc/cron.d/suny
  chmod 644 /etc/cron.d/suny
  echo "Cron installed: every ${hour_interval} hour(s)."
  log "Cron installed: every ${hour_interval} hour(s)"
}

remove_cron() {
  rm -f /etc/cron.d/suny
  echo "Cron removed."
  log "Cron removed"
}

show_help_ids() {
  cat <<'EOF'

How to get Zone ID and Record ID:

1) Zone ID:
   Cloudflare -> domain -> Overview -> Zone ID (right side)

2) Record ID:
   curl -s -X GET "https://api.cloudflare.com/client/v4/zones/ZONE_ID/dns_records?name=cdn.example.com" \
     -H "Authorization: Bearer TOKEN" -H "Content-Type: application/json"

   Use the "id" field from the response.

Token:
  My Profile -> API Tokens -> Create Token
  Template: Edit zone DNS (select your zone)

EOF
}

menu() {
  while true; do
    echo
    echo "========== suny =========="
    echo "1) Set API Token"
    echo "2) Add Domain"
    echo "3) List Domains"
    echo "4) Delete Domain"
    echo "5) Rotate All Now"
    echo "6) Rotate One Domain"
    echo "7) Install Hourly Cron"
    echo "8) Remove Cron"
    echo "9) Help: Zone/Record ID"
    echo "0) Exit"
    echo "=========================="
    read -rp "Select: " c
    case "$c" in
      1) set_token ;;
      2) add_domain ;;
      3) list_domains ;;
      4) delete_domain ;;
      5) rotate_all ;;
      6)
        list_domains
        read -rp "Domain name: " n
        require_token && rotate_one "$n"
        ;;
      7)
        read -rp "Every how many hours? [1]: " h
        h=${h:-1}
        install_cron "$h"
        ;;
      8) remove_cron ;;
      9) show_help_ids ;;
      0) exit 0 ;;
      *) echo "Invalid" ;;
    esac
  done
}

case "${1:-}" in
  --rotate-all)
    need_root
    require_token
    rotate_all
    ;;
  --rotate)
    need_root
    require_token
    rotate_one "${2:-}"
    ;;
  --menu|"")
    need_root
    menu
    ;;
  *)
    echo "Usage: suny [--menu|--rotate-all|--rotate DOMAIN]"
    exit 1
    ;;
esac
