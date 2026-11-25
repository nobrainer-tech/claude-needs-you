# shellcheck shell=bash
# Autopilot part of hooks/needs-you.sh (sourced; uses its variables: INPUT,
# EVENT, TOOL, MSG, SID, TITLE, DATA and field(), and hooks/platform.sh).
#
# While autopilot is on for this session (its switch in the window) or for all
# sessions (until a set time), the owner is away. Then:
#   a question         is refused with an instruction to take the session's own
#                      recommended answer (AskUserQuestion, end-of-turn question);
#   a plan             is approved (ExitPlanMode);
#   a permission       is granted (PermissionRequest).
# A request that names a step only the owner may take is never decided: it goes
# to the inbox. Every decision is logged first; no record, no decision.
# An end time more than a day away is not a real setting (nb-autopilot never
# writes one), so it counts as off.

# A ticked session stays on autopilot for a day at most, like autopilot for all.
NOW=$(date +%s)
AP=$(jq -r --arg id "$SID" --argjson now "$NOW" '
  if ((.sessions // {})[$id] // {}) | ((.periods // []) | length > 0 and .[-1][1] == null
       and ($now - (.[-1][0] // 0)) < 86400) then "this session"
  elif (.until_epoch // 0) > $now and (.until_epoch - $now) <= 86400 then "until \(.until)"
  else empty end' "$DATA/autopilot.json" 2>/dev/null)

# Autopilot answers only while the owner is away: no keyboard or mouse input
# for NEEDS_YOU_AUTOPILOT_IDLE_MINUTES (default 5; 0 answers at once). While you
# are at the computer, or when this system cannot tell (hooks/platform.sh), a
# request waits for you in the window, autopilot or not.
autopilot_owner_away() {
  local minutes="${NEEDS_YOU_AUTOPILOT_IDLE_MINUTES:-5}"
  case "$minutes" in ''|*[!0-9]*) minutes=5 ;; esac
  [ "$minutes" = 0 ] && return 0
  ny_owner_away "$minutes"
}

# Steps only the owner may take, in English and Polish: merging, pushing,
# deploying, publishing or sending, deleting, paying, logins and secrets,
# permissions, commits and pull requests. Checked in the question, its options
# (labels and descriptions) and suggested answers, the plan, and a permission's tool and whole input.
OWNER_ONLY='merg|push|deploy|archiv|rename[a-z ]*repo|close (the )?(pr|pull|issue)|\bcancel|budget|spend|\b(usd|eur|pln)\b|[$€£][0-9]|[0-9] ?(zł|usd|eur|pln)\b|invoice|billing|production|migrat|account|\bpr ?#|archiwiz|nazw[ęy] repo|anul[ouj]|klucz|\bkeys?\b|tryb live|live mode|\bprice|\bcen[aęyo]\b|dostęp|access|udostępn|\bshare|\bimport|\blimit|wgra|polityk|privacy|\bga4\b|tracking|usuw|budżet|wydat|koszt|faktur|produkcj|konto|konta|publish|release|delet|drop|remove|\brm\b|truncate|reset --hard|--force|purchas|(\b|_)pay|refund|login|log in|password|credential|permission|secret|token|sudo|(\b|_)send(\b|_)|e-?mail\b|(\b|_)post(\b|_)|tweet|commit|pull request|gh pr|gh release|npm publish|vercel|curl[^|;]*(-X|--data|-d |-F )|\bssh\b|\bscp\b|scal|wypchn|wdro|opublik|publikac|wyślij|usu[nń]|kasow|zapła|płatno|hasł|zalog|uprawnie|zgod'

autopilot_owner_only() {
  printf '%s' "$INPUT" | jq -e --arg re "$OWNER_ONLY" --arg ev "$EVENT" '
    [.tool_input.questions[]? | .question, .header, (.options[]? | .label, .description)]
    + [.tool_input.ask, .tool_input.plan]
    + [.tool_input.actions[]? | .label, .action]
    + (if $ev == "PermissionRequest" then [.tool_name, (.tool_input | tostring)] else [] end)
    | map(strings) | join(" ") | test($re; "i")' >/dev/null 2>&1
}

# Log first, then print the hook's answer; when the log cannot be written,
# return 1 and the request goes to the inbox as usual.
autopilot_decide() {  # decision text, hook output JSON
  mkdir -p "$DATA" 2>/dev/null
  jq -nc --argjson ts "$NOW" --arg time "$(date '+%Y-%m-%d %H:%M')" --arg session "$SID" \
     --arg title "$TITLE" --arg tool "$TOOL" --arg decision "$1" \
     '{ts:$ts,time:$time,session:$session,title:$title,tool:$tool,decision:$decision}' \
     2>/dev/null >> "$DATA/decisions.jsonl" || return 1
  printf '%s\n' "$2"
}

autopilot() {
  [ -n "$AP" ] || return 1
  autopilot_owner_away || return 1
  autopilot_owner_only && return 1
  local decision how reason pick
  case "$EVENT:$TOOL" in
    PermissionRequest:*)
      decision="$TOOL -> allowed ($(printf '%s' "$INPUT" | jq -r '.tool_input | (.command // .file_path // .url // tostring) | tostring | gsub("[\r\n\t]+"; " ") | .[0:120]' 2>/dev/null))"
      autopilot_decide "$decision" '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
      return ;;
    PreToolUse:ExitPlanMode)
      # Plan approval needs "allow" together with the tool's input (updatedInput),
      # or the app still asks. A plan that names an owner-only step never gets here.
      autopilot_decide "plan -> approved" "$(printf '%s' "$INPUT" | jq '{hookSpecificOutput:{
        hookEventName:"PreToolUse", permissionDecision:"allow", updatedInput:(.tool_input // {})}}')"
      return ;;
    PreToolUse:AskUserQuestion)
      # Per question: the option whose label ends with "(Recommended)", else the
      # first option. "not recommended" inside a label does not count.
      decision=$(printf '%s' "$INPUT" | jq -r '
        [.tool_input.questions[]?
         | .question + " -> "
           + (([.options[]?.label | strings | select(test("\\((recommended|rekomend[a-z]*|zalecane)\\)\\s*$"; "i"))][0])
              // ([.options[]?.label | strings][0]) // "your recommendation")]
        | join(" | ")' 2>/dev/null)
      how="Do not ask. Take your recommended answer and continue the work: $decision." ;;
    PreToolUse:mcp__ccd_turn__wrap_up)
      if [ -n "$(field '.tool_input.actions[0].action')" ]; then
        # An app action (commit, open or merge a pull request) is a go-ahead
        # that belongs to the owner.
        decision="$MSG -> left for the owner ($(field '.tool_input.actions[0].action'))"
        how="Do not end the turn with a question, and do not take that step: it needs the owner's go-ahead. Finish the turn without a question and leave it in your final message."
      else
        pick=$(field '.tool_input.actions[0].label')
        decision="$MSG -> ${pick:-your recommendation}"
        how="Do not end the turn with a question. Act on your recommended answer now ($decision), then finish the turn without a question."
      fi ;;
    *) return 1 ;;
  esac
  reason="Autopilot is on ($AP): the owner is away and will not answer. Never decide these yourself, even when they are your recommendation: logins or passwords, payments, purchases or any spending (ad budgets included), merging, pushing or deploying, publishing or sending anything to other people, deleting, archiving, renaming or closing anything, cancelling runs, production changes and migrations, granting permissions or account access. For such a step: skip it, finish the rest and leave the question in your final message. For everything else: $how This decision is logged for the owner's morning report."
  autopilot_decide "$decision" "$(jq -n --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}')"
}
