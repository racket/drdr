# DrDr Systemd Configuration

This replaces the `good-init.sh` shell-script supervisor with systemd.

## Architecture

DrDr has two services:

- **drdr-main** -- The CI loop. Monitors the git repo for new commits, checks out code, builds, runs tests, and analyzes results. Exits after processing each revision; systemd restarts it automatically.
- **drdr-render** -- Web server on port 9000. Serves test results from the filesystem. Runs continuously.

Both run as user `jay`. They communicate via the shared filesystem under `/opt/plt/builds/`, not via IPC or sockets.

### What systemd provides over good-init.sh

- **cgroup-based cleanup**: When main is stopped or restarted, systemd kills all child processes (Xorg, metacity, test subprocesses) via the cgroup. No more `pgrep`/`kill` pattern matching.
- **Automatic restart**: both services restart on any exit (main exits after each revision; render should run continuously).
- **Observable status**: `systemctl status` shows PID, memory, uptime, recent log lines.
- **Structured logging**: All output goes to the journal.
- **IPC isolation**: `PrivateIPC=yes` gives each service its own SysV IPC namespace. Stale shared memory segments are cleaned up when the service stops.

## Quick Reference

### Start/stop/restart

```sh
# Individual services
sudo systemctl start drdr-main
sudo systemctl stop drdr-main
sudo systemctl restart drdr-main

# Both at once
sudo systemctl restart drdr-main drdr-render

# Using the helper script
./scripts/restart-all.sh        # restart both
./scripts/restart-all.sh --stop # stop both
```

### Check status

```sh
systemctl status drdr-main --no-pager
systemctl status drdr-render --no-pager
```

### View logs

```sh
# Follow live logs
journalctl -u drdr-main -f
journalctl -u drdr-render -f

# Last 200 lines
journalctl -u drdr-main -n 200 --no-pager
journalctl -u drdr-render -n 200 --no-pager

# Logs since last boot
journalctl -u drdr-main -b --no-pager

# Logs from a specific time range
journalctl -u drdr-main --since "2025-01-15 10:00" --until "2025-01-15 12:00"
```

### Monitor with tmux

```sh
./scripts/monitor.sh
```

This opens (or attaches to) a tmux session with:
- **Window "logs"**: split view of main and render journal logs
- **Window "status"**: auto-refreshing status of both services
- **Window "shell"**: empty shell for ad-hoc commands

Detach with `Ctrl-b d`. Reattach with `tmux attach -t drdr-monitor`.

## Deployment

### First install

```sh
cd /opt/svn/drdr
# Stop good-init.sh first (kill the shell process)
./scripts/install-systemd.sh
```

### After code changes (git pull)

```sh
cd /opt/svn/drdr
git pull
./scripts/deploy-systemd.sh
```

This reloads unit files and restarts both services. The `raco make` step in `ExecStartPre` recompiles before each start.

### Rollback to good-init.sh

```sh
./scripts/uninstall-systemd.sh
cd /opt/svn/drdr
./good-init.sh
```

## Unit File Details

### drdr-main.service

| Setting | Value | Why |
|---------|-------|-----|
| `Restart=always` | Restarts on any exit | main.rkt exits 0 after each revision |
| `RestartSec=2s` | 2 second delay | Quick restart for CI responsiveness |
| `TimeoutStopSec=300s` | 5 minute stop timeout | Tests can run for extended periods |
| `KillMode=control-group` | Kill all children | Cleans up Xorg, metacity, test processes |
| `PrivateIPC=yes` | Isolated IPC namespace | Prevents stale SysV shared memory |
| `LimitCORE=51200000` | ~50MB core dumps | Matches good-init.sh `ulimit -c 100000` |
| No `NoNewPrivileges` | Omitted | Xorg.wrap needs setuid root |
| `ExecStartPre` | `raco make *.rkt */*.rkt` | Recompile before each start |

### drdr-render.service

| Setting | Value | Why |
|---------|-------|-----|
| `Restart=always` | Restart on any exit | Matches good-init.sh; render should stay running |
| `RestartSec=5s` | 5 second delay | Slightly longer to avoid rapid restart loops |
| `TimeoutStopSec=30s` | 30 second stop timeout | Web server shuts down quickly |
| `NoNewPrivileges=yes` | Set | render never starts X, safe to restrict |

### drdr.target

Groups both services. Uses `Wants=` (not `Requires=`) so render keeps running when main restarts (which happens after every revision).

## Troubleshooting

### Service won't start

```sh
# Check what went wrong
systemctl status drdr-main --no-pager -l
journalctl -u drdr-main -n 50 --no-pager

# If ExecStartPre (raco make) fails, the service won't start.
# Try running it manually:
cd /opt/svn/drdr && /opt/plt/plt/bin/raco make *.rkt */*.rkt
```

### main keeps restarting rapidly

This is expected behavior -- main exits 0 after each revision. If there are no new revisions, it enters a polling loop (`monitor-scm`) and stays running until a new commit arrives.

If main is crashing (non-zero exit) repeatedly, check logs:
```sh
journalctl -u drdr-main -n 100 --no-pager
```

systemd has built-in rate limiting: if a service restarts more than 5 times in 10 seconds (default), it enters a failed state. Check with `systemctl status` and reset with:
```sh
sudo systemctl reset-failed drdr-main
sudo systemctl start drdr-main
```

### Xorg won't start inside main

Xorg requires setuid root via `/usr/lib/xorg/Xorg.wrap`. Verify:
```sh
ls -la /usr/lib/xorg/Xorg.wrap
# Should show: -rwsr-sr-x ... root root ...
```

If `NoNewPrivileges=yes` is accidentally added to drdr-main.service, Xorg's setuid will be blocked and it will fail to start.

### Stale processes after stop

With `KillMode=control-group`, systemd kills all processes in the cgroup. Verify:
```sh
sudo systemctl stop drdr-main
sleep 5
pgrep -u jay Xorg    # should show nothing
pgrep -u jay metacity # should show nothing
```

### Checking what unit file is loaded

```sh
systemctl cat drdr-main.service
# Shows the full unit file content and its path
```

If it doesn't point to the repo file, re-run `install-systemd.sh`.
