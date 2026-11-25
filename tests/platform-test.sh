#!/bin/bash
# Tests for what differs per system (hooks/platform.sh): idle time, the desktop
# app's folder, notifications and the inbox page on Linux and Windows. uname is
# faked, and so are xprintidle, gdbus, notify-send, PowerShell and the program
# that opens the page, so every branch runs on any system.
# Usage: bash tests/platform-test.sh
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
WINDOW_REAL="$ROOT/bin/needs-you-window"

cat > "$WORK/bin/xprintidle" <<'EOF'
#!/bin/bash
echo "${FAKE_XIDLE_MS:-}"
EOF
cat > "$WORK/bin/gdbus" <<'EOF'
#!/bin/bash
[ -n "${FAKE_MUTTER_MS:-}" ] && echo "(uint64 $FAKE_MUTTER_MS,)"
EOF
cat > "$WORK/bin/notify-send" <<'EOF'
#!/bin/bash
[ "${1:-}" = --help ] && exit 0
echo "NOTIFY $*" >> "$FAKE_LOG"
EOF
cat > "$WORK/fake-powershell" <<'EOF'
#!/bin/bash
script=$(cat)
case "$script" in
  *GetLastInputInfo*) [ -n "${FAKE_WIN_IDLE_MS:-}" ] && printf '%s\r\n' "$FAKE_WIN_IDLE_MS" ;;
  *ToastNotificationManager*) echo "TOAST $NY_TITLE|$NY_BODY" >> "$FAKE_LOG" ;;
esac
EOF
cat > "$WORK/opener" <<'EOF'
#!/bin/bash
echo "BROWSER $*" >> "$FAKE_LOG"
EOF
chmod +x "$WORK/bin/"* "$WORK/fake-powershell" "$WORK/opener"

# Wait (up to 10 s) until FILE holds TEXT: the hook delivers in the background.
settle() { local _; for _ in $(seq 1 50); do grep -q -F -- "$2" "$1" 2>/dev/null && return 0; sleep 0.2; done; }
settle_count() { local _; for _ in $(seq 1 50); do [ "$(grep -c -F -- "$2" "$1" 2>/dev/null)" -ge "$3" ] && return 0; sleep 0.2; done; }

# Sourced in a subshell, as the hook does, for one system.
idle() { FAKE_UNAME="$1" bash -c '. "$0/hooks/platform.sh"; ny_idle_seconds' "$ROOT"; }
appdir() { FAKE_UNAME="$1" bash -c '. "$0/hooks/platform.sh"; ny_app_dir' "$ROOT"; }

# --- Idle time -------------------------------------------------------------------

setup idle
same macos-ioreg "$(FAKE_IDLE_NS=420000000000 idle Darwin)" "420"
same linux-no-display-unknown "$(FAKE_XIDLE_MS=5000 idle Linux)" ""
same linux-x11-xprintidle "$(DISPLAY=:0 FAKE_XIDLE_MS=361000 idle Linux)" "361"
same linux-x11-falls-back-to-mutter "$(DISPLAY=:0 FAKE_MUTTER_MS=7000 idle Linux)" "7"
same linux-wayland-mutter "$(WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 FAKE_MUTTER_MS=600000 FAKE_XIDLE_MS=1 idle Linux)" "600"
same linux-wayland-not-gnome-unknown "$(WAYLAND_DISPLAY=wayland-0 FAKE_XIDLE_MS=1 idle Linux)" ""
same windows-powershell "$(NEEDS_YOU_POWERSHELL="$WORK/fake-powershell" FAKE_WIN_IDLE_MS=330500 idle MINGW64_NT-10.0-26100)" "330"
same windows-no-answer-unknown "$(NEEDS_YOU_POWERSHELL="$WORK/fake-powershell" idle MSYS_NT-10.0)" ""
same own-command-wins "$(NEEDS_YOU_IDLE_SECONDS_CMD='echo 99' idle Linux)" "99"
same own-command-garbage-unknown "$(NEEDS_YOU_IDLE_SECONDS_CMD='echo soon' idle Linux)" ""
same unknown-system "$(idle SunOS)" ""

# --- A lock left by a writer that crashed ------------------------------------------

