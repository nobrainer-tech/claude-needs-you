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

# Writers take turns on an entry: while another writer holds its lock, a new
# request waits and is written after the lock is released, never lost.
mkdir "$(INBOX).lock"
fire "Question while locked" & sleep 0.6
same locked-entry-not-written-yet "$(entry .msg)" "old"
rmdir "$(INBOX).lock"; wait; sleep 0.3
same written-after-unlock "$(entry .msg)" "Question while locked"

# A session that ends is handled too.
fire "Question before the end"; sleep 1
event SessionEnd
same session-end-handles "$(entry .done)" "true"

# A tool call that waited for the lock while a newer request replaced the entry
# leaves the newer request waiting.
echo '{"ts":1,"session":"local_test","msg":"older","done":false}' > "$(INBOX)"
mkdir "$(INBOX).lock"
# Git Bash starts a process far slower: give the hook time to reach the lock.
event PostToolUse Bash & sleep "$SPAWN_WAIT"
jq -nc --argjson ts "$(date +%s)" '{ts:$ts,session:"local_test",msg:"newer",done:false}' > "$(INBOX)"
rmdir "$(INBOX).lock"; wait
same delayed-completion-keeps-newer "$(entry .done)" "false"

# Another session's tool call leaves this entry alone.
fire "Question D"; sleep 1
CLAUDE_CODE_HOST_SESSION_ID=local_other event PostToolUse Bash
same other-session-leaves-it "$(entry .done)" "false"

# Tools run in parallel: a request waits on one tool call, and only that call's
# completion handles it. A notification that follows keeps the call it waits on.
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_use_id":"tu-bash"}' | "$HOOK"; sleep 1
same request-keeps-tool-call "$(entry .tool_use_id)" "tu-bash"
echo '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_use_id":"tu-read"}' | "$HOOK"
same parallel-tool-leaves-it "$(entry .done)" "false"
echo '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}' | "$HOOK"; sleep 1
same notification-keeps-tool-call "$(entry .tool_use_id)" "tu-bash"
echo '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_use_id":"tu-read-2"}' | "$HOOK"
same parallel-tool-leaves-notification "$(entry .done)" "false"
echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"tu-bash"}' | "$HOOK"
same own-tool-call-handles "$(entry .done)" "true"

# Two prompts with the same text from two tool calls are two requests: the
# second replaces the first, so finishing the first leaves the second waiting.
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_use_id":"tu-1"}' | "$HOOK"; sleep 1
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_use_id":"tu-2"}' | "$HOOK"; sleep 1
same second-prompt-replaces-first "$(entry .tool_use_id)" "tu-2"
echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"tu-1"}' | "$HOOK"
same first-call-leaves-second "$(entry .done)" "false"
: > "$FAKE_LOG"
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_use_id":"tu-2"}' | "$HOOK"; sleep 1
expect same-call-again-counts-once "WINDOW" 0

# --- Settings that do not depend on the session ------------------------------

