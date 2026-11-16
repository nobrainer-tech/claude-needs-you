#!/bin/bash
# Tests for bin/needs-you-scan: sessions that already wait go to the inbox.
# Each scenario writes a desktop-app session file and the end of its transcript
# in a temp home. Run: bash tests/scan-test.sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
SCAN="$ROOT/bin/needs-you-scan"

iso() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%S.000Z'; }
now=$(date +%s)
SESSIONS() { printf '%s' "$HOME/Library/Application Support/Claude/claude-code-sessions/acct/org"; }
T() { printf '%s' "$HOME/.claude/projects/-my-repo/cli-1.jsonl"; }

# The session file of local_test with a transcript cli-1, plus extra fields.
session() {
  local extra="${1:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc --arg cwd "$HOME/my-repo/src" --argjson extra "$extra" \
    '{title:"my-app | checkout bug", cwd:$cwd, cliSessionId:"cli-1", isArchived:false} + $extra' \
    > "$(SESSIONS)/local_test.json"
  mkdir -p "$(dirname "$(T)")"; : > "$(T)"
}
user() {  # seconds ago, text
  jq -nc --arg t "$(iso $((now - $1)))" --arg x "$2" '{type:"user",timestamp:$t,message:{role:"user",content:$x}}' >> "$(T)"
}
ask() {  # seconds ago, question, tool (default wrap_up), id
  jq -nc --arg t "$(iso $((now - $1)))" --arg q "$2" --arg tool "${3:-mcp__ccd_turn__wrap_up}" --arg id "${4:-tu-ask}" '
    {type:"assistant",timestamp:$t,message:{role:"assistant",content:[{type:"tool_use",id:$id,name:$tool,
      input:(if $tool == "AskUserQuestion" then {questions:[{question:$q}]} else {ask:$q,recap:"r"} end)}]}}' >> "$(T)"
}
result() {  # seconds ago, tool_use_id, is_error (default false)
  jq -nc --arg t "$(iso $((now - $1)))" --arg id "$2" --argjson err "${3:-false}" \
    '{type:"user",timestamp:$t,message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,content:"ok",is_error:$err}]}}' >> "$(T)"
}
scan() { "$SCAN" --no-open >/dev/null; }

setup open-question
session; user 600 "fix the bug"; ask 300 "Merge the fix?"
scan
same open-question-listed "$(entry .msg)" "Merge the fix?"
same open-question-waits "$(entry .done)" "false"
same keeps-asked-time "$(entry .ts)" "$((now - 300))"
same has-section "$(entry .section)" "🛒 Shop"
same has-link "$(entry .link)" "claude://claude.ai/epitaxy/local_test"

setup answered
session; ask 600 "Merge the fix?"; user 300 "yes"
scan
check answered-not-listed "$(ls "$HOME/.claude/needs-you/inbox" 2>/dev/null)" "local_test" 0

setup ask-tool
session; user 900 "go"; ask 600 "Which colour?" AskUserQuestion tu-1; result 500 tu-1
scan
check answered-tool-not-listed "$(ls "$HOME/.claude/needs-you/inbox" 2>/dev/null)" "local_test" 0
ask 300 "Which size?" AskUserQuestion tu-2
scan
same open-tool-listed "$(entry .msg)" "Which size?"
same open-tool-call-kept "$(entry .tool_use_id)" "tu-2"

setup subagent
session; user 600 "go"
jq -nc --arg t "$(iso $((now - 300)))" '{type:"assistant",isSidechain:true,timestamp:$t,message:{content:[{type:"tool_use",id:"s",name:"AskUserQuestion",input:{questions:[{question:"sub?"}]}}]}}' >> "$(T)"
scan
check subagent-not-listed "$(ls "$HOME/.claude/needs-you/inbox" 2>/dev/null)" "local_test" 0

# A question autopilot refused (the session went on without it) does not wait,
# nor does one followed by a turn that ended without a question.
setup refused
session; user 900 "go"; ask 600 "Run the tests?" mcp__ccd_turn__wrap_up tu-r; result 590 tu-r true
scan
check refused-not-listed "$(ls "$HOME/.claude/needs-you/inbox" 2>/dev/null)" "local_test" 0
ask 300 "" mcp__ccd_turn__wrap_up tu-done
scan
check refused-then-done-not-listed "$(ls "$HOME/.claude/needs-you/inbox" 2>/dev/null)" "local_test" 0

setup closed
session; user 900 "go"; ask 600 "Merge the fix?"; ask 300 "" mcp__ccd_turn__wrap_up tu-done
scan
check later-turn-without-question-closes "$(ls "$HOME/.claude/needs-you/inbox" 2>/dev/null)" "local_test" 0

# A question you cleared from the window does not come back; a newer one does.
setup cleared
session; user 900 "go"; ask 600 "Merge the fix?"
mkdir -p "$HOME/.claude/needs-you/cleared"; echo "$((now - 600))" > "$HOME/.claude/needs-you/cleared/local_test"
scan
check cleared-not-back "$(ls "$HOME/.claude/needs-you/inbox" 2>/dev/null)" "local_test" 0
user 500 "no"; ask 300 "Deploy instead?"
scan
same newer-after-clear-listed "$(entry .msg)" "Deploy instead?"

# A newer request written while the scan waited for the lock stays.
setup locked
session; user 900 "go"; ask 600 "Merge the fix?"
mkdir -p "$HOME/.claude/needs-you/inbox"; mkdir "$(INBOX).lock"
scan & sleep 0.5
jq -nc --argjson ts "$now" '{ts:$ts,session:"local_test",msg:"Newer",done:false}' > "$(INBOX)"
rmdir "$(INBOX).lock"; wait
same newer-under-lock-kept "$(entry .msg)" "Newer"

setup old
session; ask $((2 * 86400)) "Old question?"
scan
check older-than-a-day-skipped "$(ls "$HOME/.claude/needs-you/inbox" 2>/dev/null)" "local_test" 0

setup known
session; user 600 "go"; ask 300 "Merge the fix?"
mkdir -p "$HOME/.claude/needs-you/inbox"
jq -nc --argjson ts "$((now - 300))" '{ts:$ts,session:"local_test",msg:"Merge the fix?",done:true,done_ts:1}' > "$(INBOX)"
scan
same handled-stays-handled "$(entry .done)" "true"

setup archived
session '{"isArchived":true}'; user 600 "go"; ask 300 "Merge?"
scan
check archived-skipped "$(ls "$HOME/.claude/needs-you/inbox" 2>/dev/null)" "local_test" 0

setup quit
session "$(jq -nc --argjson q "$(( (now - 120) * 1000 ))" '{interruptedAwaitingPerson:true, interruptedByQuitAt:$q}')"
user 600 "go"
scan
same quit-while-waiting-listed "$(entry .msg)" "A session is waiting for you"
same quit-time-kept "$(entry .ts)" "$((now - 120))"

# On SessionStart the hook runs the scan in the background; the scan opens the
# window when it added an entry.
setup session-start
session; user 600 "go"; ask 300 "Deploy now?"
echo '{"hook_event_name":"SessionStart","session_id":"cli-9"}' | "$HOOK"; sleep 2
same session-start-scans "$(entry .msg)" "Deploy now?"
expect new-entry-opens-window "WINDOW" 1
: > "$FAKE_LOG"
"$SCAN" >/dev/null
expect nothing-new-no-window "WINDOW" 0

if [ "$FAIL" = 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