. "$ROOT/hooks/platform.sh"
mkdir "$WORK/fresh.lock" "$WORK/old.lock"
touch -t 202001010000 "$WORK/old.lock"
check fresh-lock-is-live "$(ny_stale "$WORK/fresh.lock" && echo stale)" "stale" 0
check old-lock-is-stale "$(ny_stale "$WORK/old.lock" && echo stale)" "stale" 1
# Two writers found the lock stale; the first took it over and a new writer
# holds a fresh one. The second, still acting on its old verdict, must leave the
# fresh lock alone.
: > "$WORK/a.lock"
ny_break_stale "$WORK/a.lock"
same outdated-stale-verdict-keeps-fresh-lock "$([ -e "$WORK/a.lock" ] && echo kept)" "kept"
# A stale lock is taken over; while another writer holds the breaker, it is not.
: > "$WORK/b.lock"; touch -t 202001010000 "$WORK/b.lock"
: > "$WORK/b.lock.break"
ny_lock "$WORK/b.lock" 2 0.01
same busy-breaker-keeps-lock "$(cat "$WORK/b.lock" 2>/dev/null)" ""
rm -f "$WORK/b.lock.break"
ny_lock "$WORK/b.lock" 2 0.01
same stale-lock-taken-over "$(cat "$WORK/b.lock" 2>/dev/null)" "$$"
touch -t 202001010000 "$WORK/b.lock" && : > "$WORK/b.lock.break" && touch -t 202001010000 "$WORK/b.lock.break"
ny_lock "$WORK/b.lock" 3 0.01
same crashed-breaker-cleared "$(cat "$WORK/b.lock" 2>/dev/null)" "$$"
same breaker-gone-after-takeover "$([ -e "$WORK/b.lock.break" ] && echo left)" ""
ny_unlock "$WORK/b.lock"

# --- Numbers from settings and idle tools ---------------------------------------------

same int-leading-zero-is-decimal "$(ny_int 010 5)" "10"
same int-08-is-eight "$(ny_int 08 5)" "8"
same int-junk-is-default "$(ny_int 5m 7)" "7"
same idle-decimal-seconds "$(NEEDS_YOU_IDLE_SECONDS_CMD='echo 4.000' idle Linux)" "4"
same idle-leading-zero "$(NEEDS_YOU_IDLE_SECONDS_CMD='echo 0540' idle Linux)" "540"
same xprintidle-junk-unknown "$(DISPLAY=:0 FAKE_XIDLE_MS='12 34' idle Linux)" ""
same nine-minutes-is-not-010 "$(NEEDS_YOU_IDLE_SECONDS_CMD='echo 540' bash -c '. "$0/hooks/platform.sh"; ny_owner_away 010 && echo away' "$ROOT")" ""
same ten-minutes-is-010 "$(NEEDS_YOU_IDLE_SECONDS_CMD='echo 600' bash -c '. "$0/hooks/platform.sh"; ny_owner_away 010 && echo away' "$ROOT")" "away"
same 08-minutes-no-error "$(NEEDS_YOU_IDLE_SECONDS_CMD='echo 600' bash -c '. "$0/hooks/platform.sh"; ny_owner_away 08 2>&1 && echo away' "$ROOT")" "away"

# --- The resume command in every shell ------------------------------------------------

same resume-drive-root "$(bash -c '. "$0/hooks/platform.sh"; ny_resume_cmd "C:\\" s1' "$ROOT")" 'cd "C:\." && claude --resume s1'
same resume-trailing-backslash "$(bash -c '. "$0/hooks/platform.sh"; ny_resume_cmd "C:\\work\\" s1' "$ROOT")" 'cd "C:\work\." && claude --resume s1'
# shellcheck disable=SC1111,SC1112  # typographic quotes on purpose
same resume-windows-typographic-quote "$(FAKE_UNAME=MINGW64_NT-10.0 bash -c '. "$0/hooks/platform.sh"; ny_resume_cmd "C:\\it’s “x”" s1' "$ROOT")" "Set-Location -LiteralPath 'C:\it’’s “x”'; claude --resume s1"
same resume-windows-apostrophe "$(FAKE_UNAME=MINGW64_NT-10.0 bash -c '. "$0/hooks/platform.sh"; ny_resume_cmd "C:\\Ann'"'"'s" s1' "$ROOT")" "Set-Location -LiteralPath 'C:\Ann''s'; claude --resume s1"
# The POSIX form runs in a real shell and lands in that folder (no " on Windows).
case "${OSTYPE:-}" in msys*|cygwin*) d="$WORK/it's \$HOME" ;; *) d="$WORK/it's \$HOME \"q\"" ;; esac
mkdir -p "$d"
cmd=$(bash -c '. "$0/hooks/platform.sh"; ny_resume_cmd "$1" s1' "$ROOT" "$d")
# shellcheck disable=SC2329  # claude is called by the eval'd command
same resume-posix-runs "$(claude() { pwd; }; eval "$cmd")" "$d"

