([Past chat][1])([Past chat][1])([Past chat][1])([Past chat][1])

# DrDr Systemd Migration Plan (Ubuntu systemd 249)

This document consolidates the full plan for replacing the current shell-script launcher with systemd for **DrDr**, including reliability hardening, logging, repository-managed configuration, and X/metacity strategies.

It reflects the constraints observed on your host:

* `systemd 249 (249.11-0ubuntu3.16)` on Ubuntu
* `systemd-analyze` does **not** support `--offline`
* `%E` path expansion in `StandardOutput=append:...` did **not** work on your build (treated as unsupported in this context)
* DrDr entry points are:

  * `/opt/svn/drdr/main.rkt`
  * `/opt/svn/drdr/render.rkt`

The plan below uses **literal paths** for reliability.

---

## Goals

1. Replace shell-loop supervision with systemd supervision.
2. Eliminate PID files and ad-hoc `pgrep`/`kill` cleanup.
3. Make restart behavior deterministic and observable.
4. Keep configuration under version control in the DrDr repository.
5. Address X/metacity process management and shared-memory cleanup robustly.
6. Provide options for:

   * per-run X/metacity (inside DrDr)
   * persistent systemd-managed X/metacity (recommended for most operations)

---

## High-level recommendation

Use systemd to supervise:

* `drdr-main.service`
* `drdr-render.service`
* optional `drdr.target` (group control)
* optional `drdr-clean.service` (legacy IPC cleanup)
* optional persistent X stacks (`drdr-xvfb@.service`, `drdr-metacity@.service`, `drdr-x@.target`) if moving X/metacity out of DrDr

And in all DrDr and X units, use:

* `KillMode=control-group`
* `TimeoutStopSec=...`
* `PrivateIPC=yes`
* `PrivateTmp=yes`

This removes most of the cleanup fragility from the old shell script.

---

# 1. Why migrate from the shell script

## Problems with the shell script approach

Typical issues in shell-based service supervisors:

* orphaned child processes on crash or partial failures
* race conditions around startup readiness
* stale IPC/shared memory (especially around X)
* broad `pgrep`/`pkill` matching that can kill unrelated processes
* ad-hoc restart loops without structured status/logging
* PID files that go stale or point to reused PIDs
* no cgroup-based lifecycle management

## What systemd gives you

* process-tree tracking via cgroups
* controlled shutdown and restart behavior
* startup ordering (`After=`, `Requires=`)
* centralized logging (`journalctl`) and optional file logging
* automatic restart policies
* sandboxing and isolation knobs (`PrivateIPC`, `ProtectSystem`, etc.)
* clear status and failure reasons (`systemctl status`)

---

# 2. Host-specific constraints discovered during setup

## systemd version

Your host reports:

```text
systemd 249 (249.11-0ubuntu3.16)
```

This is sufficient for the planned units.

## `systemd-analyze --offline` not available

On your system:

* `systemd-analyze: unrecognized option '--offline'`

So use:

```sh
sudo systemd-analyze verify /path/to/unit.service
```

instead of `--offline`.

## `%E` expansion not working in `StandardOutput=append:...`

You tested `%E` expansion and got:

* `Path %E:LOGS/out.log is not absolute`

and then the same issue again with `%E{LOGS}`.

Conclusion for this host/build:

* treat `%E` expansion in this context as unavailable/unreliable
* use **literal paths** in unit files

This is why the plan below avoids `%E` entirely.

---

# 3. Final architecture options

You have two valid ways to handle X/metacity per job run.

## Option A: DrDr starts X + metacity internally for each run

This is your current pattern.

### Pros

* fresh X/WM per run
* stronger per-run isolation
* minimal cross-run state contamination

### Cons

* higher overhead (startup cost per run)
* more race conditions (readiness checks)
* more cleanup complexity if DrDr crashes mid-run
* harder to observe X/WM behavior separately from DrDr logs

### Best when

* you need near-pristine graphical state every single run
* test correctness depends on a fresh WM/X instance
* throughput is lower than isolation requirements

