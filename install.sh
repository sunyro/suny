#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: curl -fsSL ... | sudo bash"
  exit 1
fi

REPO_RAW="https://raw.githubusercontent.com/sunyro/suny/main"

mkdir -p /opt/suny /etc/suny /var/lib/suny

echo "[suny] Downloading..."
curl -fsSL "$REPO_RAW/suny.sh" -o /opt/suny/suny.sh
chmod +x /opt/suny/suny.sh
ln -sf /opt/suny/suny.sh /usr/local/bin/suny

echo "[suny] Installed successfully."
echo "Run: sudo suny"