# --- The PowerShell scripts parse (and on Windows, run) -------------------------------

ps=""
for c in powershell.exe pwsh; do ps=$(command -v "$c" 2>/dev/null) && break; done
if [ -n "$ps" ]; then
  for name in idle toast; do
    out=$(NY_PS_SRC="$(bash -c '. "$0/hooks/platform.sh"; ny_ps_'"$name"'_script' "$ROOT")" "$ps" -NoProfile -NonInteractive -Command \
      '$e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($env:NY_PS_SRC, [ref]$null, [ref]$e); $e.Count' 2>&1 | tr -d '\r\n')
    same "powershell-parses-$name-script" "$out" "0"
  done
  # The C# inside compiles (on Linux and macOS user32 is missing, so only the
  # call fails there); on Windows the whole script prints the idle milliseconds.
  out=$(bash -c '. "$0/hooks/platform.sh"; ny_ps_idle_script' "$ROOT" | "$ps" -NoProfile -NonInteractive -Command - 2>&1 | tr -d '\r\n')
  check powershell-idle-csharp-compiles "$out" "error CS" 0
  check powershell-idle-type-added "$out" "Cannot add type" 0
  case "${OSTYPE:-}" in
    msys*|cygwin*) same windows-idle-runs-clean "$(printf '%s\n' "$out" | grep -v -E '^[0-9]*$')" "" ;;
  esac
else
  skip powershell-parses-scripts "no PowerShell here"
fi

# --- jq: a missing jq.exe stays missing; titles keep their slashes --------------------

same no-jq-function-without-jq "$(env -i HOME="$HOME" /bin/bash -c 'OSTYPE=msys; PATH=/nonexistent; . "$0/hooks/platform.sh" 2>/dev/null; type -t jq' "$ROOT")" ""

# --- The desktop app's folder ------------------------------------------------------

same app-dir-macos "$(appdir Darwin)" "$HOME/Library/Application Support/Claude"
same app-dir-linux "$(appdir Linux)" "$HOME/.config/Claude"
same app-dir-linux-xdg "$(XDG_CONFIG_HOME=/x/cfg appdir Linux)" "/x/cfg/Claude"
same app-dir-windows "$(appdir MINGW64_NT-10.0)" "$HOME/AppData/Roaming/Claude"
same app-dir-by-hand "$(NEEDS_YOU_APP_DIR=/srv/claude appdir Linux)" "/srv/claude"

# --- Autopilot needs a known idle time ---------------------------------------------

setup linux-autopilot
export FAKE_UNAME=Linux
"$AP" on 23:59 >/dev/null
check linux-on-uses-portable-date "$("$AP" status)" "Autopilot ON until" 1
check linux-unknown-idle-not-answered "$(fire "Which path on Linux?")" "permissionDecision" 0
same linux-unknown-idle-in-inbox "$(entry .msg)" "Which path on Linux?"
doc=$("$AP" doctor)
check linux-doctor-says-unknown "$doc" "autopilot will NOT answer" 1
check linux-doctor-hint-xprintidle "$doc" "sudo apt install xprintidle" 1
check linux-doctor-hint-notify "$doc" "ok       notify-send" 1
export DISPLAY=:0 FAKE_XIDLE_MS=900000
check linux-away-answered "$(fire "Which path while away?")" '"permissionDecision": "deny"' 1
check linux-doctor-idle-known "$("$AP" doctor)" "idle time: 900 s since the last input (xprintidle)" 1
export FAKE_XIDLE_MS=2000
check linux-present-not-answered "$(fire "Which path while here?")" "permissionDecision" 0
unset DISPLAY FAKE_XIDLE_MS
"$AP" off >/dev/null

setup windows-autopilot
export FAKE_UNAME=MINGW64_NT-10.0 NEEDS_YOU_POWERSHELL="$WORK/fake-powershell"
"$AP" on 23:59 >/dev/null
check windows-unknown-idle-not-answered "$(fire "Which path on Windows?")" "permissionDecision" 0
check windows-doctor-says-unknown "$("$AP" doctor)" "autopilot will NOT answer" 1
export FAKE_WIN_IDLE_MS=700000
check windows-away-answered "$(fire "Which path while away?")" '"permissionDecision": "deny"' 1
unset FAKE_WIN_IDLE_MS NEEDS_YOU_POWERSHELL
"$AP" off >/dev/null

# --- Requests from a terminal session on Linux and Windows --------------------------