---

## Option B: systemd-managed persistent Xvfb + metacity (recommended default)

Move Xvfb/metacity to systemd and let DrDr connect to fixed displays.

### Pros

* lower per-run overhead
* fewer startup races
* systemd-supervised restarts for X/WM
* better logging and observability
* easier to inspect failures (`systemctl status`, separate logs)

### Cons

* possible cross-run state leakage inside persistent WM/X if tests mutate state
* requires explicit hygiene (restart X stack periodically or between batches if needed)

### Best when

* throughput and operational reliability matter more than pristine per-run GUI state
* jobs are frequent
* you want simpler operations and debugging

---

## Recommendation

Use **Option B** for normal operation. Add periodic or batch-boundary restarts of X stacks if GUI state carryover causes issues. Keep Option A available for selected jobs that truly require pristine per-run X.

---

# 4. Core DrDr systemd services (literal paths, Ubuntu 249 compatible)

This is the base setup if you migrate DrDr itself to systemd, regardless of X strategy.

## 4.1 Create service user and directories

```sh
sudo useradd --system --home /nonexistent --shell /usr/sbin/nologin drdr || true

sudo install -d -m 0750 -o drdr -g drdr /var/log/drdr
sudo install -d -m 0750 -o drdr -g drdr /var/lib/drdr

sudo install -d -m 0755 /etc/drdr
```

Notes:

* `/var/log/drdr` is for file logs if using `StandardOutput=append:...`
* `/var/lib/drdr` is for any persistent state your services need
* systemd `StateDirectory=drdr` also creates `/var/lib/drdr`; keeping the explicit directory creation is fine and simplifies first-time setup

---

## 4.2 Optional environment file (application vars only)

Use this for app behavior knobs, not for path interpolation in unit directives.

`/etc/drdr/drdr.env`

```ini
DRDR_ENV=prod
PARALLELISM=4
```

Install it:

```sh
sudo tee /etc/drdr/drdr.env >/dev/null <<'ENV'
DRDR_ENV=prod
PARALLELISM=4
ENV
sudo chmod 0644 /etc/drdr/drdr.env
```

---

## 4.3 `drdr-main.service`

`/etc/systemd/system/drdr-main.service`

```ini
[Unit]
Description=DrDr main CI service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=drdr
Group=drdr
EnvironmentFile=/etc/drdr/drdr.env
WorkingDirectory=/opt/svn/drdr

# systemd-managed writable state area
StateDirectory=drdr
StateDirectoryMode=0750

# file logging + journal (append works on systemd 249 in general; tested separately)
StandardOutput=append:/var/log/drdr/main.log
StandardError=append:/var/log/drdr/main.log

ExecStart=/opt/plt/plt/bin/racket /opt/svn/drdr/main.rkt

Restart=on-failure
RestartSec=2s

# Critical for cleanup reliability
KillMode=control-group
TimeoutStopSec=30s
SendSIGKILL=yes

# Isolation/sandboxing
NoNewPrivileges=yes
PrivateTmp=yes
PrivateIPC=yes

ProtectSystem=strict
ProtectHome=read-only

# Allow writes where needed
ReadWritePaths=/var/log/drdr /var/lib/drdr

[Install]
WantedBy=multi-user.target
```

### Why these settings matter

* `KillMode=control-group`: kills all child processes started by the unit, not just the main PID
* `PrivateIPC=yes`: isolates SysV IPC (shared memory/semaphores/message queues), which helps prevent stale X-related shared memory from persisting after service stops
* `ProtectSystem=strict`: hardens filesystem access; allow explicit writes only via `ReadWritePaths`

---

## 4.4 `drdr-render.service`

`/etc/systemd/system/drdr-render.service`

