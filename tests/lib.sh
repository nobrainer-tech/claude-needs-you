# Shared set-up for tests/test.sh and tests/autopilot-test.sh (sourced).
#
# Stand-ins for the window, terminal-notifier, osascript, open and ioreg come
# first on PATH, and HOME points at a temp folder. Nothing shows on screen and
# no real state is touched.
# shellcheck shell=bash disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/needs-you.sh"
AP="$ROOT/bin/nb-autopilot"
WORK=$(mktemp -d /tmp/needs-you-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
FAIL=0

cat > "$WORK/bin/window" <<'EOF'
#!/bin/bash
[ "${1:-}" = --check ] && exit "${FAKE_NO_WINDOW:-0}"
echo "WINDOW $*" >> "$FAKE_LOG"
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
echo "    | |   \"HIDIdleTime\" = ${FAKE_IDLE_NS:-0}"
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" NEEDS_YOU_WINDOW_CMD="$WORK/bin/window"

# A fresh home per scenario. By default the session is a desktop-app session
# named "my-app | checkout bug", filed in the sidebar section "🛒 Shop", working
# in a git repository called my-repo.
setup() {
  export HOME="$WORK/$1" FAKE_LOG="$WORK/$1.log"
  export CLAUDE_CODE_HOST_SESSION_ID="local_test"
  unset FAKE_BANNER_EXIT FAKE_ANSWER FAKE_NO_WINDOW FAKE_IDLE_NS NEEDS_YOU_IDLE_CMD
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
same() {  # name, got, want
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2', want '$3'"; FAIL=1; fi
}
