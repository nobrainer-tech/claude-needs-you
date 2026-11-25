# What differs between macOS, Linux and Windows (Git Bash), in one place
# (sourced by the hook, nb-autopilot, needs-you-scan and needs-you-window).
#
#   NY_OS                macos, linux, windows or other (from uname -s)
#   NY_STAT              stat arguments that print "MTIME PATH" (GNU or BSD stat)
#   ny_date_at EPOCH FMT local time of EPOCH in FMT (strftime, without the +)
#   ny_epoch_of "YYYY-MM-DD HH:MM:SS"   that local time as epoch seconds
#   ny_idle_seconds      seconds since the last keyboard or mouse input; prints
#                        nothing when this system cannot tell (NY_IDLE_VIA names
#                        the source)
#   ny_app_dir           where the Claude desktop app keeps its data
#   ny_open TARGET       open a file or a claude:// link with the default app
#   ny_notify TITLE BODY [FILE]   a native notification (Linux, Windows)
#   ny_resume_cmd CWD ID the command that returns to a terminal session
#
# Every check is by feature or by uname, never by a macOS-only flag, so a
# missing tool degrades to "unknown" instead of breaking a session.
# shellcheck shell=bash disable=SC2034

case "$(uname -s 2>/dev/null)" in
  Darwin) NY_OS=macos ;;
  Linux) NY_OS=linux ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT) NY_OS=windows ;;
  *) NY_OS=other ;;
esac

