#!/bin/bash
# needs-you: one Claude Code hook, two jobs.
#
#   Needs You   When a session waits for you (a question, a plan to approve, a
#               permission prompt), it goes to one inbox window that lists every
#               waiting session. Clicking one opens that exact session in the
#               Claude desktop app. Handled ones grey out and drop to the bottom.
#   Autopilot   While autopilot is on (for all sessions until a set time, or for
#               one session ticked in the window), it answers for you: a question
#               gets the session's own recommended answer, a plan is approved and
#               a permission granted. Steps only you may take (merge, push,
#               deploy, publish, send, delete, pay, credentials) always wait for
#               you. Every decision is logged (hooks/autopilot.sh).
#
# Reads the hook JSON on stdin. Prints nothing, or a PreToolUse "deny" under
# autopilot. Any failure is silent: this hook must never break a session.
# https://github.com/nobrainer-tech/claude-needs-you

PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
command -v jq >/dev/null 2>&1 || exit 0

# Git Bash on Windows may start the hook with a backslash path.
ROOT="$(cd "$(dirname "${0//\\//}")/.." && pwd)"
# shellcheck source=hooks/platform.sh
. "$ROOT/hooks/platform.sh"
# shellcheck source=hooks/settings.sh
. "$ROOT/hooks/settings.sh"
HEADLINE="${NEEDS_YOU_TITLE:-Claude needs you}"
OPEN_LABEL="${NEEDS_YOU_OPEN:-Open}"
LATER_LABEL="${NEEDS_YOU_LATER:-Later}"
COPY_LABEL="${NEEDS_YOU_COPY:-Copy the command}"
WINDOW="${NEEDS_YOU_WINDOW_CMD:-$ROOT/bin/needs-you-window}"
DATA="$HOME/.claude/needs-you"            # inbox/, autopilot.json, decisions.jsonl
INBOX="$DATA/inbox"

INPUT=$(cat)
field() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }
# One jq call for the five fields. The unit separator is not whitespace, so an
# empty field cannot shift the others.
IFS=$'\037' read -r EVENT TOOL AGENT CLI_ID TOOL_USE_ID <<EOF
$(printf '%s' "$INPUT" | jq -r '[.hook_event_name, .tool_name, .agent_id, .session_id, .tool_use_id]
  | map(. // "" | tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' 2>/dev/null)
EOF

# A session started (also when the desktop app opens): look for sessions that
# already wait, in the background.
if [ "$EVENT" = SessionStart ]; then
  ( "$ROOT/bin/needs-you-scan" ) </dev/null >/dev/null 2>&1 &
  exit 0
fi

# Which session is this? The desktop app sets CLAUDE_CODE_HOST_SESSION_ID; a
# terminal session has only its own session id.
APP_ID="${CLAUDE_CODE_HOST_SESSION_ID:-}"
SID=$(printf '%s' "${APP_ID:-$CLI_ID}" | tr -c 'A-Za-z0-9_.-' '_')
SID="${SID:-none}"
ENTRY="$INBOX/$SID.json"

# Every writer of an entry (this hook, the scan and the window) holds its lock
# (ny_lock), so a check and the write that follows it see the same request. A
# lock older than a minute belongs to a writer that crashed.
lock_entry() { ny_lock "$ENTRY.lock" 40 0.05; }
unlock_entry() { ny_unlock "$ENTRY.lock"; }

# The inbox page in the browser (Linux, Windows) reads a data file; keep it
# current whenever an entry changes. Never on a Mac that has not used it.
web_refresh() {
  [ -f "$DATA/web/index.html" ] || return 0
  ( "$WINDOW" --refresh ) </dev/null >/dev/null 2>&1 &
}

# The session moved on: you wrote to it, one of its own tool calls finished (an
# answered question, an approved plan or permission), or it ended. Its entry is
# handled.
# The end-of-turn tool returns before you answer, so it does not count; nor
# does a subagent's tool call. Tools run in parallel, so a tool call handles a
# request only when it is the call that request waits on (same tool_use_id).
case "$EVENT" in
  UserPromptSubmit|PostToolUse|SessionEnd)
    [ "$TOOL" = mcp__ccd_turn__wrap_up ] && exit 0
    [ -n "$AGENT" ] && exit 0
    [ -f "$ENTRY" ] || exit 0
    # The request this event follows; checked again under the lock, so a newer
    # request written while we waited for it stays waiting.
    TS=$(jq -r 'select(.done != true) | .ts' "$ENTRY" 2>/dev/null)
    [ -n "$TS" ] || exit 0
    if [ "$EVENT" = PostToolUse ]; then
      WAITS_ON=$(jq -r '.tool_use_id // empty' "$ENTRY" 2>/dev/null)
      [ -z "$WAITS_ON" ] || [ "$WAITS_ON" = "$TOOL_USE_ID" ] || exit 0
    fi
    lock_entry || exit 0
    jq -c --argjson n "$(date +%s)" --argjson ts "$TS" \
      'if .done != true and .ts == $ts then .done = true | .done_ts = $n else . end' \
      "$ENTRY" > "$ENTRY.tmp.$$" 2>/dev/null && mv "$ENTRY.tmp.$$" "$ENTRY" 2>/dev/null
    rm -f "$ENTRY.tmp.$$" 2>/dev/null
    unlock_entry
    web_refresh
    exit 0 ;;
esac

case "$EVENT:$TOOL" in
  PreToolUse:AskUserQuestion)        MSG=$(field '.tool_input.questions[0].question') ;;
  PreToolUse:mcp__ccd_turn__wrap_up) MSG=$(field '.tool_input.ask'); [ -n "$MSG" ] || exit 0 ;;
  PreToolUse:ExitPlanMode)           MSG="${NEEDS_YOU_PLAN:-A plan is waiting for your approval}" ;;
  Notification:*)                    MSG=$(field .message) ;;
  PermissionRequest:*)               MSG="${NEEDS_YOU_PERMISSION:-Permission needed}: $TOOL" ;;
  PermissionDenied:*)                [ -z "$AGENT" ] || exit 0; MSG="${NEEDS_YOU_BLOCKED:-Blocked}: $TOOL" ;;
  *) exit 0 ;;
