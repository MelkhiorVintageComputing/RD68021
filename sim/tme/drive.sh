#!/bin/bash
# RD68021 -- drive a TME machine's serial console.
#
#   T=<tme install> drive.sh <config> <seconds> <command>...
#
# Runs tmesh with a FIFO as the console's input. Each time the console output
# ends in a prompt -- `>`, `#` or `:` -- the next command is typed, with a
# carriage return. Once the last command's prompt has come back, or the time is
# up, or the machine stops by itself, tmesh is stopped.
#
# PROMPT, an extended regular expression matched against the end of the output,
# overrides what a prompt is.
#
# A prompt counts only if a line has ended since the last command was typed, so
# that the prompt the command was typed at is not taken for its answer.
cfg=$1; secs=$2; shift 2
PROMPT=${PROMPT:-'[>#:] *'}
# The console output since the last command, ending in a prompt, and with at
# least one line ended in it.
prompted() {
  tr -d '\000' < console.out | tail -c +$((sent+1)) > console.new
  # Bit 7 stripped: a getty set for even parity sends it, and "login:" then
  # comes out as bytes no pattern matches.
  tr -d '\r' < console.new | LC_ALL=C tr '\200-\377' '\000-\177' | tail -c 40 \
    | tr '\n' ' ' | grep -Eaq "($PROMPT)\$" &&
    { [ $sent -eq 0 ] || grep -q $'\n' console.new; }
}
rm -f console.in; mkfifo console.in; : > console.out
LTDL_LIBRARY_PATH=$T/lib $T/bin/tmesh $cfg < /dev/null > tmesh.log 2>&1 &
pid=$!
exec 3>console.in
start=$(date +%s); sent=0
for cmd in "$@"; do
  until prompted; do
    sleep 1; [ $(( $(date +%s)-start )) -gt $secs ] && break 2
  done
  sent=$(tr -d '\000' < console.out | wc -c)
  printf '%s\r' "$cmd" >&3
  sleep 2
done
# ... and the prompt after the last command.
until prompted; do
  sleep 1
  [ $(( $(date +%s)-start )) -gt $secs ] && break
  kill -0 $pid 2>/dev/null || break
done
kill $pid 2>/dev/null; exec 3>&-
