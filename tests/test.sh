#!/bin/bash
# Tests for the inbox side of hooks/needs-you.sh.
# The Swift window itself: tests/window-test.sh.
# Usage: bash tests/test.sh
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# --- The inbox ---------------------------------------------------------------

setup inbox
fire "Question A"; sleep 1
same entry-message "$(entry .msg)" "Question A"
same entry-title "$(entry .title)" "my-app | checkout bug"
same entry-section "$(entry .section)" "🛒 Shop"
same entry-project-is-repo "$(entry .project)" "my-repo"
same entry-link "$(entry .link)" "claude://claude.ai/epitaxy/local_test"
same entry-waiting "$(entry .done)" "false"
expect window-opened "WINDOW" 1
expect no-banner-with-window "BANNER" 0
expect no-dialog-with-window "DIALOG" 0

# A newer request of the same session replaces its entry.
fire "Question B"; sleep 1
same newer-replaces "$(entry .msg)" "Question B"
same one-entry-per-session "$(find "$HOME/.claude/needs-you/inbox" -name '*.json' | wc -l | tr -d ' ')" "1"

# The same request twice within 2 minutes counts once.
: > "$FAKE_LOG"
fire "Question B"; sleep 1
expect dedupe "WINDOW" 0

# The session moved on: its entry is handled, not removed.
event PostToolUse mcp__ccd_turn__wrap_up
same wrap-up-does-not-handle "$(entry .done)" "false"
event PostToolUse Bash sub-1
same subagent-does-not-handle "$(entry .done)" "false"
event PostToolUse AskUserQuestion
same tool-call-handles "$(entry .done)" "true"
check handled-has-time "$(entry .done_ts)" "null" 0
fire "Question C"; sleep 1
same new-request-waits-again "$(entry .done)" "false"
event UserPromptSubmit
same prompt-handles "$(entry .done)" "true"

# A handled request that comes again within 2 minutes is a new request: the
# same permission prompt after you approved the last one still reaches you.
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' | "$HOOK"
event PostToolUse Bash
: > "$FAKE_LOG"
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' | "$HOOK"; sleep 1
same repeat-after-handled-waits "$(entry .done)" "false"
expect repeat-after-handled-shown "WINDOW" 1

# A newer request is not marked handled by a tool call that read the older one:
# the hook only marks the request that is still in the file.
echo '{"ts":1,"session":"local_test","msg":"old","done":false}' > "$(INBOX)"
event PostToolUse Bash
same handles-current "$(entry .done)" "true"

# Another session's tool call leaves this entry alone.
fire "Question D"; sleep 1
CLAUDE_CODE_HOST_SESSION_ID=local_other event PostToolUse Bash
same other-session-leaves-it "$(entry .done)" "false"

# --- Without the window ------------------------------------------------------

setup banner
export FAKE_NO_WINDOW=1 FAKE_BANNER_EXIT=0
fire "Question E"; sleep 1
expect banner-sent "BANNER" 1
expect banner-links-session "-open claude://claude.ai/epitaxy/local_test" 1
expect banner-no-window "WINDOW" 0
same banner-still-inbox "$(entry .msg)" "Question E"

setup dialog
export FAKE_NO_WINDOW=1 FAKE_ANSWER=Open
fire "Question F"; sleep 1
expect dialog-shown "DIALOG [Claude needs you: my-app | checkout bug] Question F (labels: 2)" 1
expect dialog-open-link "OPEN claude://claude.ai/epitaxy/local_test" 1

setup window-off
export NEEDS_YOU_WINDOW=0
fire "Question G"; sleep 1
expect window-switched-off "WINDOW" 0
expect window-off-dialog "DIALOG" 1
unset NEEDS_YOU_WINDOW

# A terminal session: titled by its folder, no link.
setup terminal
unset CLAUDE_CODE_HOST_SESSION_ID
export FAKE_NO_WINDOW=1
fire "Question I"; sleep 1
expect terminal-title "DIALOG [Claude needs you: my-repo] Question I (labels: 0)" 1
expect terminal-no-open "OPEN" 0
same terminal-entry "$(entry .link cli-1)" ""

# --- Other events ------------------------------------------------------------

setup events
echo '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{}}' | "$HOOK"
same plan "$(entry .msg)" "A plan is waiting for your approval"
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' | "$HOOK"
same permission "$(entry .msg)" "Permission needed: Bash"
NEEDS_YOU_PERMISSION="Prośba o zgodę" bash -c 'echo "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Edit\"}" | "$0"' "$HOOK"
same permission-text-from-env "$(entry .msg)" "Prośba o zgodę: Edit"
rm -f "$(INBOX)"
echo '{"hook_event_name":"PermissionDenied","tool_name":"Bash","agent_id":"sub-1"}' | "$HOOK"
same subagent-denial-silent "$(entry .msg)" ""
out=$(echo '{"hook_event_name":"PreToolUse","tool_name":"mcp__ccd_turn__wrap_up","tool_input":{"recap":"done"}}' | "$HOOK")
same wrap-up-without-question-silent "$out$(entry .msg)" ""
out=$(echo 'not json' | "$HOOK"; echo "exit=$?")
check garbage-input-is-harmless "$out" "exit=0" 1

# --- Away from the Mac -------------------------------------------------------

setup idle
export NEEDS_YOU_IDLE_CMD='printf "%s|%s|%s\n" "$1" "$NEEDS_YOU_SESSION_ID" "$NEEDS_YOU_MESSAGE" >> "$FAKE_LOG"'
export FAKE_IDLE_NS=$(( 11 * 60 * 1000000000 ))
fire "Question J"; sleep 1
expect idle-command-runs "Claude needs you: my-app | checkout bug: Question J|local_test|Question J" 1
export FAKE_IDLE_NS=$(( 2 * 60 * 1000000000 ))
fire "Question K"; sleep 1
expect idle-command-not-at-desk "|Question K" 0
export NEEDS_YOU_IDLE_MINUTES=1
fire "Question L"; sleep 1
expect idle-minutes-from-env "|Question L" 1
unset NEEDS_YOU_IDLE_MINUTES

if [ "$FAIL" = 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
