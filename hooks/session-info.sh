# What the window shows about a session (sourced by hooks/needs-you.sh and
# bin/needs-you-scan, after hooks/platform.sh).
#
# session_info APP_ID [CWD] [TRANSCRIPT] [CLI_ID]
#   sets FILE, TITLE, SECTION, PROJECT, LINK, CWD and RESUME.
#   A desktop-app session (APP_ID local_...) gets its title, sidebar section and
#   a claude:// link from the app's session file. A terminal session (Claude
#   Code CLI or an IDE) has no such file: its title is the name it was given
#   (/rename) or the summary in its transcript, else its project, and RESUME is
#   the command that returns to it (cd <folder> && claude --resume <id>).
# shellcheck shell=bash disable=SC2034

APP=$(ny_app_dir)

# Each account keeps its own copy of a session file; the newest is the live one.
session_file() {
  [ -n "$1" ] || return 0
  find "$APP/claude-code-sessions" -name "$1.json" -type f -exec stat "${NY_STAT[@]}" {} + 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
}

# The newest name of a terminal session: /rename writes a custom-title line,
# older versions a summary line.
transcript_title() {
  [ -n "$1" ] && [ -f "$1" ] || return 0
  grep -a -E '"type": ?"(custom-title|summary)"' "$1" 2>/dev/null | tail -1 \
    | jq -r '(.customTitle // .summary // empty) | gsub("[\r\n\t]+"; " ") | .[0:120]' 2>/dev/null
}

session_info() {
  local id="$1" transcript scope repo
  CWD="${2:-}"
  transcript=$(ny_unix_path "${3:-}")
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
    [ -n "$file_cwd" ] && CWD="$file_cwd"
  fi
  PROJECT=""
  if [ -n "$CWD" ]; then
    repo=$(git -C "$(ny_unix_path "$CWD")" rev-parse --show-toplevel 2>/dev/null)
    repo="${repo:-$CWD}"
    repo="${repo//\\//}"
    repo="${repo%/}"
    PROJECT="${repo##*/}"
  fi
  [ -n "$TITLE" ] || TITLE=$(transcript_title "$transcript")
  [ -n "$TITLE" ] || TITLE="${PROJECT:-Claude Code}"
  LINK=""
  RESUME=""
  if [ -n "$id" ]; then
    LINK="claude://claude.ai/epitaxy/$id"
  else
    RESUME=$(ny_resume_cmd "$CWD" "${4:-}")
  fi
  return 0
}