# A session started before the owner set the texts has none in its
# environment; ~/.claude/needs-you/settings.json still gives them, and the
# window opened by that session gets them too.
setup settings
mkdir -p "$HOME/.claude/needs-you"
echo '{"NEEDS_YOU_LANG":"pl","NEEDS_YOU_PLAN":"Plan do akceptacji"}' > "$HOME/.claude/needs-you/settings.json"
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' | "$HOOK"; sleep 1
same file-language-in-entry "$(entry .msg)" "Prośba o zgodę: Bash"
expect window-gets-file-language "[Claude czeka na Ciebie]" 1
echo '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode"}' | "$HOOK"; sleep 1
same file-text-beats-language "$(entry .msg)" "Plan do akceptacji"
# The session's own environment still wins.
NEEDS_YOU_PERMISSION="Zgoda" sh -c 'echo "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Read\"}" | "$0"' "$HOOK"; sleep 1
same environment-beats-file "$(entry .msg)" "Zgoda: Read"
# A command of several lines from the file runs as written, line by line.
jq -n --arg c "printf first >> '$HOME/idle.out'
printf second >> '$HOME/idle.out'" '{NEEDS_YOU_IDLE_CMD:$c}' > "$HOME/.claude/needs-you/settings.json"
FAKE_IDLE_NS=900000000000 sh -c 'echo "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Edit\"}" | "$0"' "$HOOK"; sleep 1
same file-command-keeps-lines "$(cat "$HOME/idle.out" 2>/dev/null)" "firstsecond"
# An unknown or unsafe language name is ignored.
echo '{"NEEDS_YOU_LANG":"../pl"}' > "$HOME/.claude/needs-you/settings.json"
echo '{"hook_event_name":"PermissionRequest","tool_name":"Grep"}' | "$HOOK"; sleep 1
same unsafe-language-ignored "$(entry .msg)" "Permission needed: Grep"
# Every text the window and the hook use has a Polish translation.
missing=$(grep -ho 'text("NEEDS_YOU_[A-Z_]*\|NEEDS_YOU_[A-Z_]*:-[^}$]' "$ROOT/app/main.swift" "$ROOT/hooks/needs-you.sh" \
  | grep -o 'NEEDS_YOU_[A-Z_]*' | sort -u | grep -v -e IDLE -e WINDOW \
  | while read -r k; do jq -e --arg k "$k" 'has($k)' "$ROOT/texts/pl.json" >/dev/null || echo "$k"; done)
same polish-covers-every-text "$missing" ""

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

# A terminal session (Claude Code CLI): titled by its folder, no link, and the
# command that returns to it, which the dialog copies.
setup terminal
unset CLAUDE_CODE_HOST_SESSION_ID
export FAKE_NO_WINDOW=1 FAKE_ANSWER="Copy the command"
fire "Question I"; sleep 1
expect terminal-title "DIALOG [Claude needs you: my-repo] Question I" 1
expect terminal-dialog-copy-button 'cd "/work/my-repo" && claude --resume cli-1 (labels: 2)' 1
expect terminal-copies-resume 'PBCOPY cd "/work/my-repo" && claude --resume cli-1' 1
expect terminal-no-open "OPEN" 0
same terminal-entry "$(entry .link cli-1)" ""
same terminal-entry-resume "$(entry .resume cli-1)" 'cd "/work/my-repo" && claude --resume cli-1'
same terminal-entry-cwd "$(entry .cwd cli-1)" "/work/my-repo"
# Its name from the transcript: the newest /rename, else the summary.
T="$HOME/t.jsonl"
printf '%s\n' '{"type":"summary","summary":"Fix the flaky test"}' '{"type":"user","message":{"content":"hi"}}' > "$T"
jq -nc --arg t "$T" '{hook_event_name:"PreToolUse", tool_name:"AskUserQuestion", session_id:"cli-2",
  cwd:"/work/my-repo", transcript_path:$t, tool_input:{questions:[{question:"Q?"}]}}' | "$HOOK"; sleep 1
same terminal-title-from-summary "$(entry .title cli-2)" "Fix the flaky test"
printf '%s\n' '{"type":"custom-title","customTitle":"checkout | retry","sessionId":"cli-2"}' >> "$T"
jq -nc --arg t "$T" '{hook_event_name:"PreToolUse", tool_name:"AskUserQuestion", session_id:"cli-2",
  cwd:"/work/my-repo", transcript_path:$t, tool_input:{questions:[{question:"Q2?"}]}}' | "$HOOK"; sleep 1
same terminal-title-from-rename "$(entry .title cli-2)" "checkout | retry"
# A folder with a quote or a dollar sign is single-quoted.
jq -nc '{hook_event_name:"PreToolUse", tool_name:"AskUserQuestion", session_id:"cli-3",
  cwd:"/work/it'"'"'s $HOME", tool_input:{questions:[{question:"Q3?"}]}}' | "$HOOK"; sleep 1
same terminal-resume-quoted "$(entry .resume cli-3)" "cd '/work/it'\\''s \$HOME' && claude --resume cli-3"

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
