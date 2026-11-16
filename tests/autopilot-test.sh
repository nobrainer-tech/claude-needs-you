#!/bin/bash
# Tests for the autopilot: hooks/needs-you.sh and bin/nb-autopilot.
# The Swift window itself: tests/window-test.sh.
# Usage: bash tests/autopilot-test.sh
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# --- Autopilot for all sessions ------------------------------------------------

setup autopilot
check ap-on "$("$AP" on 23:59)" "Autopilot ON until" 1
check ap-status-on "$("$AP" status)" "Autopilot ON until" 1

Q='{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[
  {"question":"Which path?","options":[{"label":"Path A"},{"label":"Path B (Recommended)"}]},
  {"question":"Which name?","options":[{"label":"alpha"},{"label":"beta"}]}]}}'
out=$(printf '%s' "$Q" | "$HOOK")
check ap-deny "$out" '"permissionDecision": "deny"' 1
check ap-picks-recommended "$out" "Which path? -> Path B (Recommended)" 1
check ap-else-first-option "$out" "Which name? -> alpha" 1
check ap-names-exceptions "$out" "Never decide these yourself" 1
same ap-no-entry "$(entry .msg)" ""
expect ap-no-window "WINDOW" 0

Q='{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[
  {"question":"Która ścieżka?","options":[{"label":"A"},{"label":"B (rekomendowane)"}]}]}}'
check ap-polish-marker "$(printf '%s' "$Q" | "$HOOK")" "Która ścieżka? -> B (rekomendowane)" 1

# "not recommended" inside a label is not the marker.
Q='{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[
  {"question":"Drop the old table?","options":[{"label":"Keep it"},{"label":"Drop it now (not recommended)"}]}]}}'
check ap-not-recommended-is-not-picked "$(printf '%s' "$Q" | "$HOOK")" "Drop the old table? -> Keep it" 1

W='{"hook_event_name":"PreToolUse","tool_name":"mcp__ccd_turn__wrap_up","tool_input":{"ask":"Run the slow tests too?","actions":[{"label":"Yes, run them"},{"label":"No"}]}}'
out=$(printf '%s' "$W" | "$HOOK")
check ap-end-of-turn "$out" "Run the slow tests too? -> Yes, run them" 1
check ap-exceptions-cover-merging "$out" "merging, pushing or deploying" 1

# An end-of-turn question whose first answer is an app action (merge, commit,
# open a pull request) is a go-ahead for the owner: autopilot never takes it.
W='{"hook_event_name":"PreToolUse","tool_name":"mcp__ccd_turn__wrap_up","tool_input":{"ask":"Merge the pull request?","actions":[{"action":"merge"}]}}'
out=$(printf '%s' "$W" | "$HOOK")
check ap-app-action-denied "$out" '"permissionDecision": "deny"' 1
check ap-app-action-left-for-owner "$out" "do not take that step" 1
check ap-app-action-not-taken "$out" "Act on your recommended answer now" 0

# Autopilot never answers a permission prompt or a plan: those go to the inbox.
out=$(echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{}}' | "$HOOK")
check ap-permission-not-answered "$out" "permissionDecision" 0
same ap-permission-in-inbox "$(entry .msg)" "Permission needed: Bash"
out=$(echo '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{}}' | "$HOOK")
check ap-plan-not-answered "$out" "permissionDecision" 0
same ap-plan-in-inbox "$(entry .msg)" "A plan is waiting for your approval"

report=$("$AP" report)
check ap-report-question "$report" "Which path? -> Path B (Recommended)" 1
check ap-report-end-of-turn "$report" "Run the slow tests too? -> Yes, run them" 1
check ap-report-left-for-owner "$report" "Merge the pull request? -> left for the owner (merge)" 1
check ap-report-session "$report" "my-app | checkout bug" 1

# Switching on again keeps the start of the report; off keeps the report.
since=$(jq -r .since_epoch "$HOME/.claude/needs-you/autopilot.json")
sleep 1; "$AP" on 23:58 >/dev/null
same ap-on-again-keeps-start "$(jq -r .since_epoch "$HOME/.claude/needs-you/autopilot.json")" "$since"
check ap-off "$("$AP" off)" "Autopilot OFF" 1
check ap-status-off "$("$AP" status)" "Autopilot OFF" 1
check ap-report-after-off "$("$AP" report)" "Which path?" 1
check ap-off-no-deny "$(fire "Question after autopilot")" "permissionDecision" 0
same ap-off-inbox "$(entry .msg)" "Question after autopilot"

