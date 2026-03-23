#!/usr/bin/env bash
set -euo pipefail

SESSION="drdr-monitor"

# Attach to existing session if it exists
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Attaching to existing tmux session '$SESSION'..."
    exec tmux attach-session -t "$SESSION"
fi

echo "Creating tmux session '$SESSION'..."

# Window 1: logs (split horizontally)
tmux new-session -d -s "$SESSION" -n "logs" \
    "journalctl -u drdr-main -f"
tmux set-option -t "$SESSION" status-left-length 20
tmux split-window -v -t "$SESSION:logs" \
    "journalctl -u drdr-render -f"

# Window 2: status (scrollable, re-run with up-arrow + enter to refresh)
tmux new-window -t "$SESSION" -n "status" \
    "systemctl status drdr-main -l"
tmux split-window -v -t "$SESSION:status" \
    "systemctl status drdr-render -l"

# Window 3: help + shell
tmux new-window -t "$SESSION" -n "shell" \
    "cat <<'HELP'
DrDr Operations
===============
Restart both:    sudo systemctl restart drdr-main drdr-render
Restart main:    sudo systemctl restart drdr-main
Restart render:  sudo systemctl restart drdr-render
Stop both:       sudo systemctl stop drdr-main drdr-render
Start both:      sudo systemctl start drdr-main drdr-render

Status:          systemctl status drdr-main drdr-render -l
Main logs:       journalctl -u drdr-main -n 200 --no-pager
Render logs:     journalctl -u drdr-render -n 200 --no-pager

Deploy update:   cd /opt/svn/drdr && git pull && scripts/deploy-systemd.sh
Uninstall:       cd /opt/svn/drdr && scripts/uninstall-systemd.sh
Rollback:        scripts/uninstall-systemd.sh && ./good-init.sh

Check NAT rule:  sudo iptables -t nat -L PREROUTING -n
Test web:        curl -s http://localhost:9000/ | head
Test port 80:    curl -s http://localhost/ | head

Tmux: Ctrl-b n = next window, Ctrl-b p = prev, Ctrl-b d = detach
HELP
exec bash"
tmux resize-pane -t "$SESSION:shell.0" -y 18
tmux split-window -v -t "$SESSION:shell"

# Start on the logs window
tmux select-window -t "$SESSION:logs"

exec tmux attach-session -t "$SESSION"
