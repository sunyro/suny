#!/bin/bash
# suny - Cloudflare IP Rotate Manager + distributed tunnel health checks
# /opt/suny/suny.sh

set -euo pipefail

CONFIG_DIR="/etc/suny"
STATE_DIR="/var/lib/suny"
CONFIG_FILE="$CONFIG_DIR/config.env"
DOMAINS_FILE="$CONFIG_DIR/domains.list"
LOG_FILE="/var/log/suny.log"
LOCK_FILE="/var/run/suny.lock"
CHECKHOST_API="https://api.check-host.net"

mkdir -p "$CONFIG_DIR" "$STATE_DIR"
touch "$DOMAINS_FILE" "$LOG_FILE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
need_root() { [[ $EUID -eq 0 ]] || { echo "Run as root: sudo suny"; exit 1; }; }
load_config() { [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"; }
save_config() {
  cat > "$CONFIG_FILE" <<EOF2
CF_API_TOKEN="${CF_API_TOKEN:-}"
DEFAULT_TTL="${DEFAULT_TTL:-120}"
DEFAULT_PROXIED="${DEFAULT_PROXIED:-true}"
CHECKHOST_API_KEY="${CHECKHOST_API_KEY:-}"
EOF2
  chmod 600 "$CONFIG_FILE"
}
require_token() {
  load_config
  [[ -n "${CF_API_TOKEN:-}" ]] || { echo "Set Cloudflare API Token first (menu option 1)."; return 1; }
}
cf_api() {
  local method="$1" endpoint="$2" data="${3:-}"
  local args=(-sS --connect-timeout 10 --max-time 30 -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=(--data "$data")
  curl "${args[@]}"
}

# domains.list format (backward compatible):
# name|zone_id|record_id|ip1,ip2,ip3|ttl|proxied|health_port|health_enabled|min_success
# health_enabled: true/false. min_success: percentage of non-Iran/global probes required.
valid_bool() { [[ "$1" == "true" || "$1" == "false" ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)); }

list_domains() {
  echo; echo "===== Domain List ====="
  [[ -s "$DOMAINS_FILE" ]] || { echo "No domains configured."; return; }
  local i=1
  while IFS='|' read -r name zone_id record_id ips ttl proxied health_port health_enabled min_success _extra; do
    [[ -z "$name" || "$name" =~ ^# ]] && continue
    health_port="${health_port:-443}"; health_enabled="${health_enabled:-false}"; min_success="${min_success:-60}"
    local state_file="$STATE_DIR/${name}.idx" idx=0 current="?"
    [[ -f "$state_file" ]] && idx=$(cat "$state_file")
    IFS=',' read -r -a arr <<< "$ips"
    current="${arr[$idx]:-?}"
    echo "$i) $name"
    echo "   IPs: $ips"
    echo "   Current: $current | TTL: $ttl | Proxied: $proxied"
    echo "   Health: $health_enabled | TCP port: $health_port | Min external success: ${min_success}%"
    echo; i=$((i+1))
  done < "$DOMAINS_FILE"
}

add_domain() {
  require_token || return
  load_config
  echo
  read -rp "Domain/subdomain (e.g. cdn.example.com): " name
  read -rp "Cloudflare Zone ID: " zone_id
  read -rp "DNS Record ID (A record): " record_id
  read -rp "IP list comma-separated: " ips
  read -rp "TTL seconds [${DEFAULT_TTL:-120}]: " ttl; ttl=${ttl:-${DEFAULT_TTL:-120}}
  read -rp "Proxied true/false [${DEFAULT_PROXIED:-true}]: " proxied; proxied=${proxied:-${DEFAULT_PROXIED:-true}}
  read -rp "Health check enabled true/false [true]: " health_enabled; health_enabled=${health_enabled:-true}
  read -rp "Health check TCP port [443]: " health_port; health_port=${health_port:-443}
  read -rp "Minimum external success percentage [60]: " min_success; min_success=${min_success:-60}
  valid_bool "$proxied" || { echo "Invalid proxied value."; return 1; }
  valid_bool "$health_enabled" || { echo "Invalid health enabled value."; return 1; }
  valid_port "$health_port" || { echo "Invalid port."; return 1; }
  [[ "$min_success" =~ ^[0-9]+$ ]] && ((min_success>=1 && min_success<=100)) || { echo "Invalid percentage."; return 1; }
  # Fixed-string match: domain names must never be treated as regex.
  grep -Fv "${name}|" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp" || true
  mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
  echo "${name}|${zone_id}|${record_id}|${ips}|${ttl}|${proxied}|${health_port}|${health_enabled}|${min_success}" >> "$DOMAINS_FILE"
  echo 0 > "$STATE_DIR/${name}.idx"
  log "Domain added: $name"
  echo "Saved."
}

delete_domain() {
  list_domains; read -rp "Domain name to delete: " name
  if grep -Fq "${name}|" "$DOMAINS_FILE" 2>/dev/null; then
    grep -Fv "${name}|" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp" || true
    mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
    rm -f "$STATE_DIR/${name}.idx"
    log "Domain deleted: $name"; echo "Deleted."
  else echo "Not found."; fi
}

get_domain_line() { awk -F'|' -v n="$1" '$1==n {print; exit}' "$DOMAINS_FILE"; }

# ----- Check-Host legacy API: dynamic worldwide nodes, one node per selected country -----
checkhost_curl() {
  local url="$1"; shift
  local args=(-sS --connect-timeout 10 --max-time 30 -H 'Accept: application/json')
  load_config
  [[ -n "${CHECKHOST_API_KEY:-}" ]] && args+=(-H "Authorization: Bearer ${CHECKHOST_API_KEY}")
  curl "${args[@]}" "$url" "$@"
}

get_probe_nodes() {
  # country codes intentionally cover Iran + major external regions.
  local wanted=(ir tr ae de nl fr gb us ca sg jp)
  local nodes_json
  nodes_json=$(checkhost_curl "https://check-host.net/nodes/hosts") || return 1
  for cc in "${wanted[@]}"; do
    echo "$nodes_json" | jq -r --arg cc "$cc" '.nodes | to_entries[] | select(.value.location[0]|ascii_downcase == $cc) | .key' | head -n1
  done | sed '/^null$/d' | awk '!seen[$0]++'
}

check_host_tcp() {
  local ip="$1" port="$2"
  local nodes_file request_id result_json
  nodes_file=$(mktemp)
  trap 'rm -f "$nodes_file"' RETURN
  get_probe_nodes > "$nodes_file" || { echo "CHECKHOST_UNAVAILABLE"; return 2; }
  [[ -s "$nodes_file" ]] || { echo "CHECKHOST_NO_NODES"; return 2; }
  local url="https://check-host.net/check-tcp?host=${ip}:${port}&max_nodes=20"
  while IFS= read -r node; do url+="&node=$(printf '%s' "$node" | jq -sRr @uri)"; done < "$nodes_file"
  local dispatch
  dispatch=$(checkhost_curl "$url") || { echo "CHECKHOST_UNAVAILABLE"; return 2; }
  request_id=$(echo "$dispatch" | jq -r '.request_id // empty')
  [[ -n "$request_id" ]] || { echo "CHECKHOST_BAD_RESPONSE"; return 2; }

  local i=0
  while ((i<20)); do
    result_json=$(checkhost_curl "https://check-host.net/check-result/$request_id") || result_json='{}'
    if echo "$result_json" | jq -e 'type=="object" and length>0 and any(.[]; . != null and length>0)' >/dev/null 2>&1; then break; fi
    sleep 1; i=$((i+1))
  done
  [[ -n "$result_json" ]] || { echo "CHECKHOST_TIMEOUT"; return 2; }
  echo "$result_json"
}

health_check_ip() {
  local ip="$1" port="$2" min_success="$3"
  echo
  echo "Checking $ip:$port from distributed nodes..."
  local result
  result=$(check_host_tcp "$ip" "$port") || { echo "Status: UNKNOWN (Check-Host unavailable)"; return 2; }
  local total=0 success=0 iran_ok=0
  # Legacy Check-Host TCP result arrays begin with 1 on success.
  while IFS=$'\t' read -r node status; do
    [[ -z "$node" ]] && continue
    total=$((total+1))
    local country
    country=$(echo "$node" | sed -E 's/^([a-z]{2}).*/\1/' | tr '[:upper:]' '[:lower:]')
    if [[ "$status" == "1" ]]; then
      success=$((success+1)); [[ "$country" == "ir" ]] && iran_ok=1
      printf '  %-6s %-34s OK\n' "$country" "$node"
    else
      printf '  %-6s %-34s FAIL\n' "$country" "$node"
    fi
  done < <(echo "$result" | jq -r 'to_entries[] | [(.key), ((.value[0][0] // 0)|tostring)] | @tsv' 2>/dev/null || true)

  local external_total external_success
  external_total=$((total - 1)); external_success=$((success - iran_ok))
  if ((external_total < 0)); then external_total=0; fi
  if ((external_success < 0)); then external_success=0; fi
  local pct=0
  if ((external_total > 0)); then pct=$((external_success*100/external_total)); fi
  echo "  External reachability: ${external_success}/${external_total} (${pct}%)"
  if ((iran_ok==0)); then
    echo "  Status: OFFLINE / UNREACHABLE"
    return 3
  elif ((external_success==0)); then
    echo "  Status: LIKELY FILTERED (Iran OK, external probes 0%)"
    return 4
  elif ((pct < min_success)); then
    echo "  Status: DEGRADED (${pct}% external, threshold ${min_success}%)"
    return 5
  else
    echo "  Status: HEALTHY (${pct}% external)"
    return 0
  fi
}

check_one_domain() {
  local name="$1" line
  line=$(get_domain_line "$name")
  [[ -n "$line" ]] || { echo "Domain not found: $name"; return 1; }
  IFS='|' read -r dname zone_id record_id ips ttl proxied health_port health_enabled min_success _extra <<< "$line"
  health_port="${health_port:-443}"; min_success="${min_success:-60}"
  IFS=',' read -r -a arr <<< "$ips"
  echo; echo "===== Health Check: $name ====="
  local ip rc
  for ip in "${arr[@]}"; do
    health_check_ip "$ip" "$health_port" "$min_success" || rc=$?
    rc=${rc:-0}; unset rc
  done
}

rotate_one() {
  local name="$1" line
  line=$(get_domain_line "$name")
  [[ -n "$line" ]] || { echo "Domain not found: $name"; return 1; }
  IFS='|' read -r dname zone_id record_id ips ttl proxied health_port health_enabled min_success _extra <<< "$line"
  health_port="${health_port:-443}"; health_enabled="${health_enabled:-false}"; min_success="${min_success:-60}"
  IFS=',' read -r -a arr <<< "$ips"; local count=${#arr[@]}
  ((count>0)) || { echo "No IPs for $name"; return 1; }
  local state_file="$STATE_DIR/${name}.idx" idx=0
  [[ -f "$state_file" ]] && idx=$(cat "$state_file")
  local attempts=0 new_idx new_ip rc
  while ((attempts<count)); do
    new_idx=$(( (idx + 1 + attempts) % count )); new_ip="${arr[$new_idx]}"
    if [[ "$health_enabled" == "true" ]]; then
      set +e; health_check_ip "$new_ip" "$health_port" "$min_success"; rc=$?; set -e
      # 0 healthy. UNKNOWN (2) is not a reason to silently move DNS; skip unsafe candidates.
      if ((rc!=0)); then
        echo "Skipping $new_ip because health check did not pass."
        attempts=$((attempts+1)); continue
      fi
    fi
    local payload
    payload=$(jq -cn --arg name "$dname" --arg ip "$new_ip" --argjson ttl "${ttl:-120}" --argjson proxied "${proxied:-true}" '{type:"A",name:$name,content:$ip,ttl:$ttl,proxied:$proxied}')
    local res
    res=$(cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$payload")
    if echo "$res" | jq -e '.success == true' >/dev/null 2>&1; then
      echo "$new_idx" > "$state_file"
      log "OK $dname -> $new_ip"
      echo "OK: $dname -> $new_ip"
      return 0
    else
      log "FAIL $dname -> $new_ip | $res"; echo "Update failed for $dname"; echo "$res"; return 1
    fi
  done
  echo "No healthy candidate available for $name; DNS was NOT changed."
  return 1
}

rotate_all() {
  require_token || return
  [[ -s "$DOMAINS_FILE" ]] || { echo "No domains configured."; return; }
  (
    flock -n 9 || { echo "Another suny rotate is already running."; exit 2; }
    while IFS='|' read -r name _rest; do
      [[ -z "$name" || "$name" =~ ^# ]] && continue
      rotate_one "$name" || true
    done < "$DOMAINS_FILE"
  ) 9>"$LOCK_FILE"
}

set_token() {
  load_config; echo
  read -rsp "Cloudflare API Token: " token; echo
  CF_API_TOKEN="$token"
  read -rp "Default TTL [120]: " ttl; DEFAULT_TTL=${ttl:-120}
  read -rp "Default Proxied true/false [true]: " prox; DEFAULT_PROXIED=${prox:-true}
  save_config; echo "Saved."
  echo "Recommended Cloudflare token: Zone -> DNS -> Edit + Zone -> Zone -> Read, scoped only to required zones."
}

set_checkhost_key() {
  load_config; echo
  read -rsp "Check-Host API key (optional, Enter to clear): " key; echo
  CHECKHOST_API_KEY="$key"; save_config
  echo "Saved. Anonymous Check-Host API works with conservative rate limits; a key raises limits."
}

install_cron() {
  local hour_interval="${1:-1}"
  [[ "$hour_interval" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid interval."; return 1; }
  echo "0 */${hour_interval} * * * root /usr/local/bin/suny --rotate-all >> /var/log/suny.log 2>&1" > /etc/cron.d/suny
  chmod 644 /etc/cron.d/suny
  echo "Cron installed: every ${hour_interval} hour(s)."; log "Cron installed: every ${hour_interval} hour(s)"
}
remove_cron() { rm -f /etc/cron.d/suny; echo "Cron removed."; log "Cron removed"; }

uninstall_suny() {
  need_root
  echo; echo "WARNING: This removes suny, its config, state, logs and cron."; echo "It does NOT delete your Cloudflare DNS records or servers."
  read -rp "Type UNINSTALL to continue: " confirm
  [[ "$confirm" == "UNINSTALL" ]] || { echo "Cancelled."; return; }
  rm -f /etc/cron.d/suny /usr/local/bin/suny
  rm -rf /opt/suny "$CONFIG_DIR" "$STATE_DIR"
  rm -f "$LOG_FILE" "$LOCK_FILE"
  echo "suny uninstalled."
  exit 0
}

show_help_ids() {
  cat <<'EOF2'

Cloudflare:
  Zone ID: Cloudflare -> domain -> Overview -> Zone ID
  Record ID:
    curl -sS -X GET "https://api.cloudflare.com/client/v4/zones/ZONE_ID/dns_records?name=cdn.example.com" \
      -H "Authorization: Bearer TOKEN" -H "Content-Type: application/json"
    Use the "id" field.

Recommended API Token permissions:
  Zone -> DNS -> Edit
  Zone -> Zone -> Read
  Scope the token to only the zone(s) used by suny.

Health check:
  suny uses Check-Host distributed nodes and TCP checks against the actual tunnel port.
  It checks Iran plus external locations. "LIKELY FILTERED" means Iran is reachable while
  all selected external probes failed; it is a heuristic, not proof of censorship.

EOF2
}

menu() {
  while true; do
    echo; echo "========== suny =========="
    echo "1) Set Cloudflare API Token"
    echo "2) Add Domain"
    echo "3) List Domains"
    echo "4) Delete Domain"
    echo "5) Rotate All Now"
    echo "6) Rotate One Domain"
    echo "7) Install Hourly Cron"
    echo "8) Remove Cron"
    echo "9) Health Check Domain"
    echo "10) Set Check-Host API Key (optional)"
    echo "11) Help: Cloudflare / Health Check"
    echo "12) Uninstall suny"
    echo "0) Exit"
    echo "=========================="
    read -rp "Select: " c
    case "$c" in
      1) set_token ;;
      2) add_domain ;;
      3) list_domains ;;
      4) delete_domain ;;
      5) rotate_all ;;
      6) list_domains; read -rp "Domain name: " n; require_token && rotate_one "$n" ;;
      7) read -rp "Every how many hours? [1]: " h; install_cron "${h:-1}" ;;
      8) remove_cron ;;
      9) list_domains; read -rp "Domain name: " n; check_one_domain "$n" ;;
      10) set_checkhost_key ;;
      11) show_help_ids ;;
      12) uninstall_suny ;;
      0) exit 0 ;;
      *) echo "Invalid" ;;
    esac
  done
}

case "${1:-}" in
  --rotate-all) need_root; require_token; rotate_all ;;
  --rotate) need_root; require_token; rotate_one "${2:-}" ;;
  --health) need_root; check_one_domain "${2:-}" ;;
  --uninstall) uninstall_suny ;;
  --menu|"") need_root; menu ;;
  *) echo "Usage: suny [--menu|--rotate-all|--rotate DOMAIN|--health DOMAIN|--uninstall]"; exit 1 ;;
esac
