#!/usr/bin/env bash
set -euo pipefail

SESSION="drdr-monitor"

# Attach to existing session if it exists
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Attaching to existing tmux session '$SESSION'..."
    exec tmux attach-session -t "$SESSION"
fi

echo "Creating tmux session '$SESSION'..."

# Window 0: shell + help
tmux new-session -d -s "$SESSION" -n "shell"
tmux set-option -t "$SESSION" status-left-length 20
tmux split-window -v -t "$SESSION:shell" \
    "cat <<'HELP'
DrDr Monitor
============
Window 0 (shell):   shell (top) + this help (bottom)
Window 1 (logs):    main log (top) + render log (bottom)
Window 2 (status):  main status (top) + render status (bottom)

Commands
--------
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

Tmux: Ctrl-b n/p = next/prev window, Ctrl-b up/down = switch pane
      Ctrl-b d = detach, reattach: tmux attach -t drdr-monitor
HELP
sleep infinity"
tmux resize-pane -t "$SESSION:shell.1" -y 22

# Window 1: logs (split horizontally)
tmux new-window -t "$SESSION" -n "logs" \
    "journalctl -u drdr-main -f"
tmux split-window -v -t "$SESSION:logs" \
    "journalctl -u drdr-render -f"

# Window 2: status (auto-refreshing, compact)
tmux new-window -t "$SESSION" -n "status" \
    "watch -n 5 'systemctl status drdr-main --no-pager -n0 2>&1'"
tmux split-window -v -t "$SESSION:status" \
    "watch -n 5 'systemctl status drdr-render --no-pager -n0 2>&1'"

# Start on the shell window
tmux select-window -t "$SESSION:shell"

exec tmux attach-session -t "$SESSION"