setup linux-cli
export FAKE_UNAME=Linux
unset CLAUDE_CODE_HOST_SESSION_ID
fire "Ship the docs fix?"; settle "$FAKE_LOG" NOTIFY
expect linux-window-asked-to-notify "WINDOW --notify" 1
expect linux-notification "NOTIFY -a Needs You -- Claude needs you my-repo: Ship the docs fix?" 1
expect linux-notification-has-resume 'cd "/work/my-repo" && claude --resume cli-1' 1
expect linux-no-dialog "DIALOG" 0
expect linux-no-banner "BANNER" 0
same linux-entry-resume "$(entry .resume cli-1)" 'cd "/work/my-repo" && claude --resume cli-1'

setup windows-cli
export FAKE_UNAME=MINGW64_NT-10.0 NEEDS_YOU_POWERSHELL="$WORK/fake-powershell"
unset CLAUDE_CODE_HOST_SESSION_ID
jq -nc '{hook_event_name:"PreToolUse", tool_name:"AskUserQuestion", session_id:"cli-w",
  cwd:"C:\\Users\\ana\\code\\shop", tool_input:{questions:[{question:"Keep the retry?"}]}}' | "$HOOK"; settle "$FAKE_LOG" TOAST
expect windows-toast "TOAST Claude needs you|shop: Keep the retry?" 1
same windows-project-from-backslash-path "$(entry .project cli-w)" "shop"
same windows-resume "$(entry .resume cli-w)" 'cd "C:\Users\ana\code\shop" && claude --resume cli-w'
unset NEEDS_YOU_POWERSHELL

# --- The inbox page ---------------------------------------------------------------

setup web
export FAKE_UNAME=Linux NEEDS_YOU_WINDOW_CMD="$WINDOW_REAL" NEEDS_YOU_OPEN_CMD="$WORK/opener"
export NEEDS_YOU_IDLE_CMD="echo not-for-the-page" NEEDS_YOU_LANG=pl
W="$HOME/.claude/needs-you/web"
check web-check "$("$WINDOW_REAL" --check; echo "exit=$?")" "exit=0" 1
fire "Which colour for the button?"; settle "$FAKE_LOG" BROWSER; settle "$W/data.js" "Which colour"
same web-page-installed "$(cmp -s "$ROOT/app/web/index.html" "$W/index.html" && echo same)" "same"
same web-fonts-installed "$(find "$W/fonts" -name '*.ttf' | wc -l | tr -d ' ')" "5"
check web-data-has-entry "$(cat "$W/data.js")" '"msg":"Which colour for the button?"' 1
check web-data-has-link "$(cat "$W/data.js")" '"link":"claude://claude.ai/epitaxy/local_test"' 1
check web-data-has-texts "$(cat "$W/data.js")" '"TITLE":"Claude czeka na Ciebie"' 1
check web-data-keeps-commands-out "$(cat "$W/data.js")" "not-for-the-page" 0
check web-data-is-a-call "$(head -c 9 "$W/data.js")" "needsYou(" 1
expect web-opened-once "BROWSER $W/index.html" 1
fire "And the border?"; settle "$W/data.js" "And the border?"; sleep 1
expect web-not-reopened-while-recent "BROWSER" 1
check web-data-updated "$(cat "$W/data.js")" '"msg":"And the border?"' 1
event UserPromptSubmit; settle "$W/data.js" '"done":true' 
check web-handled-refreshes "$(cat "$W/data.js")" '"done":true' 1
echo $(( $(date +%s) - 3 * 3600 )) > "$W/opened"
fire "A question hours later?"; settle "$W/data.js" "hours later"; sleep 1
expect web-reopened-after-a-while "BROWSER" 2
"$WINDOW_REAL" >/dev/null; settle_count "$FAKE_LOG" BROWSER 3
expect web-by-hand-opens "BROWSER" 3
# An entry older than a day and a broken file stay out of the page.
jq -nc '{ts:1,session:"local_old",msg:"ancient",done:false}' > "$HOME/.claude/needs-you/inbox/local_old.json"
echo '{not json' > "$HOME/.claude/needs-you/inbox/broken.json"
"$WINDOW_REAL" --refresh
check web-old-entry-left-out "$(cat "$W/data.js")" "ancient" 0
check web-survives-broken-file "$(cat "$W/data.js")" '"msg":"A question hours later?"' 1
# The page follows autopilot: switching it on and an answer it gives both
# rewrite data.js.
"$AP" on 23:59 >/dev/null
settle "$W/data.js" '"until_epoch":1'
check web-follows-autopilot-on "$(cat "$W/data.js")" '"until_epoch":null' 0
"$AP" off >/dev/null
settle "$W/data.js" '"until_epoch":null'
check web-follows-autopilot-off "$(cat "$W/data.js")" '"until_epoch":null' 1
"$AP" session on local_x "/review" >/dev/null
check title-keeps-its-slash "$("$AP" status)" "on for /review (local_x)" 1
settle "$W/data.js" '"title":"/review"'
check web-session-title-and-start "$(cat "$W/data.js")" '"local_x":{"title":"/review","since":' 1
"$AP" session off local_x >/dev/null