```ini
[Unit]
Description=DrDr render worker
After=drdr-main.service
PartOf=drdr.target

[Service]
Type=simple
User=drdr
Group=drdr
EnvironmentFile=/etc/drdr/drdr.env
WorkingDirectory=/opt/svn/drdr

StateDirectory=drdr
StateDirectoryMode=0750

StandardOutput=append:/var/log/drdr/render.log
StandardError=append:/var/log/drdr/render.log

ExecStart=/opt/plt/plt/bin/racket /opt/svn/drdr/render.rkt

Restart=on-failure
RestartSec=2s

KillMode=control-group
TimeoutStopSec=30s
SendSIGKILL=yes

NoNewPrivileges=yes
PrivateTmp=yes
PrivateIPC=yes

ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/log/drdr /var/lib/drdr

[Install]
WantedBy=multi-user.target
```

---

## 4.5 Optional `drdr.target` (group control)

This gives a single handle to start/stop the full DrDr stack.

`/etc/systemd/system/drdr.target`

```ini
[Unit]
Description=DrDr stack
Requires=drdr-main.service drdr-render.service
```

If you later add X units, this target is also the right place to group them.

---

## 4.6 Optional one-time legacy IPC cleanup (`drdr-clean.service`)

This is mainly for cleanup of **old leftovers** from the shell-script era.

`/etc/systemd/system/drdr-clean.service`

```ini
[Unit]
Description=DrDr one-time IPC cleanup
DefaultDependencies=no
Before=drdr.target drdr-main.service drdr-render.service

[Service]
Type=oneshot
User=drdr
Group=drdr
ExecStart=/bin/sh -c 'ipcs -m | awk "$3==\"drdr\"{print $2}" | xargs -r -n1 ipcrm -m'
ExecStart=/bin/sh -c 'ipcs -s | awk "$3==\"drdr\"{print $2}" | xargs -r -n1 ipcrm -s'
ExecStart=/bin/sh -c 'ipcs -q | awk "$3==\"drdr\"{print $2}" | xargs -r -n1 ipcrm -q'
```

### When to use this

* during initial migration from the old launcher
* if you suspect old SysV IPC segments are still hanging around
* not usually needed once `PrivateIPC=yes` is in place and systemd owns DrDr and X

---

# 5. Startup, enablement, and verification

## 5.1 Verify unit syntax (Ubuntu 249 style)

```sh
sudo systemd-analyze verify /etc/systemd/system/drdr-main.service
sudo systemd-analyze verify /etc/systemd/system/drdr-render.service
sudo systemd-analyze verify /etc/systemd/system/drdr.target
sudo systemd-analyze verify /etc/systemd/system/drdr-clean.service
```

Notes:

* This may emit warnings about unrelated vendor units (for example `snapd.service` on your system). Those warnings are noisy but not fatal to DrDr.

---

## 5.2 Reload and enable

```sh
sudo systemctl daemon-reload

# Enable individual services
sudo systemctl enable drdr-main.service
sudo systemctl enable drdr-render.service

# Optional group control
sudo systemctl enable drdr.target
```

---

## 5.3 First start

```sh
# optional legacy IPC cleanup
sudo systemctl start drdr-clean.service || true

# start services
sudo systemctl start drdr-main.service
sudo systemctl start drdr-render.service

# or start as a group if using the target
# sudo systemctl start drdr.target
```

---

## 5.4 Status and logs

```sh
systemctl status drdr-main --no-pager
systemctl status drdr-render --no-pager

sudo tail -n 200 /var/log/drdr/main.log
sudo tail -n 200 /var/log/drdr/render.log

sudo journalctl -u drdr-main -e --no-pager
sudo journalctl -u drdr-render -e --no-pager
```

---

# 6. Logging options

## Option 1 (current recommendation): file + journal

Use:

```ini
StandardOutput=append:/var/log/drdr/main.log
StandardError=append:/var/log/drdr/main.log
```

Pros:

* easy tailing from file
* also visible in journal
* compatible with your systemd 249 build when using literal paths

Cons:

* requires log rotation
* duplicates logs (file + journal)

### Logrotate config

`/etc/logrotate.d/drdr`

```conf
/var/log/drdr/*.log {
  weekly
  rotate 8
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
```

