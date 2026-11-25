# Shared set-up for tests/test.sh and tests/autopilot-test.sh (sourced).
#
# Stand-ins for the window, terminal-notifier, osascript, open, pbcopy, ioreg
# and uname come first on PATH, and HOME points at a temp folder. Nothing shows
# on screen and no real state is touched. uname answers FAKE_UNAME (Darwin by
# default), so these suites test the macOS behaviour on every system; the
# system-specific parts (Linux, Windows) are in tests/platform-test.sh.
# shellcheck shell=bash disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/needs-you.sh"
AP="$ROOT/bin/nb-autopilot"
WORK=$(mktemp -d /tmp/needs-you-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
FAIL=0
# Time for a background hook to start; Git Bash starts processes far slower.
case "${OSTYPE:-}" in msys*|cygwin*) SPAWN_WAIT=1.2 ;; *) SPAWN_WAIT=0.3 ;; esac

cat > "$WORK/bin/window" <<'EOF'
#!/bin/bash
[ "${1:-}" = --check ] && exit "${FAKE_NO_WINDOW:-0}"
echo "WINDOW $* [${NEEDS_YOU_TITLE:-}]" >> "$FAKE_LOG"
EOF
cat > "$WORK/bin/terminal-notifier" <<'EOF'
#!/bin/bash
echo "BANNER $*" >> "$FAKE_LOG"
exit "${FAKE_BANNER_EXIT:-1}"
EOF
cat > "$WORK/bin/osascript" <<'EOF'
#!/bin/bash
# After "--" come the title, the message and the button labels.
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
echo "DIALOG [$1] $2 (labels: $(( $# - 2 )))" >> "$FAKE_LOG"
printf '%s\n' "${FAKE_ANSWER:-Later}"
EOF
cat > "$WORK/bin/open" <<'EOF'
#!/bin/bash
echo "OPEN $*" >> "$FAKE_LOG"
EOF
cat > "$WORK/bin/ioreg" <<'EOF'
#!/bin/bash
[ -n "${FAKE_NO_IDLE:-}" ] && exit 0
echo "    | |   \"HIDIdleTime\" = ${FAKE_IDLE_NS:-0}"
EOF
cat > "$WORK/bin/pbcopy" <<'EOF'
#!/bin/bash
echo "PBCOPY $(cat)" >> "$FAKE_LOG"
EOF
REAL_UNAME=$(command -v uname)
printf '#!/bin/bash\nif [ -n "${FAKE_UNAME:-}" ] && [ "${1:-}" = -s ]; then echo "$FAKE_UNAME"; exit 0; fi\nexec %q "$@"\n' \
  "$REAL_UNAME" > "$WORK/bin/uname"
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" NEEDS_YOU_WINDOW_CMD="$WORK/bin/window"

# A fresh home per scenario. By default the session is a desktop-app session
# named "my-app | checkout bug", filed in the sidebar section "🛒 Shop", working
# in a git repository called my-repo.
setup() {
  export HOME="$WORK/$1" FAKE_LOG="$WORK/$1.log"
  export CLAUDE_CODE_HOST_SESSION_ID="local_test" FAKE_UNAME=Darwin
  unset FAKE_BANNER_EXIT FAKE_ANSWER FAKE_NO_WINDOW FAKE_IDLE_NS FAKE_NO_IDLE
  # No display, desktop app data or PowerShell of the machine running the tests.
  unset DISPLAY WAYLAND_DISPLAY XDG_CONFIG_HOME
  export APPDATA="$HOME/AppData/Roaming"
  # Only the test's own window stand-in; no text or setting of the machine.
  local v
  for v in $(compgen -v NEEDS_YOU_); do [ "$v" = NEEDS_YOU_WINDOW_CMD ] || unset "$v"; done
  local app="$HOME/Library/Application Support/Claude"
  mkdir -p "$app/claude-code-sessions/acct/org" "$HOME/my-repo/src"
  git -C "$HOME/my-repo" init -q 2>/dev/null
  jq -nc --arg cwd "$HOME/my-repo/src" '{title:"my-app | checkout bug", cwd:$cwd}' \
    > "$app/claude-code-sessions/acct/org/local_test.json"
  echo '{"preferences":{"epitaxyPrefs":{"dframe-group-scopes":{"acct/org":{
    "groups":[{"id":"g1","name":"🛒 Shop"}],"assignments":{"code:local_test":"g1"}}}}}}' \
    > "$app/claude_desktop_config.json"
  : > "$FAKE_LOG"
}
INBOX() { printf '%s' "$HOME/.claude/needs-you/inbox/${1:-local_test}.json"; }
ask() {
  jq -nc --arg q "$1" '{hook_event_name:"PreToolUse", tool_name:"AskUserQuestion",
    session_id:"cli-1", cwd:"/work/my-repo", tool_input:{questions:[{question:$q}]}}'
}
fire() { ask "$1" | "$HOOK"; }
event() { jq -nc --arg e "$1" --arg t "${2:-}" --arg a "${3:-}" \
  '{hook_event_name:$e} + (if $t != "" then {tool_name:$t} else {} end) + (if $a != "" then {agent_id:$a} else {} end)' | "$HOOK"; }
entry() { jq -r "$1" "$(INBOX "${2:-}")" 2>/dev/null; }
expect() {  # name, fixed string to count in the log, wanted count
  local got
  got=$(grep -c -F -- "$2" "$FAKE_LOG")
  if [ "$got" = "$3" ]; then echo "PASS $1"
  else echo "FAIL $1: '$2' x$got, want $3"; cat "$FAKE_LOG"; FAIL=1; fi
}
check() {  # name, text, fixed string, 1 = must be present / 0 = must be absent
  local got=0
  printf '%s' "$2" | grep -q -F -- "$3" && got=1
  if [ "$got" = "$4" ]; then echo "PASS $1"
  else echo "FAIL $1: '$3' present=$got, want $4"; printf '%s\n' "$2"; FAIL=1; fi
}
# Git Bash cannot make a file read-only for its owner; those checks are skipped.
readonly_works() {
  local f="$WORK/.ro-probe"
  : > "$f"; chmod 400 "$f"
  if [ -w "$f" ]; then rm -f "$f"; return 1; fi
  chmod 600 "$f"; rm -f "$f"
}
# Nor a folder that its owner cannot write to.
readonly_dir_works() {
  local d="$WORK/.ro-dir" ok=1
  mkdir -p "$d"; chmod 500 "$d"
  if ( : > "$d/x" ) 2>/dev/null; then ok=0; fi
  chmod 700 "$d"; rm -rf "$d"
  [ "$ok" = 1 ]
}
skip() { echo "SKIP $1: $2"; }
same() {  # name, got, want
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2', want '$3'"; FAIL=1; fi
}