esac
[ -n "$MSG" ] || MSG="${NEEDS_YOU_WAITING:-A session is waiting for you}"

# Title, sidebar section, project and link of the session.
# shellcheck source=hooks/session-info.sh
. "$ROOT/hooks/session-info.sh"
session_info "$APP_ID" "$(field .cwd)" "$(field .transcript_path)" "$CLI_ID"

# --- Autopilot -------------------------------------------------------------
# shellcheck source=hooks/autopilot.sh
. "$ROOT/hooks/autopilot.sh"
autopilot && exit 0

# --- Needs You -------------------------------------------------------------
mkdir -p "$INBOX" 2>/dev/null
# One line, at most 180 characters. jq counts characters, so a letter outside
# ASCII is never cut in half, whatever the locale of the hook's environment.
MSG=$(jq -rn --arg m "$MSG" '$m | gsub("[\r\n\t]+"; " ") | .[0:180]')

# The same request from the same session, still waiting, counts once per
# 2 minutes. Once it is handled, the same message again is a new request; so is
# the same message from another tool call (two Bash prompts in a row).
if jq -e --arg m "$MSG" --arg tu "$TOOL_USE_ID" --argjson now "$NOW" \
     '.done != true and .msg == $m and ($now - .ts) < 120
      and ($tu == "" or (.tool_use_id // "") == "" or .tool_use_id == $tu)' "$ENTRY" >/dev/null 2>&1; then
  exit 0
fi

# The tool call the request waits on. A notification has none: it keeps the one
# of the request it follows, if that one still waits.
WAITS_ON="$TOOL_USE_ID"
[ -n "$WAITS_ON" ] || WAITS_ON=$(jq -r 'select(.done != true) | .tool_use_id // empty' "$ENTRY" 2>/dev/null)

# The inbox entry: the newest request of a session replaces its earlier one.
jq -nc --argjson ts "$NOW" --arg session "$SID" --arg title "$TITLE" --arg section "$SECTION" \
  --arg project "$PROJECT" --arg msg "$MSG" --arg link "$LINK" --arg tu "$WAITS_ON" \
  --arg resume "$RESUME" --arg cwd "$CWD" \
  '{ts:$ts,session:$session,title:$title,section:$section,project:$project,msg:$msg,link:$link,done:false}
   + (if $tu != "" then {tool_use_id:$tu} else {} end)
   + (if $resume != "" then {resume:$resume, cwd:$cwd} else {} end)' \
  > "$ENTRY.tmp.$$" 2>/dev/null && lock_entry && { mv "$ENTRY.tmp.$$" "$ENTRY" 2>/dev/null; unlock_entry; }
rm -f "$ENTRY.tmp.$$" 2>/dev/null

# Away from the computer (no keyboard or mouse input for NEEDS_YOU_IDLE_MINUTES,
# default 10): run your own command too, for example a message to your phone.
# It gets the request in NEEDS_YOU_MESSAGE, NEEDS_YOU_SESSION_TITLE and
# NEEDS_YOU_SESSION_ID, and one line of text as its first argument. When this
# system cannot tell the idle time, it does not run.
if [ -n "${NEEDS_YOU_IDLE_CMD:-}" ]; then
  if ny_owner_away "${NEEDS_YOU_IDLE_MINUTES:-10}"; then
    ( NEEDS_YOU_MESSAGE="$MSG" NEEDS_YOU_SESSION_TITLE="$TITLE" NEEDS_YOU_SESSION_ID="$SID" \
        /bin/sh -c "$NEEDS_YOU_IDLE_CMD" needs-you "$HEADLINE: $TITLE: $MSG" ) </dev/null >/dev/null 2>&1 &
  fi
fi

# macOS: the window shows the whole inbox and refreshes itself; a call while it
# is open does nothing. Without the Swift compiler: a banner, else a dialog.
# A terminal session's dialog offers to copy the command that returns to it.
# Linux and Windows: a native notification, and the inbox page in the browser.
fallback() {
  if [ "$NY_OS" != macos ]; then
    ny_notify "$HEADLINE" "$TITLE: $MSG${RESUME:+
$RESUME}" "$([ -f "$DATA/web/index.html" ] && printf '%s' "$DATA/web/index.html")"
    return
  fi
  if command -v terminal-notifier >/dev/null 2>&1; then
    local sub="$TITLE"
    case "$sub" in [-\(\[\{]*) sub="▸ $sub" ;; esac
    set -- -title "$HEADLINE" -subtitle "$sub" -message "▸ $MSG" -group "needs-you-$SID" -sound default
    [ -n "$LINK" ] && set -- "$@" -open "$LINK"
    terminal-notifier "$@" && return 0
  fi
  local answer
  if [ -n "$LINK" ]; then
    answer=$(osascript -e 'on run argv' -e 'activate' \
      -e 'set r to display dialog (item 2 of argv) with title (item 1 of argv) buttons {item 3 of argv, item 4 of argv} default button 2 giving up after 3600' \
      -e 'return button returned of r' -e 'end run' \
      -- "$HEADLINE: $TITLE" "$MSG" "$LATER_LABEL" "$OPEN_LABEL" 2>/dev/null)
    [ "$answer" = "$OPEN_LABEL" ] && open "$LINK"
  elif [ -n "$RESUME" ]; then
    answer=$(osascript -e 'on run argv' -e 'activate' \
      -e 'set r to display dialog (item 2 of argv) with title (item 1 of argv) buttons {item 3 of argv, item 4 of argv} default button 2 giving up after 3600' \
      -e 'return button returned of r' -e 'end run' \
      -- "$HEADLINE: $TITLE" "$MSG

$RESUME" "$LATER_LABEL" "$COPY_LABEL" 2>/dev/null)
    [ "$answer" = "$COPY_LABEL" ] && printf '%s' "$RESUME" | pbcopy
  else
    osascript -e 'on run argv' -e 'activate' \
      -e 'display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button 1 giving up after 3600' \
      -e 'end run' -- "$HEADLINE: $TITLE" "$MSG" >/dev/null 2>&1
  fi
}
deliver() {
  if ny_web_inbox; then
    # The page first (it opens only when it has not been opened lately), then
    # on Linux and Windows the notification, which may wait for a click.
    if [ "${NEEDS_YOU_WINDOW:-1}" != 0 ] && "$WINDOW" --check && "$WINDOW" --notify; then
      [ "$NY_OS" = macos ] && return 0
    fi
    fallback
    return 0
  fi
  if [ "${NEEDS_YOU_WINDOW:-1}" != 0 ] && "$WINDOW" --check; then
    "$WINDOW" && return 0
  fi
  fallback
}
( deliver ) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
exit 0
