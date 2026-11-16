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
  {"question":"Rename the old column?","options":[{"label":"Keep it"},{"label":"Rename it now (not recommended)"}]}]}}'
check ap-not-recommended-is-not-picked "$(printf '%s' "$Q" | "$HOOK")" "Rename the old column? -> Keep it" 1

W='{"hook_event_name":"PreToolUse","tool_name":"mcp__ccd_turn__wrap_up","tool_input":{"ask":"Run the slow tests too?","actions":[{"label":"Yes, run them"},{"label":"No"}]}}'
out=$(printf '%s' "$W" | "$HOOK")
check ap-end-of-turn "$out" "Run the slow tests too? -> Yes, run them" 1
check ap-exceptions-cover-merging "$out" "merging, pushing or deploying" 1

# A question about a step only the owner may take (merge, push, deploy, publish,
# delete, pay, log in, grant) is never answered, even when the session
# recommends it, and whether it is an app action or a plain option: it goes to
# the inbox.
W='{"hook_event_name":"PreToolUse","tool_name":"mcp__ccd_turn__wrap_up","tool_input":{"ask":"Merge the pull request?","actions":[{"action":"merge"}]}}'
out=$(printf '%s' "$W" | "$HOOK")
check ap-app-action-not-answered "$out" "permissionDecision" 0
same ap-app-action-in-inbox "$(entry .msg)" "Merge the pull request?"
Q='{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[
  {"question":"Ready to ship?","options":[{"label":"Deploy to production (Recommended)"},{"label":"Wait"}]}]}}'
check ap-owner-only-option-not-answered "$(printf '%s' "$Q" | "$HOOK")" "permissionDecision" 0
same ap-owner-only-option-in-inbox "$(entry .msg)" "Ready to ship?"
W='{"hook_event_name":"PreToolUse","tool_name":"mcp__ccd_turn__wrap_up","tool_input":{"ask":"Scalić PR?","actions":[{"label":"Tak, scal"}]}}'
check ap-owner-only-polish-not-answered "$(printf '%s' "$W" | "$HOOK")" "permissionDecision" 0
W='{"hook_event_name":"PreToolUse","tool_name":"mcp__ccd_turn__wrap_up","tool_input":{"ask":"Run the slow tests too?","actions":[{"label":"Yes"}]}}'
check ap-never-list-first "$(printf '%s' "$W" | "$HOOK" | jq -r .hookSpecificOutput.permissionDecisionReason)" "will not answer. Never decide these yourself" 1

# Autopilot grants a permission and approves a plan for the owner, unless the
# request names a step only the owner may take: that one goes to the inbox.
out=$(echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test"}}' | "$HOOK")
check ap-permission-allowed "$out" '"behavior":"allow"' 1
rm -f "$(INBOX)"
out=$(echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' | "$HOOK")
check ap-permission-delete-not-allowed "$out" "behavior" 0
same ap-permission-delete-in-inbox "$(entry .msg)" "Permission needed: Bash"
out=$(echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push origin main"}}' | "$HOOK")
check ap-permission-push-not-allowed "$out" "behavior" 0
out=$(echo '{"hook_event_name":"PermissionRequest","tool_name":"mcp__mail__send_message","tool_input":{"to":"x"}}' | "$HOOK")
check ap-permission-send-not-allowed "$out" "behavior" 0
out=$(echo '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":"Refactor the parser and add tests"}}' | "$HOOK")
check ap-plan-approved "$out" '"permissionDecision": "allow"' 1
check ap-plan-echoes-input "$out" '"plan": "Refactor the parser and add tests"' 1
rm -f "$(INBOX)"
out=$(echo '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":"Fix it, then deploy to production"}}' | "$HOOK")
check ap-plan-with-deploy-not-approved "$out" "permissionDecision" 0
same ap-plan-with-deploy-in-inbox "$(entry .msg)" "A plan is waiting for your approval"
# Without a record there is no approval either.
chmod 400 "$HOME/.claude/needs-you/decisions.jsonl"
out=$(echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}' | "$HOOK")
chmod 600 "$HOME/.claude/needs-you/decisions.jsonl"
check ap-unlogged-permission-not-allowed "$out" "behavior" 0

report=$("$AP" report)
check ap-report-question "$report" "Which path? -> Path B (Recommended)" 1
check ap-report-end-of-turn "$report" "Run the slow tests too? -> Yes, run them" 1
check ap-report-no-owner-only "$report" "Merge the pull request?" 0
check ap-report-session "$report" "my-app | checkout bug" 1
check ap-report-permission "$report" "Bash -> allowed (npm test)" 1
check ap-report-plan "$report" "plan -> approved" 1

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
out=$(echo '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":"Rename a helper"}}' | "$HOOK")
check ap-session-plan-approved "$out" '"permissionDecision": "allow"' 1
check ap-session-report "$("$AP" report)" "Ticked session question -> your recommendation" 1
"$AP" on 23:59 >/dev/null; "$AP" off >/dev/null
check ap-global-off-keeps-session "$("$AP" status)" "on for my-app" 1
check ap-session-off "$("$AP" session off local_test)" "Autopilot OFF for local_test" 1
check ap-session-off-asks-again "$(fire "Unticked again")" "permissionDecision" 0
check ap-session-off-status "$("$AP" status)" "on for my-app" 0
check ap-report-after-untick "$("$AP" report)" "Ticked session question -> your recommendation" 1
# Ticking it again opens a new period; decisions of the first one stay in the report.
"$AP" session on local_test >/dev/null
check ap-retick-on "$(fire "Ticked again question")" '"permissionDecision": "deny"' 1
check ap-report-keeps-first-period "$("$AP" report)" "Ticked session question -> your recommendation" 1
check ap-report-has-second-period "$("$AP" report)" "Ticked again question -> your recommendation" 1
# Switching an already ticked session on again keeps its open period.
"$AP" session on local_test >/dev/null
check ap-on-again-keeps-period "$("$AP" report)" "Ticked again question -> your recommendation" 1
same ap-on-again-one-open-period "$(jq '.sessions.local_test.periods | map(select(.[1] == null)) | length' "$HOME/.claude/needs-you/autopilot.json")" "1"
"$AP" session off local_test >/dev/null

# Writers that race keep both changes.
for i in 1 2 3 4 5 6; do "$AP" session on "local_r$i" >/dev/null & done; wait
same ap-parallel-writes-kept "$(jq '[.sessions | keys[] | select(startswith("local_r"))] | length' "$HOME/.claude/needs-you/autopilot.json")" "6"

# Global off takes the same lock: a session switch racing it cannot undo it.
"$AP" on 23:59 >/dev/null
for i in 1 2 3 4 5 6; do "$AP" session on "local_s$i" >/dev/null & done
"$AP" off >/dev/null; wait
check ap-off-not-undone "$("$AP" status)" "Autopilot OFF" 1

# A lock held by a live writer is never taken: the call fails and leaves it.
mkdir "$HOME/.claude/needs-you/autopilot.json.lock"
out=$("$AP" session on local_locked 2>&1; echo "exit=$?")
check ap-busy-lock-fails "$out" "exit=1" 1
if [ -d "$HOME/.claude/needs-you/autopilot.json.lock" ]; then echo "PASS ap-busy-lock-kept"; else echo "FAIL ap-busy-lock-kept"; FAIL=1; fi
rmdir "$HOME/.claude/needs-you/autopilot.json.lock"
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
