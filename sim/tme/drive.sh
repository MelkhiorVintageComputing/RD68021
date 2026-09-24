#!/bin/bash
# RD68021 -- drive a TME machine's serial console.
#
#   T=<tme install> drive.sh <config> <seconds> <command>...
#
# Runs tmesh with a FIFO as the console's input. Each time the console output
# ends in a prompt -- `>`, `#` or `:` -- the next command is typed, with a
# carriage return. Once the last command's prompt has come back, or the time is
# up, or the machine stops by itself, tmesh is stopped.
cfg=$1; secs=$2; shift 2
rm -f console.in; mkfifo console.in; : > console.out
LTDL_LIBRARY_PATH=$T/lib $T/bin/tmesh $cfg < /dev/null > tmesh.log 2>&1 &
pid=$!
exec 3>console.in
start=$(date +%s); sent=0
for cmd in "$@"; do
  until tr -d '\000\r' < console.out | tail -c 3 | grep -q '[>#:] *$' && [ $(stat -c %s console.out) -gt $sent ]; do
    sleep 1; [ $(( $(date +%s)-start )) -gt $secs ] && break 2
  done
  sent=$(stat -c %s console.out)
  printf '%s\r' "$cmd" >&3
  sleep 2
done
# ... and the prompt after the last command.
until tr -d '\000\r' < console.out | tail -c 3 | grep -q '[>#:] *$' && [ $(stat -c %s console.out) -gt $sent ]; do
  sleep 1
  [ $(( $(date +%s)-start )) -gt $secs ] && break
  kill -0 $pid 2>/dev/null || break
done
kill $pid 2>/dev/null; exec 3>&-