"$AP" on 25:00 >/dev/null 2>&1
same ap-rejects-bad-time "exit=$?" "exit=2"
check ap-doctor "$("$AP" doctor)" "ok       jq" 1

# No record, no answer: when the decision log cannot be written, autopilot does
# not answer for the owner and the request goes to the inbox instead.
"$AP" on 23:59 >/dev/null
chmod 400 "$HOME/.claude/needs-you/decisions.jsonl"
before=$(wc -l < "$HOME/.claude/needs-you/decisions.jsonl")
out=$(fire "Question when the log is read-only")
chmod 600 "$HOME/.claude/needs-you/decisions.jsonl"
check ap-unlogged-no-deny "$out" "permissionDecision" 0
same ap-unlogged-inbox "$(entry .msg)" "Question when the log is read-only"
same ap-unlogged-log-unchanged "$(wc -l < "$HOME/.claude/needs-you/decisions.jsonl")" "$before"
"$AP" off >/dev/null

# A failed write is reported, not hidden behind "Autopilot OFF".
"$AP" on 23:59 >/dev/null
chmod 500 "$HOME/.claude/needs-you"
out=$("$AP" off 2>&1; echo "exit=$?")
chmod 700 "$HOME/.claude/needs-you"
check ap-off-failure-is-reported "$out" "could not write" 1
check ap-off-failure-exit-code "$out" "exit=1" 1
"$AP" off >/dev/null

# --- Autopilot for one session ------------------------------------------------

setup per-session
check ap-session-on "$("$AP" session on local_test "my-app | checkout bug")" "Autopilot ON for my-app | checkout bug" 1
check ap-session-status "$("$AP" status)" "on for my-app | checkout bug (local_test)" 1
out=$(fire "Ticked session question")
check ap-session-deny "$out" '"permissionDecision": "deny"' 1
check ap-session-reason "$out" "Autopilot is on (this session)" 1
same ap-session-no-entry "$(entry .msg)" ""
out=$(CLAUDE_CODE_HOST_SESSION_ID=local_other bash -c "$(declare -f ask); ask 'Unticked session question' | \"\$0\"" "$HOOK")
check ap-other-session-not-answered "$out" "permissionDecision" 0
same ap-other-session-inbox "$(entry .msg local_other)" "Unticked session question"
out=$(echo '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{}}' | "$HOOK")
check ap-session-plan-not-answered "$out" "permissionDecision" 0
check ap-session-report "$("$AP" report)" "Ticked session question -> your recommendation" 1
"$AP" on 23:59 >/dev/null; "$AP" off >/dev/null
check ap-global-off-keeps-session "$("$AP" status)" "on for my-app" 1
check ap-session-off "$("$AP" session off local_test)" "Autopilot OFF for local_test" 1
check ap-session-off-asks-again "$(fire "Unticked again")" "permissionDecision" 0
"$AP" session on 'bad id;rm' >/dev/null 2>&1
same ap-session-rejects-bad-id "exit=$?" "exit=2"

# An end time more than a day away is not a real setting: autopilot is off.
setup far-future
mkdir -p "$HOME/.claude/needs-you"
echo '{"until_epoch":99999999999,"since_epoch":0,"until":"never"}' > "$HOME/.claude/needs-you/autopilot.json"
check far-future-no-deny "$(fire "Question with a forged end time")" "permissionDecision" 0
check far-future-status-off "$("$AP" status)" "Autopilot OFF" 1

# A long question is cut by characters, not bytes: a letter outside ASCII at the
# cut stays whole even when the hook runs in the C locale, as it does in the app.
setup non-ascii
long=$(printf 'x%.0s' $(seq 1 179))
ask "${long}ąęść and the rest of a long question" | LC_ALL=C "$HOOK"
same non-ascii-cut-on-a-character "$(entry .msg)" "${long}ą"

# An expired autopilot is off.
setup expired
mkdir -p "$HOME/.claude/needs-you"
echo '{"until_epoch":1,"since_epoch":0,"until":"past"}' > "$HOME/.claude/needs-you/autopilot.json"
check expired-no-deny "$(fire "Question after the end time")" "permissionDecision" 0
check expired-report-empty "$("$AP" report)" "No autopilot decisions." 1

if [ "$FAIL" = 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