---

## Option 2: journal-only logging

Remove `StandardOutput=` and `StandardError=`.

Pros:

* simplest config
* no file rotation
* structured systemd-native logs

Cons:

* less convenient if you have existing scripts expecting flat log files

Read logs with:

```sh
sudo journalctl -u drdr-main -e --no-pager
sudo journalctl -u drdr-render -e --no-pager
```

---

# 7. Repository-managed systemd configuration (recommended)

You want the configuration committed to the DrDr repository. This is a good practice.

## 7.1 Repo layout

Example layout inside `/opt/svn/drdr`:

```text
/opt/svn/drdr/
  systemd/
    drdr-main.service
    drdr-render.service
    drdr.target
    drdr-clean.service
    drdr-x@.target                # if using systemd-managed X
    drdr-xvfb@.service            # if using systemd-managed X
    drdr-metacity@.service        # if using systemd-managed X
  etc/
    drdr/
      drdr.env                    # non-secret defaults only
  scripts/
    install-systemd.sh
    uninstall-systemd.sh
```

### Secrets policy

Do not commit secrets to `drdr.env`. Commit only safe defaults. Use one of:

* `/etc/drdr/drdr.local.env` (untracked on host)
* `systemctl edit drdr-main` drop-ins with `Environment=...`
* credentials mechanisms if needed later

---

## 7.2 Deployment strategy options

### Option A: `systemctl link` to repo files (recommended)

Systemd loads the unit directly from the repo path via link registration.

Pros:

* repo files are authoritative
* no duplicated copies in `/etc/systemd/system`
* updates are `git pull` + `daemon-reload`

Cons:

* requires repo path to exist and remain stable
* slightly less familiar to admins used to `/etc/systemd/system/*.service`

### Option B: install/copy unit files into `/etc/systemd/system`

Pros:

* standard admin model
* system still works if repo path changes or is unavailable briefly

Cons:

* config duplication
* easy for `/etc` copy to drift from repo version

### Recommendation

Use **Option A (`systemctl link`)** for DrDr since the repo is the source of truth.

---

## 7.3 Example installer script (repo-managed)

`scripts/install-systemd.sh`

```sh
#!/usr/bin/env bash
set -euo pipefail

REPO=/opt/svn/drdr

# 1) user and dirs
id -u drdr >/dev/null 2>&1 || sudo useradd --system --home /nonexistent --shell /usr/sbin/nologin drdr
sudo install -d -m 0750 -o drdr -g drdr /var/log/drdr /var/lib/drdr
sudo install -d -m 0755 /etc/drdr

# 2) environment file symlink (non-secret defaults from repo)
if [ ! -e /etc/drdr/drdr.env ]; then
  sudo ln -s "$REPO/etc/drdr/drdr.env" /etc/drdr/drdr.env
fi

# 3) link unit files from repo
sudo systemctl link "$REPO/systemd/drdr-main.service"
sudo systemctl link "$REPO/systemd/drdr-render.service"
sudo systemctl link "$REPO/systemd/drdr.target"
sudo systemctl link "$REPO/systemd/drdr-clean.service"

# Optional X units (if using systemd-managed X)
if [ -f "$REPO/systemd/drdr-x@.target" ]; then
  sudo systemctl link "$REPO/systemd/drdr-x@.target"
  sudo systemctl link "$REPO/systemd/drdr-xvfb@.service"
  sudo systemctl link "$REPO/systemd/drdr-metacity@.service"
fi

# 4) verify (warnings from unrelated units may appear)
sudo systemd-analyze verify "$REPO/systemd/drdr-main.service" || true
sudo systemd-analyze verify "$REPO/systemd/drdr-render.service" || true
[ -f "$REPO/systemd/drdr.target" ] && sudo systemd-analyze verify "$REPO/systemd/drdr.target" || true
[ -f "$REPO/systemd/drdr-clean.service" ] && sudo systemd-analyze verify "$REPO/systemd/drdr-clean.service" || true

# 5) reload and enable
sudo systemctl daemon-reload
sudo systemctl enable drdr-main.service drdr-render.service
sudo systemctl enable drdr.target || true

# 6) one-time cleanup and start
sudo systemctl start drdr-clean.service || true
sudo systemctl start drdr-main.service
sudo systemctl start drdr-render.service
```

