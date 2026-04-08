#!/usr/bin/env bash
set -euo pipefail


echo "=== DrDr systemd uninstall ==="

# Stop
echo "Stopping services..."
sudo systemctl stop drdr.target 2>/dev/null || true
sudo systemctl stop drdr-main.service 2>/dev/null || true
sudo systemctl stop drdr-render.service 2>/dev/null || true
sudo systemctl stop drdr-render-watch.path 2>/dev/null || true

# Disable
echo "Disabling services..."
sudo systemctl disable drdr-main.service 2>/dev/null || true
sudo systemctl disable drdr-render.service 2>/dev/null || true
sudo systemctl disable drdr-render-watch.path 2>/dev/null || true
sudo systemctl disable drdr.target 2>/dev/null || true

# Remove unit file links (only if they are symlinks)
echo "Removing unit file links..."
for unit in drdr-main.service drdr-render.service drdr.target \
            drdr-render-watch.path drdr-render-restart.service; do
    target="/etc/systemd/system/$unit"
    if [ -L "$target" ]; then
        sudo rm -f "$target"
    elif [ -e "$target" ]; then
        echo "WARNING: $target exists but is not a symlink; not removing" >&2
    fi
done

# Clear failed state
sudo systemctl reset-failed drdr-main.service 2>/dev/null || true
sudo systemctl reset-failed drdr-render.service 2>/dev/null || true

# Reload
sudo systemctl daemon-reload

echo ""
echo "=== Done ==="
echo "DrDr systemd units removed."
echo ""
echo "To restart with the old shell script:"
echo "  cd /opt/svn/drdr && ./good-init.sh"