sleep 1   # background refreshes of the switches above are done
# A refresh reads the inbox only once it holds the lock: one that waited
# writes what is there when it runs, never an older snapshot.
: > "$W/data.lock"
"$WINDOW_REAL" --refresh & sleep 0.5
jq -nc --argjson ts "$(date +%s)" '{ts:$ts,session:"local_new",title:"t",msg:"Newer than the lock",done:false}' > "$HOME/.claude/needs-you/inbox/local_new.json"
rm -f "$W/data.lock"; wait
check web-waiting-refresh-is-newest "$(cat "$W/data.js")" "Newer than the lock" 1

# A full inbox: data goes to jq on stdin, so Windows' 32767-character command
# line is no limit (150 entries of about 600 characters here).
long=$(printf 'x%.0s' $(seq 1 500))
for i in $(seq 1 150); do
  jq -nc --argjson ts "$(date +%s)" --arg i "$i" --arg m "$long" '{ts:$ts,session:("cli-"+$i),title:"busy",msg:$m,
    resume:("cd \"C:\\Users\\someone\\projects\\inventory-client\" && claude --resume cli-"+$i),done:false}' \
    > "$HOME/.claude/needs-you/inbox/cli-$i.json"
done
"$WINDOW_REAL" --refresh
same web-full-inbox "$(sed 's/^needsYou(//; s/);$//' "$W/data.js" | jq '[.entries[] | select(.title == "busy")] | length')" "150"

# A browser that keeps xdg-open waiting does not hold up the notification.
printf '#!/bin/bash\nsleep 20\necho "SLOW $*" >> "$FAKE_LOG"\n' > "$WORK/slow-opener"; chmod +x "$WORK/slow-opener"
rm -f "$W/opened"
start=$(date +%s)
NEEDS_YOU_OPEN_CMD="$WORK/slow-opener" "$WINDOW_REAL" --notify
same web-open-does-not-wait "$(( $(date +%s) - start < 15 ))" "1"   # the opener takes 20 s
same web-opened-time-written-first "$([ -s "$W/opened" ] && echo yes)" "yes"
unset NEEDS_YOU_IDLE_CMD NEEDS_YOU_LANG NEEDS_YOU_OPEN_CMD
export NEEDS_YOU_WINDOW_CMD="$WORK/bin/window"

# The page loads nothing from outside its own folder.
external=$(grep -n -E '(src|href)="https?:|url\((["'"'"'])?https?:|@import' "$ROOT/app/web/index.html" | grep -v 'nobrainer-tech-flow' || true)
same web-no-external-assets "$external" ""
check web-renders-text-only "$(grep -c 'innerHTML\|outerHTML\|insertAdjacentHTML\|document.write' "$ROOT/app/web/index.html")" "0" 1

# --- Sessions that already wait, from the Linux desktop app's folder ---------------

setup linux-scan
export FAKE_UNAME=Linux
. "$ROOT/hooks/platform.sh"
app="$HOME/.config/Claude/claude-code-sessions/acct/org"
mkdir -p "$app" "$HOME/.claude/projects/-my-repo"
jq -nc --arg cwd "$HOME/my-repo" '{title:"linux | scan", cwd:$cwd, cliSessionId:"cli-l"}' > "$app/local_lin.json"
t=$(TZ=UTC ny_date_at $(( $(date +%s) - 120 )) '%Y-%m-%dT%H:%M:%S.000Z')
jq -nc --arg t "$t" '{type:"assistant",timestamp:$t,message:{content:[{type:"tool_use",id:"tu-l",name:"AskUserQuestion",input:{questions:[{question:"Linux question?"}]}}]}}' \
  > "$HOME/.claude/projects/-my-repo/cli-l.jsonl"
"$ROOT/bin/needs-you-scan" --no-open >/dev/null
same linux-scan-finds-session "$(entry .msg local_lin)" "Linux question?"
same linux-scan-title "$(entry .title local_lin)" "linux | scan"

if [ "$FAIL" = 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