---

## 7.4 Example uninstaller script

`scripts/uninstall-systemd.sh`

```sh
#!/usr/bin/env bash
set -euo pipefail

REPO=/opt/svn/drdr

sudo systemctl stop drdr.target drdr-main drdr-render 2>/dev/null || true
sudo systemctl disable drdr.target drdr-main drdr-render 2>/dev/null || true
sudo systemctl reset-failed drdr-main drdr-render 2>/dev/null || true

sudo systemctl unlink "$REPO/systemd/drdr-main.service" 2>/dev/null || true
sudo systemctl unlink "$REPO/systemd/drdr-render.service" 2>/dev/null || true
sudo systemctl unlink "$REPO/systemd/drdr.target" 2>/dev/null || true
sudo systemctl unlink "$REPO/systemd/drdr-clean.service" 2>/dev/null || true

sudo systemctl unlink "$REPO/systemd/drdr-x@.target" 2>/dev/null || true
sudo systemctl unlink "$REPO/systemd/drdr-xvfb@.service" 2>/dev/null || true
sudo systemctl unlink "$REPO/systemd/drdr-metacity@.service" 2>/dev/null || true
```

---

## 7.5 Operational workflow with repo-managed units

### Initial install

```sh
cd /opt/svn/drdr
git pull
./scripts/install-systemd.sh
```

### After unit changes

```sh
cd /opt/svn/drdr
git pull
sudo systemctl daemon-reload
sudo systemctl restart drdr-main drdr-render
```

### Inspect current unit source

```sh
systemctl cat drdr-main.service
```

---

# 8. X/metacity strategies in detail

This section covers both approaches and how to make each maximally reliable.

---

## 8.1 Option A: DrDr launches X + metacity per run (internal)

### Reliability goals

If DrDr starts X/metacity internally, maximize reliability by ensuring:

* dynamic display allocation (avoid collisions)
* explicit readiness checks
* per-run Xauthority/cookie
* process-group cleanup on normal exit and signals
* systemd cgroup cleanup as a backstop

### Key practices

#### 1) Use dynamic display allocation with `-displayfd`

Avoid hardcoding `:1`, `:99`, etc. when spawning Xvfb per run.

#### 2) Use a per-run `XAUTHORITY`

Avoid shared state and stale auth entries.

#### 3) Disable TCP (`-nolisten tcp`)

Reduces attack surface and weird remote connection behavior.

#### 4) Wait for X readiness

Do not assume X is ready immediately after spawning it. Probe with `xset q` or similar.

#### 5) Let systemd kill the whole cgroup

If DrDr is systemd-managed with `KillMode=control-group`, orphan cleanup becomes much more reliable.

### Example per-run wrapper (inside DrDr job pipeline)

```sh
#!/usr/bin/env bash
set -euo pipefail

run_dir="$(mktemp -d -t drdr-x-XXXXXX)"
trap 'kill 0 || true; rm -rf "$run_dir"' EXIT INT TERM

cookie="$(mcookie)"
xauthf="$run_dir/.Xauthority"

# Launch Xvfb and have it choose a free display number
exec 3<> "$run_dir/displayfd"
Xvfb -displayfd 3 -screen 0 1920x1080x24 -nolisten tcp -noreset -shmem -auth "$xauthf" &
read -r disp <"$run_dir/displayfd"

export DISPLAY=":$disp"
xauth -f "$xauthf" add "$DISPLAY" MIT-MAGIC-COOKIE-1 "$cookie"
export XAUTHORITY="$xauthf"

# Launch WM
metacity --sm-disable --composite=off &
wm_pid=$!

# Wait for X to be ready
for _ in {1..50}; do
  if xset q >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

# Run payload
exec "$@"
```

