# needs-you settings that do not depend on how a session was started (sourced).
#
# A session keeps the environment it started with, so a text or command set in
# ~/.claude/settings.json reaches only sessions started after the change, and
# the window took the language of whichever session opened it. These sources
# fill every NEEDS_YOU_* variable the environment leaves empty, in this order:
#
#   1. the session's environment (the env block of ~/.claude/settings.json)
#   2. ~/.claude/needs-you/settings.json, read on every request
#   3. the built-in translation NEEDS_YOU_LANG names, texts/<lang>.json
#   4. the English defaults in the hook and the window
#
# The window inherits the result from the hook that opens it.
# shellcheck shell=bash

needs_you_load() {  # a JSON object of "NEEDS_YOU_NAME": "text"
  [ -f "$1" ] || return 0
  local lines
  lines=$(jq -r 'to_entries[]
    | select((.key | test("^NEEDS_YOU_[A-Z_]+$")) and (.value | type == "string"))
    | "\(.key)\u001f\(.value | gsub("[\n\r]"; " "))"' "$1" 2>/dev/null) || return 0
  local key value
  while IFS=$'\037' read -r key value; do
    [ -n "$key" ] || continue
    [ -n "${!key:-}" ] || export "$key=$value"
  done <<EOF
$lines
EOF
}

needs_you_load "$HOME/.claude/needs-you/settings.json"
case "${NEEDS_YOU_LANG:-}" in
  ""|*[!a-z]*) ;;
  *) needs_you_load "$ROOT/texts/$NEEDS_YOU_LANG.json" ;;
esac
