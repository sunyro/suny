#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo 'Run as root, or use: bash <(curl -fsSL https://raw.githubusercontent.com/sunyro/suny/main/install.sh)'
  exit 1
fi

REPO_RAW='https://raw.githubusercontent.com/sunyro/suny/main'

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl jq util-linux cron >/dev/null
  systemctl enable --now cron >/dev/null 2>&1 || true
else
  command -v curl >/dev/null || { echo 'curl is required.'; exit 1; }
  command -v jq >/dev/null || { echo 'jq is required.'; exit 1; }
  command -v flock >/dev/null || { echo 'flock (util-linux) is required.'; exit 1; }
fi

mkdir -p /opt/suny /etc/suny /var/lib/suny
curl -fsSL "$REPO_RAW/suny.sh" -o /opt/suny/suny.sh
chmod +x /opt/suny/suny.sh
ln -sf /opt/suny/suny.sh /usr/local/bin/suny

touch /etc/suny/domains.list /var/log/suny.log
[[ -f /etc/suny/config.env ]] && chmod 600 /etc/suny/config.env || true

echo
echo '[suny] Installed/updated successfully.'
echo '[suny] Run: suny'
