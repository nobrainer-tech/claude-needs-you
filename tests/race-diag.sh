#!/bin/bash
# Temporary diagnostic: six writers race on autopilot.json; on a lost write,
# print the traces.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AP="$ROOT/bin/nb-autopilot"
W=$(mktemp -d)
for i in $(seq 1 30); do
  export HOME="$W/h$i"; mkdir -p "$HOME"
  "$AP" session on local_x >/dev/null
  for j in 1 2 3 4 5 6; do
    PS4='+ $$ $(date +%s.%N) ' bash -x "$AP" session on "local_r$j" > /dev/null 2> "$W/t$i.$j" &
  done
  wait
  n=$(jq '[.sessions|keys[]|select(startswith("local_r"))]|length' "$HOME/.claude/needs-you/autopilot.json")
  if [ "$n" != 6 ]; then
    echo "iteration $i: $n of 6"; jq -c . "$HOME/.claude/needs-you/autopilot.json"
    for j in 1 2 3 4 5 6; do echo "--- writer $j"; grep -E 'mkdir|rmdir|ny_stale|mv |cat |return|cur=' "$W/t$i.$j" | head -40; done
    exit 1
  fi
done
echo "no lost write in 30 rounds"
