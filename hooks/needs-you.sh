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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEADLINE="${NEEDS_YOU_TITLE:-Claude needs you}"
OPEN_LABEL="${NEEDS_YOU_OPEN:-Open}"
LATER_LABEL="${NEEDS_YOU_LATER:-Later}"
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

# Which session is this? The desktop app sets CLAUDE_CODE_HOST_SESSION_ID; a
# terminal session has only its own session id.
APP_ID="${CLAUDE_CODE_HOST_SESSION_ID:-}"
SID=$(printf '%s' "${APP_ID:-$CLI_ID}" | tr -c 'A-Za-z0-9_.-' '_')
SID="${SID:-none}"
ENTRY="$INBOX/$SID.json"

# Every writer of an entry (this hook and the window) holds its lock folder, so
# a check and the write that follows it see the same request. A lock older than
# a minute belongs to a writer that crashed.
lock_entry() {
  local _
  for _ in $(seq 1 40); do
    mkdir "$ENTRY.lock" 2>/dev/null && return 0
    [ -n "$(find "$ENTRY.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$ENTRY.lock" 2>/dev/null
    sleep 0.05
  done
  return 1
}
unlock_entry() { rmdir "$ENTRY.lock" 2>/dev/null; }

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

# Title, sidebar section and project of a desktop-app session. Each account
# keeps its own copy of the session file; the newest one is the live session.
APP="$HOME/Library/Application Support/Claude"
FILE=""
if [ -n "$APP_ID" ]; then
  FILE=$(find "$APP/claude-code-sessions" -name "$APP_ID.json" -type f -exec stat -f '%m %N' {} + 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)
fi
TITLE=""
[ -n "$FILE" ] && TITLE=$(jq -r '.title // empty' "$FILE" 2>/dev/null)
# The sidebar section: per account scope (the two folders above the session
# file), "code:<session id>" -> group id -> group name. Any scope will do.
SECTION=""
if [ -n "$FILE" ] && [ -f "$APP/claude_desktop_config.json" ]; then
  SCOPE=$(printf '%s' "$FILE" | awk -F/ '{print $(NF-2) "/" $(NF-1)}')
  SECTION=$(jq -r --arg s "$SCOPE" --arg k "code:$APP_ID" '
    (.preferences.epitaxyPrefs["dframe-group-scopes"] // {}) as $all
    | ([$all[$s] // empty] + [$all[]]) | map(. as $x | ($x.assignments[$k] // null) as $g
        | select($g) | ($x.groups[]? | select(.id == $g) | .name)) | .[0] // empty' \
    "$APP/claude_desktop_config.json" 2>/dev/null)
fi
# The project: the repository the session works in, else its folder.
CWD=""
[ -n "$FILE" ] && CWD=$(jq -r '.cwd // empty' "$FILE" 2>/dev/null)
[ -n "$CWD" ] || CWD=$(field .cwd)
PROJECT=""
if [ -n "$CWD" ]; then
  REPO=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
  PROJECT=$(basename "${REPO:-$CWD}")
fi
[ -n "$TITLE" ] || TITLE="${PROJECT:-Claude Code}"
LINK=""
[ -n "$APP_ID" ] && LINK="claude://claude.ai/epitaxy/$APP_ID"

# --- Autopilot -------------------------------------------------------------
# shellcheck source=hooks/autopilot.sh
. "$ROOT/hooks/autopilot.sh"
autopilot && exit 0

# --- Needs You -------------------------------------------------------------
mkdir -p "$INBOX" 2>/dev/null
# One line, at most 180 characters. jq counts characters, so a letter outside
# ASCII is never cut in half, whatever the locale of the hook's environment.
MSG=$(jq -rn --arg m "$MSG" '$m | gsub("[\r\n\t]+"; " ") | .[0:180]')

# The same message from the same session, still waiting, counts once per
# 2 minutes. Once it is handled, the same message again is a new request.
if jq -e --arg m "$MSG" --argjson now "$NOW" \
     '.done != true and .msg == $m and ($now - .ts) < 120' "$ENTRY" >/dev/null 2>&1; then
  exit 0
fi

# The tool call the request waits on. A notification has none: it keeps the one
# of the request it follows, if that one still waits.
WAITS_ON="$TOOL_USE_ID"
[ -n "$WAITS_ON" ] || WAITS_ON=$(jq -r 'select(.done != true) | .tool_use_id // empty' "$ENTRY" 2>/dev/null)

# The inbox entry: the newest request of a session replaces its earlier one.
jq -nc --argjson ts "$NOW" --arg session "$SID" --arg title "$TITLE" --arg section "$SECTION" \
  --arg project "$PROJECT" --arg msg "$MSG" --arg link "$LINK" --arg tu "$WAITS_ON" \
  '{ts:$ts,session:$session,title:$title,section:$section,project:$project,msg:$msg,link:$link,done:false}
   + (if $tu != "" then {tool_use_id:$tu} else {} end)' \
  > "$ENTRY.tmp.$$" 2>/dev/null && lock_entry && { mv "$ENTRY.tmp.$$" "$ENTRY" 2>/dev/null; unlock_entry; }
rm -f "$ENTRY.tmp.$$" 2>/dev/null

# Away from the Mac (no keyboard or mouse input for NEEDS_YOU_IDLE_MINUTES,
# default 10): run your own command too, for example a message to your phone.
# It gets the request in NEEDS_YOU_MESSAGE, NEEDS_YOU_SESSION_TITLE and
# NEEDS_YOU_SESSION_ID, and one line of text as its first argument.
if [ -n "${NEEDS_YOU_IDLE_CMD:-}" ]; then
  IDLE_NS=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print $NF; exit}')
  if [ "$(( ${IDLE_NS:-0} / 60000000000 ))" -ge "${NEEDS_YOU_IDLE_MINUTES:-10}" ] 2>/dev/null; then
    ( NEEDS_YOU_MESSAGE="$MSG" NEEDS_YOU_SESSION_TITLE="$TITLE" NEEDS_YOU_SESSION_ID="$SID" \
        /bin/sh -c "$NEEDS_YOU_IDLE_CMD" needs-you "$HEADLINE: $TITLE: $MSG" ) </dev/null >/dev/null 2>&1 &
  fi
fi

# The window shows the whole inbox and refreshes itself; a call while it is
# open does nothing. Without the Swift compiler: a banner, else a dialog.
fallback() {
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
  else
    osascript -e 'on run argv' -e 'activate' \
      -e 'display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button 1 giving up after 3600' \
      -e 'end run' -- "$HEADLINE: $TITLE" "$MSG" >/dev/null 2>&1
  fi
}
deliver() {
  if [ "${NEEDS_YOU_WINDOW:-1}" != 0 ] && "$WINDOW" --check; then
    "$WINDOW" && return 0
  fi
  fallback
}
( deliver ) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
exit 0
