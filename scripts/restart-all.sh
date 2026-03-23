#!/usr/bin/env bash
set -euo pipefail


if [ "${1:-}" = "--stop" ]; then
    echo "Stopping DrDr services..."
    sudo systemctl stop drdr-main.service
    sudo systemctl stop drdr-render.service
    echo ""
    echo "Services stopped."
    systemctl status drdr-main.service --no-pager -l 2>&1 || true
    echo ""
    systemctl status drdr-render.service --no-pager -l 2>&1 || true
    exit 0
fi

echo "Restarting DrDr services..."
sudo systemctl restart drdr-main.service drdr-render.service

sleep 2

echo ""
systemctl status drdr-main.service --no-pager -l 2>&1 || true
echo ""
systemctl status drdr-render.service --no-pager -l 2>&1 || true
