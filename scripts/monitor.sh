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

# Window 2: status (scrollable, re-run with up-arrow + enter to refresh)
tmux new-window -t "$SESSION" -n "status" \
    "systemctl status drdr-main -l"
tmux split-window -v -t "$SESSION:status" \
    "systemctl status drdr-render -l"

# Window 3: shell
tmux new-window -t "$SESSION" -n "shell"

# Start on the logs window
tmux select-window -t "$SESSION:logs"

exec tmux attach-session -t "$SESSION"