### Additional notes for Option A

* If DrDr can run multiple jobs concurrently, make sure each run gets its own temporary directory and display.
* `trap 'kill 0'` is useful but imperfect. Systemd cgroup cleanup is the real safety net.
* If X or metacity hangs, the job wrapper should have timeouts or be run under a higher-level timeout.

---

## 8.2 Option B: systemd-managed persistent Xvfb + metacity (recommended)

This moves X/WM out of DrDr and into systemd units, one stack per worker/display.

### Reliability goals

* one X stack per worker, fixed display
* separate supervision of Xvfb and metacity
* automatic restarts
* isolated IPC and tmp
* deterministic `DISPLAY`/`XAUTHORITY` for DrDr
* clean cgroup teardown

### Design

Use templated units indexed by display number (`%i`), e.g.:

* `drdr-x@91.target`
* `drdr-xvfb@91.service`
* `drdr-metacity@91.service`

And bind:

* `drdr-main.service` → display `:91`
* `drdr-render.service` → display `:92` (or the same, depending on behavior)

### Pros vs internal-per-run

* fewer race conditions
* easier to inspect and restart X separately
* lower latency per job
* clearer failure boundaries

### Cons vs internal-per-run

* long-lived GUI state unless periodically reset

---

## 8.3 Systemd units for persistent X stacks

### `drdr-x@.target`

`systemd/drdr-x@.target`

```ini
[Unit]
Description=DrDr X stack for display :%i
Requires=drdr-xvfb@%i.service drdr-metacity@%i.service
After=drdr-xvfb@%i.service
```

---

### `drdr-xvfb@.service`

`systemd/drdr-xvfb@.service`

```ini
[Unit]
Description=Xvfb for DrDr on :%i

[Service]
Type=simple
User=drdr
Group=drdr

# runtime area for this display's Xauthority/cookie
RuntimeDirectory=drdr-x/%i
RuntimeDirectoryMode=0750

# prepare cookie and xauth file
ExecStartPre=/bin/sh -c 'mkdir -p /run/drdr-x/%i; mcookie > /run/drdr-x/%i/cookie; :> /run/drdr-x/%i/xauth'

# launch Xvfb (fixed display)
ExecStart=/usr/bin/Xvfb :%i -screen 0 1920x1080x24 -nolisten tcp -noreset -shmem -auth /run/drdr-x/%i/xauth

# install auth cookie
ExecStartPost=/bin/sh -c 'xauth -f /run/drdr-x/%i/xauth add :%i MIT-MAGIC-COOKIE-1 "$(cat /run/drdr-x/%i/cookie)"'

Restart=always
RestartSec=2s

KillMode=control-group
TimeoutStopSec=15s
SendSIGKILL=yes

NoNewPrivileges=yes
PrivateIPC=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
```

---

### `drdr-metacity@.service`

`systemd/drdr-metacity@.service`

```ini
[Unit]
Description=Metacity for DrDr on :%i
After=drdr-xvfb@%i.service
PartOf=drdr-x@%i.target

[Service]
Type=simple
User=drdr
Group=drdr

Environment=DISPLAY=:%i
Environment=XAUTHORITY=/run/drdr-x/%i/xauth

ExecStart=/usr/bin/metacity --sm-disable --composite=off --no-force-fullscreen

Restart=always
RestartSec=2s

KillMode=control-group
TimeoutStopSec=10s
SendSIGKILL=yes

NoNewPrivileges=yes
PrivateIPC=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
```

---

## 8.4 Binding DrDr services to persistent X stacks

If `drdr-main` should use display `:91` and `drdr-render` should use `:92`, add the following.

### `drdr-main.service` additions

In `[Unit]`:

```ini
Requires=drdr-x@91.target
After=network-online.target drdr-x@91.target
```

In `[Service]`:

```ini
Environment=DISPLAY=:91
Environment=XAUTHORITY=/run/drdr-x/91/xauth
```

### `drdr-render.service` additions

In `[Unit]`:

