# What the window shows about a session (sourced by hooks/needs-you.sh and
# bin/needs-you-scan).
#
# session_info APP_ID [CWD]  sets FILE, TITLE, SECTION, PROJECT and LINK for a
# desktop-app session (APP_ID local_...). CWD is the folder to use when the
# session has no session file, as for a terminal session.
# shellcheck shell=bash disable=SC2034

APP="$HOME/Library/Application Support/Claude"

# Each account keeps its own copy of a session file; the newest is the live one.
session_file() {
  [ -n "$1" ] || return 0
  find "$APP/claude-code-sessions" -name "$1.json" -type f -exec stat -f '%m %N' {} + 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
}

session_info() {
  local id="$1" cwd="${2:-}" scope repo
  FILE=$(session_file "$id")
  TITLE=""
  [ -n "$FILE" ] && TITLE=$(jq -r '.title // empty' "$FILE" 2>/dev/null)
  # The sidebar section: per account scope (the two folders above the session
  # file), "code:<session id>" -> group id -> group name. Any scope will do.
  SECTION=""
  if [ -n "$FILE" ] && [ -f "$APP/claude_desktop_config.json" ]; then
    scope=$(printf '%s' "$FILE" | awk -F/ '{print $(NF-2) "/" $(NF-1)}')
    SECTION=$(jq -r --arg s "$scope" --arg k "code:$id" '
      (.preferences.epitaxyPrefs["dframe-group-scopes"] // {}) as $all
      | ([$all[$s] // empty] + [$all[]]) | map(. as $x | ($x.assignments[$k] // null) as $g
          | select($g) | ($x.groups[]? | select(.id == $g) | .name)) | .[0] // empty' \
      "$APP/claude_desktop_config.json" 2>/dev/null)
  fi
  # The project: the repository the session works in, else its folder.
  if [ -n "$FILE" ]; then
    local file_cwd
    file_cwd=$(jq -r '.cwd // empty' "$FILE" 2>/dev/null)
    [ -n "$file_cwd" ] && cwd="$file_cwd"
  fi
  PROJECT=""
  if [ -n "$cwd" ]; then
    repo=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    PROJECT=$(basename "${repo:-$cwd}")
  fi
  [ -n "$TITLE" ] || TITLE="${PROJECT:-Claude Code}"
  LINK=""
  [ -n "$id" ] && LINK="claude://claude.ai/epitaxy/$id"
  return 0
}
