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
tmux split-window -v -t "$SESSION:logs" \
    "journalctl -u drdr-render -f"

# Window 2: status (refreshes every 5 seconds)
tmux new-window -t "$SESSION" -n "status" \
    "while true; do systemctl status drdr-main drdr-render --no-pager -l 2>&1 | less -R +F; sleep 5; done"

# Window 3: shell
tmux new-window -t "$SESSION" -n "shell"

# Start on the logs window
tmux select-window -t "$SESSION:logs"

exec tmux attach-session -t "$SESSION"