```ini
Requires=drdr-x@92.target
After=drdr-main.service drdr-x@92.target
```

In `[Service]`:

```ini
Environment=DISPLAY=:92
Environment=XAUTHORITY=/run/drdr-x/92/xauth
```

### Enable/start commands

```sh
sudo systemctl daemon-reload

sudo systemctl enable drdr-x@91.target drdr-x@92.target
sudo systemctl start drdr-x@91.target drdr-x@92.target

sudo systemctl enable drdr-main.service drdr-render.service
sudo systemctl start drdr-main.service drdr-render.service
```

---

## 8.5 Reliability hygiene for persistent X (Option B)

### Nightly or periodic restart

If GUI state accumulates or tests leak state:

```sh
sudo systemctl restart drdr-x@91.target
sudo systemctl restart drdr-x@92.target
```

Automate with a timer if desired.

### Batch-boundary restart

If DrDr has natural batch boundaries, restart the X stack between batches instead of every job.

### Separate displays per worker

Do not share a single display between unrelated high-activity workers unless you know it is safe.

---

# 9. Process cleanup and shared memory: is it a problem?

You asked whether not explicitly killing remaining processes or clearing X shared memory is a problem.

## Short answer

It **can** be a problem in the shell-script model. It is **much less of a problem** with correct systemd unit settings.

## Why systemd solves most of it

With:

```ini
KillMode=control-group
PrivateIPC=yes
PrivateTmp=yes
```

systemd handles:

* child process cleanup (all children in the cgroup)
* isolation of SysV IPC objects used by the service
* reduction of stale IPC leaking into future runs

## Remaining caveat

If X/metacity is started *outside* the DrDr unit or in a way systemd does not track in the same cgroup, cleanup may still be incomplete. This is why either:

* keep X/metacity inside the DrDr service cgroup, or
* manage X/metacity as their own systemd units

Both are reliable when systemd owns them.

---

# 10. Troubleshooting and known noisy messages on your host

## 10.1 `snapd.service` warning during `systemd-analyze verify`

You saw:

```text
/lib/systemd/system/snapd.service:23: Unknown key name 'RestartMode' in section 'Service', ignoring.
```

This is a vendor-unit warning and not directly related to DrDr. It is noisy but usually harmless for your DrDr unit verification.

If needed, verify only your units and ignore unrelated warnings, or patch the vendor unit with an override. For DrDr migration, no action is required.

---

## 10.2 `netplan-ovs-cleanup.service` under `/run/systemd/system`

You saw permission-denied and then details for:

* `netplan-ovs-cleanup.service`

This is a runtime-generated unit and not a DrDr issue. It was inactive because its condition checks were not met. No action needed.

---

## 10.3 `%E` expansion tests failed

You confirmed `%E` failed in your environment. Do not use `%E` in production units here. Stick to literal paths.

---

## 10.4 If `append:` logging fails

If `StandardOutput=append:/var/log/...` fails on some future host/build:

* remove `StandardOutput` / `StandardError`
* use journal-only logging
* read logs with `journalctl -u ...`

---

# 11. Complete recommended configurations (choose one)

This section summarizes the two strongest configurations.

---

## Configuration 1: Most isolated runs (DrDr launches X/metacity internally)

### Use when

* pristine per-run GUI state is required

### Components

* `drdr-main.service`
* `drdr-render.service`
* optional `drdr.target`
* optional `drdr-clean.service`
* DrDr internal wrapper for Xvfb/metacity per run

### Required systemd settings

In DrDr units:

* `KillMode=control-group`
* `PrivateIPC=yes`
* `PrivateTmp=yes`

### Reliability checklist

* dynamic display allocation (`-displayfd`)
* per-run `XAUTHORITY`
* readiness probe before payload
* traps + process-group cleanup
* outer systemd supervision for backstop cleanup

---

## Configuration 2: Most operationally reliable and efficient (recommended)

### Use when

* throughput and operability are primary
* occasional X state reset is acceptable

### Components

