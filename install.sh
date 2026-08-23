#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: curl -fsSL ... | sudo bash"
  exit 1
fi

REPO_RAW="https://raw.githubusercontent.com/sunyro/suny/main"

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl jq util-linux >/dev/null
else
  command -v curl >/dev/null || { echo "curl is required."; exit 1; }
  command -v jq >/dev/null || { echo "jq is required. Install jq and run installer again."; exit 1; }
fi

mkdir -p /opt/suny /etc/suny /var/lib/suny

echo "[suny] Downloading..."
curl -fsSL "$REPO_RAW/suny.sh" -o /opt/suny/suny.sh
chmod +x /opt/suny/suny.sh
ln -sf /opt/suny/suny.sh /usr/local/bin/suny

# Do not overwrite existing config/domain data.
touch /etc/suny/domains.list /var/log/suny.log
chmod 600 /etc/suny/config.env 2>/dev/null || true

echo "[suny] Installed successfully."
echo "Run: sudo suny"
