#!/bin/bash
# usage: with-wm.sh WM [WM-ARG ...] -- COMMAND [ARG ...]
#
# Runs COMMAND under the window manager WM on the display named by
# DISPLAY, and exits with COMMAND's status. Many GUI tests assume that a
# window manager focuses newly shown frames, as on DrDr's shared display;
# plt-build.rkt runs this script under xvfb-run so that those tests also
# work on a private Xvfb display.

set -euo pipefail

wm=$1
shift
wm_args=()
while [[ $1 != "--" ]]; do
  wm_args+=("$1")
  shift
done
shift

"${wm}" "${wm_args[@]}" >/dev/null 2>&1 &
wm_pid=$!

# Give the window manager time to take over the screen before COMMAND
# shows a window.
sleep 1

status=0
"$@" || status=$?

kill "${wm_pid}" 2>/dev/null || true
exit "${status}"
