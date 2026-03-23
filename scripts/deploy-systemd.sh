#!/usr/bin/env bash
set -euo pipefail


echo "=== DrDr deploy (after git pull) ==="

# Reload unit file changes
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

# Restart services
echo "Restarting drdr-main..."
sudo systemctl restart drdr-main.service

echo "Restarting drdr-render..."
sudo systemctl restart drdr-render.service

# Status
echo ""
echo "=== Status ==="
systemctl status drdr-main.service --no-pager -l 2>&1 || true
echo ""
systemctl status drdr-render.service --no-pager -l 2>&1 || true
