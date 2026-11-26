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
  # One NUL-ended NAME=value record per setting, so a value keeps its
  # newlines (a command of several lines runs as written).
  local pair key
  while IFS= read -r -d '' pair; do
    key="${pair%%=*}"
    [ -n "${!key:-}" ] || export "$key=${pair#*=}"
  done < <(jq -j 'to_entries[]
    | select((.key | test("^NEEDS_YOU_[A-Z_]+$")) and (.value | type == "string")
             and (.value | contains("\u0000") | not))
    | "\(.key)=\(.value)\u0000"' "$1" 2>/dev/null)
}

needs_you_load "$HOME/.claude/needs-you/settings.json"
case "${NEEDS_YOU_LANG:-}" in
  ""|*[!a-z]*) ;;
  *) needs_you_load "$ROOT/texts/$NEEDS_YOU_LANG.json" ;;
esac
