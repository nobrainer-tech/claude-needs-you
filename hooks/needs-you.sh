#!/bin/bash
# needs-you: one Claude Code hook, two jobs.
#
#   Needs You   When a session waits for you (a question, a plan to approve, a
#               permission prompt), it goes to one inbox window that lists every
#               waiting session. Clicking one opens that exact session in the
#               Claude desktop app. Handled ones grey out and drop to the bottom.
#   Autopilot   While autopilot is on (for all sessions until a set time, or for
#               one session ticked in the window), a question is refused with an
#               instruction to take the session's own recommended answer. Every
#               decision is logged. Plans and permission prompts are never answered.
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
# One jq call for the four fields. The unit separator is not whitespace, so an
# empty field cannot shift the others.
IFS=$'\037' read -r EVENT TOOL AGENT CLI_ID <<EOF
$(printf '%s' "$INPUT" | jq -r '[.hook_event_name, .tool_name, .agent_id, .session_id]
  | map(. // "" | tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' 2>/dev/null)
EOF

# Which session is this? The desktop app sets CLAUDE_CODE_HOST_SESSION_ID; a
# terminal session has only its own session id.
APP_ID="${CLAUDE_CODE_HOST_SESSION_ID:-}"
SID=$(printf '%s' "${APP_ID:-$CLI_ID}" | tr -c 'A-Za-z0-9_.-' '_')
SID="${SID:-none}"
ENTRY="$INBOX/$SID.json"

# The session moved on: you wrote to it, or one of its own tool calls finished
# (an answered question, an approved plan or permission). Its entry is handled.
# The end-of-turn tool returns before you answer, so it does not count; nor
# does a subagent's tool call.
case "$EVENT" in
  UserPromptSubmit|PostToolUse)
    [ "$TOOL" = mcp__ccd_turn__wrap_up ] && exit 0
    [ -n "$AGENT" ] && exit 0
    [ -f "$ENTRY" ] || exit 0
    TS=$(jq -r 'select(.done != true) | .ts' "$ENTRY" 2>/dev/null)
    [ -n "$TS" ] || exit 0
    jq -c --argjson n "$(date +%s)" '.done = true | .done_ts = $n' "$ENTRY" > "$ENTRY.tmp.$$" 2>/dev/null &&
      # A newer request may have replaced the entry meanwhile: leave that one alone.
      [ "$(jq -r .ts "$ENTRY" 2>/dev/null)" = "$TS" ] && mv "$ENTRY.tmp.$$" "$ENTRY" 2>/dev/null
    rm -f "$ENTRY.tmp.$$" 2>/dev/null
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
# Only questions are answered. Plans, permission prompts and blocked actions
# go to the inbox. It is on for this session when its checkbox in the window is
# ticked, or for every session until a set time. An end time more than a day
# away is not a real setting (nb-autopilot never writes one), so it counts as off.
NOW=$(date +%s)
AP=$(jq -r --arg id "$SID" --argjson now "$NOW" '
  if (.sessions // {})[$id] and .sessions[$id].off_epoch == null then "this session"
  elif (.until_epoch // 0) > $now and (.until_epoch - $now) <= 86400 then "until \(.until)"
  else empty end' "$DATA/autopilot.json" 2>/dev/null)
# A question about a step only the owner may take is never answered, even with
# a recommendation: it goes to the inbox. The words are checked in the question,
# its options and the suggested answers, in English and Polish.
OWNER_ONLY='merg|push|deploy|publish|release|delet|drop|remove|purchas|pay|refund|login|log in|password|credential|permission|secret|token|scal|wypchn|wdro|opublik|publikac|usu[nń]|kasow|zapła|płatno|hasł|zalog|uprawnie|zgod'
if [ -n "$AP" ] && printf '%s' "$INPUT" | jq -e --arg re "$OWNER_ONLY" '
     [.tool_input.questions[]? | .question, (.options[]?.label)] + [.tool_input.ask]
     + [.tool_input.actions[]? | .label, .action] | map(strings) | join(" ")
     | test($re; "i")' >/dev/null 2>&1; then
  AP=""
fi
if [ "$EVENT" = PreToolUse ] && [ "$TOOL" != ExitPlanMode ] && [ -n "$AP" ]; then
  if [ "$TOOL" = AskUserQuestion ]; then
    # Per question: the option whose label ends with "(Recommended)", else the
    # first option. "not recommended" inside a label does not count.
    DECISION=$(printf '%s' "$INPUT" | jq -r '
      [.tool_input.questions[]?
       | .question + " -> "
         + (([.options[]?.label | strings | select(test("\\((recommended|rekomend[a-z]*|zalecane)\\)\\s*$"; "i"))][0])
            // ([.options[]?.label | strings][0]) // "your recommendation")]
      | join(" | ")' 2>/dev/null)
    HOW="Do not ask. Take your recommended answer and continue the work: $DECISION."
  elif [ -n "$(field '.tool_input.actions[0].action')" ]; then
    # The first answer is an app action (commit, open or merge a pull request,
    # and so on): a go-ahead that belongs to the owner, never to autopilot.
    DECISION="$MSG -> left for the owner ($(field '.tool_input.actions[0].action'))"
    HOW="Do not end the turn with a question, and do not take that step: it needs the owner's go-ahead. Finish the turn without a question and leave it in your final message."
  else
    PICK=$(field '.tool_input.actions[0].label')
    DECISION="$MSG -> ${PICK:-your recommendation}"
    HOW="Do not end the turn with a question. Act on your recommended answer now ($DECISION), then finish the turn without a question."
  fi
  REASON="Autopilot is on ($AP): the owner is away and will not answer. Never decide these yourself, even when they are your recommendation: logins or passwords, payments or purchases, merging, pushing or deploying, publishing or sending anything to other people, deleting data, irreversible production changes, granting permissions. For such a step: skip it, finish the rest and leave the question in your final message. For everything else: $HOW This decision is logged for the owner's morning report."
  # Answer for the owner only when the decision is on record. If the log cannot
  # be written, fall through: the owner gets the inbox entry instead.
  mkdir -p "$DATA" 2>/dev/null
  if jq -nc --argjson ts "$NOW" --arg time "$(date '+%F %H:%M')" --arg session "$SID" \
       --arg title "$TITLE" --arg tool "$TOOL" --arg decision "$DECISION" \
       '{ts:$ts,time:$time,session:$session,title:$title,tool:$tool,decision:$decision}' \
       2>/dev/null >> "$DATA/decisions.jsonl"; then
    jq -n --arg r "$REASON" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
  fi
fi

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

# The inbox entry: the newest request of a session replaces its earlier one.
jq -nc --argjson ts "$NOW" --arg session "$SID" --arg title "$TITLE" --arg section "$SECTION" \
  --arg project "$PROJECT" --arg msg "$MSG" --arg link "$LINK" \
  '{ts:$ts,session:$session,title:$title,section:$section,project:$project,msg:$msg,link:$link,done:false}' \
  > "$ENTRY.tmp.$$" 2>/dev/null && mv "$ENTRY.tmp.$$" "$ENTRY" 2>/dev/null

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
