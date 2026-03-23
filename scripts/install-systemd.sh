#!/usr/bin/env bash
set -euo pipefail

REPO="${DRDR_REPO:-/opt/svn/drdr}"
MODE="${1:-install}"

if [ "$MODE" = "--help" ] || [ "$MODE" = "-h" ]; then
    echo "Usage: $0 [--validate]"
    echo ""
    echo "  (no args)    Install and start DrDr systemd services"
    echo "  --validate   Check all prerequisites without making changes"
    exit 0
fi

# --- Validation ---

validate() {
    local errors=0
    local warnings=0

    echo "=== DrDr systemd validation ==="
    echo "Repo: $REPO"
    echo ""

    # Unit files exist
    for unit in drdr-main.service drdr-render.service drdr.target; do
        if [ -f "$REPO/systemd/$unit" ]; then
            echo "OK   $REPO/systemd/$unit exists"
        else
            echo "FAIL $REPO/systemd/$unit not found"
            errors=$((errors + 1))
        fi
    done

    # Racket binary
    if [ -x /opt/plt/plt/bin/racket ]; then
        echo "OK   /opt/plt/plt/bin/racket is executable"
    else
        echo "FAIL /opt/plt/plt/bin/racket not found or not executable"
        errors=$((errors + 1))
    fi

    # raco binary
    if [ -x /opt/plt/plt/bin/raco ]; then
        echo "OK   /opt/plt/plt/bin/raco is executable"
    else
        echo "FAIL /opt/plt/plt/bin/raco not found or not executable"
        errors=$((errors + 1))
    fi

    # Working directory
    if [ -d "$REPO" ]; then
        echo "OK   $REPO exists"
    else
        echo "FAIL $REPO does not exist"
        errors=$((errors + 1))
    fi

    # Source files to compile
    if ls "$REPO"/*.rkt >/dev/null 2>&1; then
        echo "OK   $REPO/*.rkt files present"
    else
        echo "FAIL no .rkt files in $REPO/"
        errors=$((errors + 1))
    fi

    # User jay exists (services run as jay via User= directive)
    if id jay >/dev/null 2>&1; then
        echo "OK   user jay exists ($(id jay))"
    else
        echo "FAIL user jay does not exist (needed by unit files)"
        errors=$((errors + 1))
    fi

    # Write paths exist and are writable
    for dir in /opt/plt/builds /opt/plt/logs /opt/plt/future-builds /opt/plt/repo; do
        if [ -d "$dir" ]; then
            if [ -w "$dir" ]; then
                echo "OK   $dir exists and is writable"
            else
                echo "WARN $dir exists but is not writable"
                warnings=$((warnings + 1))
            fi
        else
            echo "WARN $dir does not exist"
            warnings=$((warnings + 1))
        fi
    done

    # Xorg setuid
    if [ -f /usr/lib/xorg/Xorg.wrap ]; then
        if [ -u /usr/lib/xorg/Xorg.wrap ]; then
            echo "OK   /usr/lib/xorg/Xorg.wrap has setuid bit"
        else
            echo "WARN /usr/lib/xorg/Xorg.wrap exists but no setuid bit"
            warnings=$((warnings + 1))
        fi
    elif [ -f /usr/bin/Xorg ]; then
        echo "OK   /usr/bin/Xorg exists (wrapper)"
    else
        echo "WARN Xorg not found (main service needs it for GUI tests)"
        warnings=$((warnings + 1))
    fi

    # metacity
    if command -v metacity >/dev/null 2>&1; then
        echo "OK   metacity is available"
    else
        echo "WARN metacity not found (main service needs it for GUI tests)"
        warnings=$((warnings + 1))
    fi

    # systemd
    if command -v systemctl >/dev/null 2>&1; then
        echo "OK   systemctl is available"
    else
        echo "FAIL systemctl not found"
        errors=$((errors + 1))
    fi

    local sysver
    sysver=$(systemd --version 2>/dev/null | head -1 || echo "unknown")
    echo "INFO systemd version: $sysver"

    # sudo access
    if groups | grep -qw sudo; then
        echo "OK   $(id -un) is in the sudo group"
    else
        echo "WARN $(id -un) is not in the sudo group (needed for systemctl)"
        warnings=$((warnings + 1))
    fi

    # systemd-analyze verify
    echo ""
    echo "Running systemd-analyze verify (unrelated warnings are normal)..."
    for unit in drdr-main.service drdr-render.service drdr.target; do
        if [ -f "$REPO/systemd/$unit" ]; then
            echo "--- $unit ---"
            if ! systemd-analyze verify "$REPO/systemd/$unit" 2>&1; then
                echo "FAIL systemd-analyze verify failed for $unit"
                errors=$((errors + 1))
            fi
        fi
    done

    # Existing services
    echo ""
    echo "Existing DrDr service state:"
    for svc in drdr-main.service drdr-render.service drdr.target; do
        local state
        state=$(systemctl is-active "$svc" 2>/dev/null) || true
        echo "  $svc: ${state:-not-found}"
    done

    # Check if good-init.sh is still running
    echo ""
    if pgrep -f 'good-init.sh' >/dev/null 2>&1; then
        echo "WARN good-init.sh is currently running. Stop it before installing."
        warnings=$((warnings + 1))
        pgrep -af 'good-init.sh' 2>/dev/null | sed 's/^/      /'
    else
        echo "OK   good-init.sh is not running"
    fi

    # Port 9000
    if ss -tlnp 2>/dev/null | grep -q ':9000 '; then
        echo "INFO port 9000 is currently in use (expected if render is running)"
    else
        echo "INFO port 9000 is available"
    fi

    echo ""
    local total=$((errors + warnings))
    if [ "$total" -gt 0 ]; then
        echo "=== VALIDATION FAILED ($errors error(s), $warnings warning(s)) ==="
        return 1
    else
        echo "=== VALIDATION PASSED ==="
        return 0
    fi
}

if [ "$MODE" = "--validate" ]; then
    validate
    exit $?
fi

if [ "$MODE" != "install" ] && [ "$MODE" != "" ]; then
    echo "Unknown option: $MODE" >&2
    echo "Usage: $0 [--validate]" >&2
    exit 1
fi

# --- Install ---

echo "=== DrDr systemd install ==="
echo "Repo: $REPO"

# Run validation first
if ! validate; then
    echo ""
    echo "Fix the issues above before installing." >&2
    exit 1
fi

echo ""

# Stop existing services (idempotent)
echo "Stopping existing DrDr services (if any)..."
sudo systemctl stop drdr.target 2>/dev/null || true
sudo systemctl stop drdr-main.service 2>/dev/null || true
sudo systemctl stop drdr-render.service 2>/dev/null || true

# Disable old services
sudo systemctl disable drdr-main.service 2>/dev/null || true
sudo systemctl disable drdr-render.service 2>/dev/null || true
sudo systemctl disable drdr.target 2>/dev/null || true

# Remove old unit file links (only if they are symlinks)
for unit in drdr-main.service drdr-render.service drdr.target; do
    target="/etc/systemd/system/$unit"
    if [ -L "$target" ]; then
        sudo rm -f "$target"
    elif [ -e "$target" ]; then
        echo "WARNING: $target exists but is not a symlink; not removing" >&2
    fi
done

# Link unit files from repo
echo ""
echo "Linking unit files from $REPO/systemd/..."
sudo systemctl link "$REPO/systemd/drdr-main.service"
sudo systemctl link "$REPO/systemd/drdr-render.service"
sudo systemctl link "$REPO/systemd/drdr.target"

# Reload
sudo systemctl daemon-reload

# Enable
echo ""
echo "Enabling services..."
sudo systemctl enable drdr-main.service
sudo systemctl enable drdr-render.service

# Start
echo ""
echo "Starting services..."
sudo systemctl start drdr-main.service
sudo systemctl start drdr-render.service

# Status
echo ""
echo "=== Status ==="
systemctl status drdr-main.service --no-pager -l 2>&1 || true
echo ""
systemctl status drdr-render.service --no-pager -l 2>&1 || true

echo ""
echo "=== Done ==="
echo ""
echo "Monitor logs:"
echo "  journalctl -u drdr-main -f"
echo "  journalctl -u drdr-render -f"
echo ""
echo "Or use the tmux monitor:"
echo "  $REPO/scripts/monitor.sh"
