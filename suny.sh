#!/bin/bash
# Suny - Cloudflare tunnel backend monitor and healthy IP rotator
set -euo pipefail

CONFIG_DIR=/etc/suny
STATE_DIR=/var/lib/suny
CONFIG_FILE=$CONFIG_DIR/config.env
DOMAINS_FILE=$CONFIG_DIR/domains.list
LOG_FILE=/var/log/suny.log
LOCK_FILE=/run/suny.lock
ROTATE_CRON=/etc/cron.d/suny-rotate
MONITOR_CRON=/etc/cron.d/suny-monitor

mkdir -p "$CONFIG_DIR" "$STATE_DIR"
touch "$DOMAINS_FILE" "$LOG_FILE"

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
need_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root: sudo suny"; exit 1; }; }
load_config(){ [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"; }
save_config(){ cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN="${CF_API_TOKEN:-}"
DEFAULT_TTL="${DEFAULT_TTL:-120}"
DEFAULT_PROXIED="${DEFAULT_PROXIED:-false}"
CHECKHOST_API_KEY="${CHECKHOST_API_KEY:-}"
EOF
chmod 600 "$CONFIG_FILE"; }
require_token(){ load_config; [[ -n "${CF_API_TOKEN:-}" ]] || { echo "ابتدا API Token کلادفلر را تنظیم کن (گزینه 1)."; return 1; }; }
valid_bool(){ [[ "$1" == true || "$1" == false ]]; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
valid_percent(){ [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1>=1 && 10#$1<=100)); }

cf_api(){
  local method=$1 endpoint=$2 data=${3:-}
  local args=(-sS --connect-timeout 10 --max-time 30 -X "$method" "https://api.cloudflare.com/client/v4$endpoint" -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json')
  [[ -n "$data" ]] && args+=(--data "$data")
  curl "${args[@]}"
}

# format: name|zone|record|ips|ttl|proxied|port|health|min_success
get_line(){ awk -F'|' -v n="$1" '$1==n{print;exit}' "$DOMAINS_FILE"; }
read_domain(){
  local line
  line=$(get_line "$1") || return 1
  [[ -n "$line" ]] || return 1
  IFS='|' read -r D_NAME D_ZONE D_RECORD D_IPS D_TTL D_PROXIED D_PORT D_HEALTH D_MIN _ <<< "$line"
  D_PORT=${D_PORT:-443}; D_HEALTH=${D_HEALTH:-true}; D_MIN=${D_MIN:-60}; D_TTL=${D_TTL:-120}; D_PROXIED=${D_PROXIED:-false}
  IFS=',' read -r -a D_ARR <<< "$D_IPS"
}
state_file(){ printf '%s/%s.idx' "$STATE_DIR" "$1"; }
get_idx(){ local f; f=$(state_file "$1"); [[ -f "$f" ]] && cat "$f" || echo 0; }
set_idx(){ echo "$2" > "$(state_file "$1")"; }

list_domains(){
  echo; echo '===== Domain List ====='
  [[ -s "$DOMAINS_FILE" ]] || { echo 'دامنه‌ای ثبت نشده.'; return; }
  local i=1 name idx
  while IFS='|' read -r name _; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    read_domain "$name" || continue; idx=$(get_idx "$name")
    echo "$i) $D_NAME"
    echo "   Current: ${D_ARR[$idx]:-?}"
    echo "   IPs: $D_IPS"
    echo "   Health: $D_HEALTH | TCP: $D_PORT | Min external: $D_MIN%"
    i=$((i+1))
  done < "$DOMAINS_FILE"
  echo
}

add_domain(){
  require_token || return; load_config
  local name zone record ips ttl proxied health port min
  read -rp 'Domain/subdomain: ' name
  read -rp 'Cloudflare Zone ID: ' zone
  read -rp 'DNS Record ID: ' record
  read -rp 'IP list (comma-separated): ' ips
  read -rp "TTL [${DEFAULT_TTL:-120}]: " ttl; ttl=${ttl:-${DEFAULT_TTL:-120}}
  read -rp "Proxied true/false [${DEFAULT_PROXIED:-false}]: " proxied; proxied=${proxied:-${DEFAULT_PROXIED:-false}}
  read -rp 'Health check true/false [true]: ' health; health=${health:-true}
  read -rp 'Tunnel TCP port [443]: ' port; port=${port:-443}
  read -rp 'Minimum external success % [60]: ' min; min=${min:-60}
  [[ -n "$name" && -n "$zone" && -n "$record" && -n "$ips" ]] || { echo 'اطلاعات ناقص است.'; return 1; }
  valid_bool "$proxied" && valid_bool "$health" && valid_port "$port" && valid_percent "$min" || { echo 'مقدار واردشده نامعتبر است.'; return 1; }
  grep -Fv "${name}|" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp" || true; mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
  echo "$name|$zone|$record|$ips|$ttl|$proxied|$port|$health|$min" >> "$DOMAINS_FILE"
  set_idx "$name" 0; log "Domain added: $name"; echo 'Saved.'
}

delete_domain(){
  list_domains; local name; read -rp 'Domain to delete: ' name
  grep -Fq "${name}|" "$DOMAINS_FILE" || { echo 'پیدا نشد.'; return; }
  grep -Fv "${name}|" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp" || true; mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
  rm -f "$(state_file "$name")"; log "Domain deleted: $name"; echo 'Deleted.'
}

checkhost(){
  local url=$1; load_config
  local args=(-sS --connect-timeout 10 --max-time 30 -H 'Accept: application/json')
  [[ -n "${CHECKHOST_API_KEY:-}" ]] && args+=(-H "Authorization: Bearer $CHECKHOST_API_KEY")
  curl "${args[@]}" "$url"
}

health_check(){
  local ip=$1 port=$2 min=$3 quiet=${4:-false}
  local dispatch request result i=0 total=0 success=0
  dispatch=$(checkhost "https://check-host.net/check-tcp?host=${ip}:${port}&max_nodes=8") || return 2
  request=$(jq -r '.request_id // empty' <<< "$dispatch")
  [[ -n "$request" ]] || return 2
  result='{}'
  while ((i<15)); do
    result=$(checkhost "https://check-host.net/check-result/$request") || result='{}'
    jq -e 'type=="object" and length>0 and any(.[]; . != null and length>0)' <<< "$result" >/dev/null 2>&1 && break
    sleep 1; i=$((i+1))
  done
  while IFS=$'\t' read -r node status; do
    [[ -z "$node" ]] && continue; total=$((total+1))
    [[ "$status" == 1 ]] && success=$((success+1))
    [[ "$quiet" == false ]] && printf '  %-35s %s\n' "$node" "$( [[ "$status" == 1 ]] && echo OK || echo FAIL )"
  done < <(jq -r 'to_entries[] | [(.key),((.value[0][0] // 0)|tostring)] | @tsv' <<< "$result" 2>/dev/null || true)
  ((total>0)) || return 2
  local pct=$((success*100/total))
  [[ "$quiet" == false ]] && echo "  Reachability: $success/$total ($pct%)"
  ((pct>=min))
}

update_dns(){
  local idx=$1 ip=$2
  local payload res
  payload=$(jq -cn --arg name "$D_NAME" --arg ip "$ip" --argjson ttl "$D_TTL" --argjson proxied "$D_PROXIED" '{type:"A",name:$name,content:$ip,ttl:$ttl,proxied:$proxied}')
  res=$(cf_api PUT "/zones/$D_ZONE/dns_records/$D_RECORD" "$payload")
  if jq -e '.success==true' <<< "$res" >/dev/null 2>&1; then
    set_idx "$D_NAME" "$idx"; log "DNS switched $D_NAME -> $ip"; echo "OK: $D_NAME -> $ip"; return 0
  fi
  log "Cloudflare update failed for $D_NAME: $res"; echo "$res"; return 1
}

rotate_one(){
  read_domain "$1" || { echo 'Domain not found.'; return 1; }
  local count=${#D_ARR[@]} idx attempts=0 next ip
  count=${#D_ARR[@]}; ((count>0)) || return 1; idx=$(get_idx "$D_NAME")
  while ((attempts<count)); do
    next=$(((idx+1+attempts)%count)); ip=${D_ARR[$next]}
    if [[ "$D_HEALTH" == true ]] && ! health_check "$ip" "$D_PORT" "$D_MIN" false; then
      echo "Skip unhealthy: $ip"; attempts=$((attempts+1)); continue
    fi
    update_dns "$next" "$ip"; return $?
  done
  log "No healthy IP available for rotation: $D_NAME"; echo 'هیچ IP سالمی برای چرخش پیدا نشد.'; return 1
}

monitor_one(){
  read_domain "$1" || return 1
  [[ "$D_HEALTH" == true ]] || return 0
  local idx ip count=${#D_ARR[@]} attempts=0 next candidate
  idx=$(get_idx "$D_NAME"); ip=${D_ARR[$idx]:-}
  [[ -n "$ip" ]] || return 1
  if health_check "$ip" "$D_PORT" "$D_MIN" true; then
    log "MONITOR healthy $D_NAME -> $ip"; return 0
  fi
  log "MONITOR unhealthy $D_NAME -> $ip; starting failover"
  echo "$D_NAME: current IP $ip failed health check. Looking for healthy replacement..."
  while ((attempts<count-1)); do
    next=$(((idx+1+attempts)%count)); candidate=${D_ARR[$next]}
    if health_check "$candidate" "$D_PORT" "$D_MIN" false; then
      update_dns "$next" "$candidate"; return $?
    fi
    attempts=$((attempts+1))
  done
  log "FAILOVER no healthy replacement for $D_NAME"; echo 'هیچ IP سالم جایگزین پیدا نشد؛ DNS تغییر نکرد.'; return 1
}

with_lock(){ (
  flock -n 9 || exit 0
  "$@"
) 9>"$LOCK_FILE"; }
rotate_all_locked(){ require_token || return; while IFS='|' read -r name _; do [[ -z "$name" || "$name" == \#* ]] && continue; rotate_one "$name" || true; done < "$DOMAINS_FILE"; }
monitor_all_locked(){ require_token || return; while IFS='|' read -r name _; do [[ -z "$name" || "$name" == \#* ]] && continue; monitor_one "$name" || true; done < "$DOMAINS_FILE"; }
rotate_all(){ with_lock rotate_all_locked; }
monitor_all(){ with_lock monitor_all_locked; }

install_rotation(){
  local h; read -rp 'هر چند ساعت یک بار Rotate شود؟ [1]: ' h; h=${h:-1}
  [[ "$h" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid interval.'; return 1; }
  cat > "$ROTATE_CRON" <<EOF
0 */$h * * * root /usr/local/bin/suny --rotate-all >> /var/log/suny.log 2>&1
EOF
  chmod 644 "$ROTATE_CRON"; log "Timed rotation enabled every $h hour(s)"; echo "چرخش زمان‌بندی‌شده هر $h ساعت فعال شد."
}
remove_rotation(){ rm -f "$ROTATE_CRON"; log 'Timed rotation disabled'; echo 'چرخش زمان‌بندی‌شده حذف شد.'; }
install_monitor(){ cat > "$MONITOR_CRON" <<'EOF'
* * * * * root /usr/local/bin/suny --monitor-all >> /var/log/suny.log 2>&1
EOF
chmod 644 "$MONITOR_CRON"; log 'Minute monitor enabled'; echo 'مانیتور سلامت هر 1 دقیقه فعال شد.'; }
remove_monitor(){ rm -f "$MONITOR_CRON"; log 'Minute monitor disabled'; echo 'مانیتور دقیقه‌ای حذف شد.'; }

set_token(){
  load_config; local token ttl prox
  read -rsp 'Cloudflare API Token: ' token; echo
  CF_API_TOKEN=$token
  read -rp 'Default TTL [120]: ' ttl; DEFAULT_TTL=${ttl:-120}
  read -rp 'Default Proxied true/false [false]: ' prox; DEFAULT_PROXIED=${prox:-false}
  save_config; echo 'Saved.'
}
set_checkhost_key(){ load_config; local key; read -rsp 'Check-Host API Key (optional, Enter clears): ' key; echo; CHECKHOST_API_KEY=$key; save_config; echo 'Saved.'; }
check_domain_menu(){ list_domains; local n; read -rp 'Domain name: ' n; read_domain "$n" || { echo 'Not found.'; return; }; local ip; for ip in "${D_ARR[@]}"; do echo "Checking $ip:$D_PORT"; health_check "$ip" "$D_PORT" "$D_MIN" false && echo '  Status: HEALTHY' || echo '  Status: UNHEALTHY/UNKNOWN'; done; }
help_menu(){ cat <<'EOF'
Health Monitor: هر یک دقیقه فقط IP فعلی را بررسی می‌کند. اگر سالم باشد DNS تغییر نمی‌کند؛ اگر ناسالم باشد اولین IP سالم بعدی جایگزین می‌شود.
Timed Rotation: هر بازه‌ای که تعیین می‌کنی، بین IPهای سالم به‌صورت حلقه‌ای می‌چرخد و IP ناسالم را رد می‌کند.
Cloudflare Token: Zone/DNS/Edit و Zone/Zone/Read کافی است.
EOF
}
uninstall(){ read -rp 'حذف کامل Suny؟ [y/N]: ' a; [[ "$a" =~ ^[Yy]$ ]] || return; rm -f "$ROTATE_CRON" "$MONITOR_CRON" /usr/local/bin/suny; rm -rf /opt/suny "$CONFIG_DIR" "$STATE_DIR"; echo 'Suny removed. Log file was kept: /var/log/suny.log'; }

menu(){
  while true; do
    cat <<'EOF'
========== suny ==========
1) Set Cloudflare API Token
2) Add Domain
3) List Domains
4) Delete Domain
5) Rotate All Now
6) Rotate One Domain
7) Install Timed Healthy IP Rotation
8) Remove Timed Rotation
9) Health Check Domain
10) Set Check-Host API Key (optional)
11) Install 1-Minute Failover Monitor
12) Remove 1-Minute Monitor
13) Help
14) Uninstall suny
0) Exit
==========================
EOF
    read -rp 'Select: ' c
    case $c in
      1)set_token;;2)add_domain;;3)list_domains;;4)delete_domain;;5)rotate_all;;
      6)list_domains; read -rp 'Domain name: ' n; with_lock rotate_one "$n";;
      7)install_rotation;;8)remove_rotation;;9)check_domain_menu;;10)set_checkhost_key;;
      11)install_monitor;;12)remove_monitor;;13)help_menu;;14)uninstall; exit 0;;0)exit 0;;*)echo 'Invalid option.';;
    esac
  done
}

need_root
case "${1:-}" in
  --rotate-all) rotate_all;;
  --monitor-all) monitor_all;;
  --rotate-one) with_lock rotate_one "${2:?domain required}";;
  --help) help_menu;;
  *) menu;;
esac