# A native jq.exe under Git Bash ends its lines with CR LF. jq 1.7 has --binary
# for that; an older one is piped through tr. Git Bash also rewrites every
# argument of a native program that looks like a POSIX path, so a question or a
# title "/deploy now?" would reach jq as "C:/Program Files/Git/deploy now?".
# So the wrapper turns that rewriting off and converts only the arguments that
# name an existing file or folder itself (cygpath). Only on Windows shells, and
# only when jq.exe is there: without it `command -v jq` must keep failing.
case "${OSTYPE:-}" in
  msys*|cygwin*)
    if type -P jq >/dev/null 2>&1; then
      NY_JQ_BINARY=""
      command jq -b -n 1 >/dev/null 2>&1 && NY_JQ_BINARY=1
      ny_jq() { if [ -n "$NY_JQ_BINARY" ]; then command jq -b "$@"; else command jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; fi; }
      jq() {
        local a i=0 args=() at=() files=() conv=() k
        for a in "$@"; do
          case "$a" in /*) [ -e "$a" ] && { at+=("$i"); files+=("$a"); } ;; esac
          args+=("$a"); i=$(( i + 1 ))
        done
        if [ "${#files[@]}" -gt 0 ] && command -v cygpath >/dev/null 2>&1; then
          mapfile -t conv < <(cygpath -m -- "${files[@]}")
          for k in "${!at[@]}"; do args[at[k]]="${conv[k]:-${files[k]}}"; done
        fi
        MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' ny_jq "${args[@]}"
      }
    fi ;;
esac

# A whole number of minutes or seconds from a setting: "010" is ten (not
# octal), anything that is not digits is DEFAULT.
ny_int() {
  case "$1" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$(( 10#$1 ))" ;; esac
}

# GNU stat (Linux, Git Bash) or BSD stat (macOS).
if stat -c %Y / >/dev/null 2>&1; then NY_STAT=(-c '%Y %n'); else NY_STAT=(-f '%m %N'); fi

# A lock left by a writer that crashed: older than a minute.
ny_stale() {
  local m
  m=$(stat "${NY_STAT[@]}" "$1" 2>/dev/null) || return 1
  m="${m%% *}"
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(date +%s) - m )) -gt 60 ]
}

# A lock: LOCK created exclusively by bash itself (noclobber opens it with
# O_EXCL), not with mkdir. The mkdir of Ubuntu 26.04 (uutils) let two writers
# create the same folder at once in CI. The macOS window locks the same path
# with mkdir(2), which fails while this file exists, and the other way round.
# ny_lock LOCK TRIES PAUSE: 0 when taken; a lock older than a minute is taken over.
ny_lock() {
  local i rc had_c=""
  case "$-" in *C*) had_c=1 ;; esac
  for (( i = 0; i < $2; i++ )); do
    set -C
    { printf '%s\n' "$$" > "$1"; } 2>/dev/null
    rc=$?
    [ -n "$had_c" ] || set +C
    [ "$rc" = 0 ] && return 0
    ny_stale "$1" && ny_break_stale "$1"
    sleep "$3"
  done
  return 1
}
ny_unlock() { rm -f "$1" 2>/dev/null; }

# Take a stale lock away, safely when two writers find it stale at once: only
# the one holding LOCK.break may remove it, and only after it checked again,
# under LOCK.break, that LOCK is still stale. A writer that decided "stale"
# before another one replaced the lock finds a fresh lock and leaves it. A
# LOCK.break older than a minute is from a writer that crashed right there.
ny_break_stale() {
  local brk="$1.break" had_c="" rc
  case "$-" in *C*) had_c=1 ;; esac
  set -C
  { printf '%s\n' "$$" > "$brk"; } 2>/dev/null
  rc=$?
  [ -n "$had_c" ] || set +C
  if [ "$rc" != 0 ]; then
    ny_stale "$brk" && rm -f "$brk" 2>/dev/null
    return 1
  fi
  if ny_stale "$1"; then rm -f "$1" 2>/dev/null || rmdir "$1" 2>/dev/null; fi
  rm -f "$brk" 2>/dev/null
  return 0
}

# GNU or busybox date, else BSD date.
if date -d @0 +%s >/dev/null 2>&1; then
  ny_date_at() { date -d "@$1" "+$2"; }
  ny_epoch_of() { date -d "$1" +%s; }
else
  ny_date_at() { date -r "$1" "+$2"; }
  ny_epoch_of() { date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s; }
fi

# The PowerShell parts (Windows idle time and toast) live in their own file.
# shellcheck source=hooks/powershell.sh
. "${BASH_SOURCE[0]%/*}/powershell.sh"

NY_IDLE="" NY_IDLE_VIA=""
# Prints the seconds and also leaves them in NY_IDLE (when not in a subshell).
ny_idle_seconds() {
  local ms="" s=""
  NY_IDLE="" NY_IDLE_VIA=""
  if [ -n "${NEEDS_YOU_IDLE_SECONDS_CMD:-}" ]; then
    # Its first number; "4.000" is four seconds, "4.9" too.
    s=$(/bin/sh -c "$NEEDS_YOU_IDLE_SECONDS_CMD" </dev/null 2>/dev/null \
        | sed -n '1s/^[[:space:]]*\([0-9][0-9]*\)\(\.[0-9]*\)\{0,1\}[[:space:]]*$/\1/p')
    NY_IDLE_VIA=NEEDS_YOU_IDLE_SECONDS_CMD
  else
    case "$NY_OS" in
      macos)
        s=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {printf "%d", $NF / 1000000000; exit}')
        NY_IDLE_VIA=ioreg ;;
      linux)
        # Wayland: GNOME's own idle monitor. X11: xprintidle, then the same
        # monitor (GNOME on X11). Anything else cannot be read.
        if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v gdbus >/dev/null 2>&1; then
          ms=$(ny_mutter_idle_ms); NY_IDLE_VIA="gdbus (GNOME Mutter)"
        elif [ -n "${DISPLAY:-}" ]; then
          if command -v xprintidle >/dev/null 2>&1; then
            ms=$(xprintidle 2>/dev/null | sed -n '1s/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p'); NY_IDLE_VIA=xprintidle
          fi
          if [ -z "$ms" ] && command -v gdbus >/dev/null 2>&1; then
            ms=$(ny_mutter_idle_ms); NY_IDLE_VIA="gdbus (GNOME Mutter)"
          fi
        fi ;;
      windows)
        ms=$(ny_ps_idle_script | ny_powershell | sed -n '1s/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p'); NY_IDLE_VIA="PowerShell GetLastInputInfo" ;;
    esac
    case "$ms" in ''|*[!0-9]*) ;; *) s=$(( 10#$ms / 1000 )) ;; esac
  fi
  case "$s" in ''|*[!0-9]*) NY_IDLE_VIA=""; return 1 ;; esac
  s=$(( 10#$s ))
  NY_IDLE="$s"
  printf '%s\n' "$s"
}

ny_mutter_idle_ms() {
  gdbus call --session --timeout 2 --dest org.gnome.Mutter.IdleMonitor \
    --object-path /org/gnome/Mutter/IdleMonitor/Core \
    --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null \
    | sed -n 's/^(uint64 \([0-9][0-9]*\),)$/\1/p'
}

# Away: idle for at least MINUTES (a setting: "010" is ten, junk is DEFAULT).
# Unknown idle time is never away.
ny_owner_away() {
  local idle minutes
  minutes=$(ny_int "$1" "${2:-10}")
  idle=$(ny_idle_seconds) || return 1
  [ "$idle" -ge $(( minutes * 60 )) ]
}

# A Windows path (C:\Users\...) as Git Bash reads it; anything else unchanged.
ny_unix_path() {
  case "$1" in
    [A-Za-z]:[\\/]*) if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "${1//\\//}"; fi ;;
    *) printf '%s\n' "$1" ;;
  esac
}
# A path as a Windows program wants it (C:\...); unchanged elsewhere.
ny_native_path() {
  if [ "$NY_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

# The Claude desktop app's data. macOS is where the app keeps it; Windows and
# Linux follow the app's Electron default (%APPDATA%\Claude, ~/.config/Claude)
# and are best effort. NEEDS_YOU_APP_DIR sets it by hand.
ny_app_dir() {
  if [ -n "${NEEDS_YOU_APP_DIR:-}" ]; then ny_unix_path "$NEEDS_YOU_APP_DIR"; return; fi
  case "$NY_OS" in
    macos) printf '%s\n' "$HOME/Library/Application Support/Claude" ;;
    windows) printf '%s/Claude\n' "$(ny_unix_path "${APPDATA:-$HOME/AppData/Roaming}")" ;;
    *) printf '%s/Claude\n' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
  esac
}

# The program that opens files and links, or nothing.
ny_opener() {
  if [ -n "${NEEDS_YOU_OPEN_CMD:-}" ]; then printf '%s\n' "$NEEDS_YOU_OPEN_CMD"; return; fi
  case "$NY_OS" in
    macos) command -v open ;;
    linux|other) command -v xdg-open || command -v gio ;;
    windows) command -v explorer.exe || command -v cmd.exe ;;
  esac 2>/dev/null
}
ny_open() {
  local opener target="$1"
  opener=$(ny_opener) || return 1
  [ -n "$opener" ] || return 1
  case "$target" in *://*) ;; *) target=$(ny_native_path "$target") ;; esac
  case "$(basename "${opener//\\//}")" in
    gio) "$opener" open "$target" ;;
    cmd.exe) "$opener" //c start "" "$target" ;;
    explorer.exe) "$opener" "$target"; return 0 ;;   # explorer exits 1 even when it opened it
    *) "$opener" "$target" ;;
  esac
}

# A native notification: notify-send on Linux (a click on "Open" opens FILE
# where the notification server has actions), a toast on Windows (a tray
# balloon on PowerShell 7). macOS has its own window and banner in the hook.
ny_notify() {
  local title="$1" body="$2" file="${3:-}" act
  case "$NY_OS" in
    linux|other)
      command -v notify-send >/dev/null 2>&1 || return 1
      if [ -n "$file" ] && notify-send --help 2>/dev/null | grep -q -- '--action'; then
        act=$(notify-send -a "Needs You" --wait --action="open=${NEEDS_YOU_OPEN:-Open}" -- "$title" "$body" 2>/dev/null)
        [ "$act" = open ] && ny_open "$file"
        return 0
      fi
      notify-send -a "Needs You" -- "$title" "$body" ;;
    windows)
      ny_ps_toast_script | NY_TITLE="$title" NY_BODY="$body" ny_powershell >/dev/null ;;
    *) return 1 ;;
  esac
}

# "cd <folder> && claude --resume <id>". A plain folder goes in double quotes,
# which bash, zsh, cmd and PowerShell 7 all read the same way. A trailing
# backslash (C:\) would escape that closing quote in bash, so it gets a "." after
# it (C:\.), the same folder. Any other folder: on Windows a PowerShell command
# with the folder in single quotes, each kind of single quote doubled
# (PowerShell also takes the typographic ones as quotes); elsewhere a POSIX
# single-quoted one.
# shellcheck disable=SC1110,SC1111  # the typographic quotes here are meant
ny_resume_cmd() {
  local cwd="$1" id="$2" q
  [ -n "$id" ] || return 0
  case "$id" in *[!A-Za-z0-9_.-]*) return 0 ;; esac
  if [ -z "$cwd" ]; then printf 'claude --resume %s\n' "$id"; return; fi
  case "$cwd" in *\\) cwd="$cwd." ;; esac
  local special=""
  case "$cwd" in *[\"\$\`\'!%^\&\;\|\<\>]*) special=1 ;; esac
  for q in "“" "”" "„" "‘" "’" "‚" "‛"; do case "$cwd" in *"$q"*) special=1 ;; esac; done
  case "$special" in
    1)
      if [ "$NY_OS" = windows ]; then
        for q in "'" "‘" "’" "‚" "‛"; do cwd="${cwd//$q/$q$q}"; done
        printf "Set-Location -LiteralPath '%s'; claude --resume %s\n" "$cwd" "$id"
      else
        q="'"
        printf "cd '%s' && claude --resume %s\n" "${cwd//$q/$q\\$q$q}" "$id"
      fi ;;
    *) printf 'cd "%s" && claude --resume %s\n' "$cwd" "$id" ;;
  esac
}

# The inbox page in the browser instead of the Swift window: on Linux and
# Windows, and on a Mac with NEEDS_YOU_WEB=1.
ny_web_inbox() { [ "$NY_OS" != macos ] || [ "${NEEDS_YOU_WEB:-0}" = 1 ]; }