* `drdr-main.service`
* `drdr-render.service`
* `drdr.target`
* optional `drdr-clean.service` (for migration period)
* `drdr-x@.target`
* `drdr-xvfb@.service`
* `drdr-metacity@.service`

### Required systemd settings

For all DrDr and X units:

* `KillMode=control-group`
* `PrivateIPC=yes`
* `PrivateTmp=yes`
* `Restart=always` or `Restart=on-failure` as appropriate

### Reliability checklist

* fixed display per worker
* separate X stack per worker
* explicit `DISPLAY` and `XAUTHORITY`
* periodic X stack restart if GUI state carryover matters
* logs split by service (main, render, xvfb, metacity if desired)

---

# 12. Suggested rollout plan

## Phase 1: Replace shell supervisor, keep current internal X behavior

1. Create `drdr-main.service` and `drdr-render.service`
2. Add `KillMode=control-group`, `PrivateIPC=yes`
3. Start/stop DrDr only via systemd
4. Confirm no lingering processes and reduced IPC leaks

This gets most of the reliability gains with minimal application changes.

## Phase 2: Move units into repo and deploy via `systemctl link`

1. Commit `systemd/*.service`, `systemd/*.target`
2. Add `scripts/install-systemd.sh`
3. Deploy from repo on host
4. Confirm operational workflow (`git pull`, `daemon-reload`, restart)

## Phase 3: Optional migration of X/metacity to systemd-managed persistent stacks

1. Add `drdr-xvfb@.service`, `drdr-metacity@.service`, `drdr-x@.target`
2. Bind `drdr-main` and `drdr-render` to displays
3. Remove internal X/metacity spawning for selected workers
4. Add periodic X stack restarts if needed

---

# 13. Operational commands reference

## Basic lifecycle

```sh
sudo systemctl daemon-reload
sudo systemctl enable drdr-main drdr-render
sudo systemctl start drdr-main drdr-render
sudo systemctl restart drdr-main drdr-render
sudo systemctl stop drdr-main drdr-render
```

## If using target

```sh
sudo systemctl enable drdr.target
sudo systemctl start drdr.target
sudo systemctl stop drdr.target
```

## Status and logs

```sh
systemctl status drdr-main --no-pager
systemctl status drdr-render --no-pager

sudo journalctl -u drdr-main -e --no-pager
sudo journalctl -u drdr-render -e --no-pager

sudo tail -n 200 /var/log/drdr/main.log
sudo tail -n 200 /var/log/drdr/render.log
```

## X stack control (if systemd-managed)

```sh
sudo systemctl status drdr-x@91.target --no-pager
sudo systemctl status drdr-xvfb@91.service --no-pager
sudo systemctl status drdr-metacity@91.service --no-pager

sudo systemctl restart drdr-x@91.target
sudo systemctl restart drdr-x@92.target
```

## IPC cleanup (migration only)

```sh
sudo systemctl start drdr-clean.service
```

---

# 14. Summary of key decisions for your host

* **Spell the project name**: **DrDr**
* **Use systemd 249-compatible commands** (`systemd-analyze verify`, no `--offline`)
* **Do not use `%E` expansion** in unit file paths on this host
* **Use literal paths**

  * `/opt/svn/drdr/main.rkt`
  * `/opt/svn/drdr/render.rkt`
  * `/opt/plt/plt/bin/racket`
  * `/var/log/drdr/...`
* **Use `KillMode=control-group` + `PrivateIPC=yes`** for cleanup reliability
* **Commit unit files to the repo** and deploy with `systemctl link`
* **Prefer systemd-managed persistent Xvfb/metacity** for operational reliability, unless per-run pristine GUI state is mandatory

---

If you want, the next step can be a single repo-ready `systemd/` directory with finalized unit files for the exact option you choose (internal X vs systemd-managed X), plus install/uninstall scripts and a small admin README.

[1]: https://chatgpt.com/c/68c792fd-fae0-832e-8cb0-97b4e7a11138 "Script improvement analysis"
