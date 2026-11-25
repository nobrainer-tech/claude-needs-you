#!/bin/bash
# Tests for the Swift window (app/*.swift) through its launcher.
# Builds it, renders a demo inbox to a PNG and checks that a second copy exits
# while the first one holds the lock. Needs the Swift compiler (Xcode Command
# Line Tools); skips with a note when it is missing.
# Usage: bash tests/window-test.sh [OUT.png]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d /tmp/needs-you-window.XXXXXX)
first=""
trap '[ -n "$first" ] && kill "$first" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK"
FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=1; }

if [ "$(uname -s)" != Darwin ]; then
  echo "SKIP the Swift window is for macOS; Linux and Windows use the page (tests/platform-test.sh)"; exit 0
fi
if ! "$ROOT/bin/needs-you-window" --check; then
  echo "SKIP the Swift compiler is missing (xcode-select --install)"; exit 0
fi
bin=$("$ROOT/bin/needs-you-window" --build)
if [ -x "$bin" ]; then pass build; else fail build; exit 1; fi

I="$HOME/.claude/needs-you/inbox"; mkdir -p "$I"
now=$(date +%s)
entry() {  # id, minutes ago, section, project, title, message, handled
  jq -nc --argjson ts $((now - $2 * 60)) --arg id "$1" --arg s "$3" --arg p "$4" --arg t "$5" \
    --arg m "$6" --argjson d "$7" --argjson dt $((now - $2 * 30)) \
    '{ts:$ts,session:$id,title:$t,section:$s,project:$p,msg:$m,link:("claude://claude.ai/epitaxy/"+$id),done:$d,done_ts:$dt}' \
    > "$I/$1.json"
}
entry local_a 1 "🛒 Shop" checkout-api "🟡 checkout-api | 💳 Flaky payment test" "Keep the retry, or add a nullable column and backfill it?" false
entry local_b 4 "📣 Marketing" landing-page "🟡 landing-page | ✍️ Pricing copy" "A plan is waiting for your approval" false
entry local_c 9 "🧩 Platform" infra "🟠 infra | 🔐 Rotate staging keys" "Permission needed: Bash" false
entry local_d 25 "📓 Docs" docs-site "✅ docs-site | 🔎 Search page" "Regenerate the search index too?" true
entry local_old 1500 "" old "old" "older than a day" false
# A terminal session: no link, a command that returns to it.
jq -nc --argjson ts $((now - 6 * 60)) '{ts:$ts,session:"5f1c2d3e-cli",title:"api | night refactor",section:"",
  project:"api",msg:"Split the parser into two files?",link:"",
  resume:"cd \"/Users/ana/code/api\" && claude --resume 5f1c2d3e-cli",done:false}' > "$I/5f1c2d3e-cli.json"
jq -nc --argjson u $((now + 6 * 3600)) '{until_epoch:$u,since_epoch:0,until:"08:00",sessions:{local_b:{title:"",periods:[[0,null]]},local_quiet:{title:"🟢 api | 🤖 Night refactor",periods:[[0,null]]}}}' \
  > "$HOME/.claude/needs-you/autopilot.json"

out="${1:-$WORK/window.png}"
if "$ROOT/bin/needs-you-window" --snapshot "$out" && [ "$(wc -c < "$out")" -gt 20000 ]; then
  pass snapshot
else
  fail snapshot
fi
if [ -f "$I/local_old.json" ]; then fail older-than-a-day-removed; else pass older-than-a-day-removed; fi

# One window per user: while the first copy runs, a second one exits at once.
"$bin" --inbox "$I" --assets "$ROOT/app" </dev/null >/dev/null 2>&1 &
first=$!
sleep 2
if kill -0 "$first" 2>/dev/null; then
  start=$(date +%s)
  "$bin" --inbox "$I" --assets "$ROOT/app" </dev/null >/dev/null 2>&1
  if [ $(( $(date +%s) - start )) -le 2 ]; then pass second-copy-exits; else fail second-copy-exits; fi
else
  echo "SKIP single-instance: no window server for the first copy"
fi

if [ "$FAIL" = 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
