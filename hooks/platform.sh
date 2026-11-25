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
# argument of a native program that looks like a POSIX path, so a question
# "/deploy now?" would reach jq as "C:/Program Files/Git/deploy now?". A jq
# call with -n reads no file, so its arguments are all text and pass unchanged.
# Only on Windows shells.
case "${OSTYPE:-}" in
  msys*|cygwin*)
    NY_JQ_BINARY=""
    command jq -b -n 1 >/dev/null 2>&1 && NY_JQ_BINARY=1
    ny_jq() { if [ -n "$NY_JQ_BINARY" ]; then command jq -b "$@"; else command jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; fi; }
    jq() {
      local a
      for a in "$@"; do
        case "$a" in --*) ;; -*n*) MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' ny_jq "$@"; return ;; esac
      done
      ny_jq "$@"
    } ;;
esac

# GNU stat (Linux, Git Bash) or BSD stat (macOS).
if stat -c %Y / >/dev/null 2>&1; then NY_STAT=(-c '%Y %n'); else NY_STAT=(-f '%m %N'); fi

# A lock folder left by a writer that crashed: older than a minute.
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
    ny_stale "$1" && { rm -f "$1" 2>/dev/null || rmdir "$1" 2>/dev/null; }
    sleep "$3"
  done
  return 1
}
ny_unlock() { rm -f "$1" 2>/dev/null; }

# GNU or busybox date, else BSD date.
if date -d @0 +%s >/dev/null 2>&1; then
  ny_date_at() { date -d "@$1" "+$2"; }
  ny_epoch_of() { date -d "$1" +%s; }
else
  ny_date_at() { date -r "$1" "+$2"; }
  ny_epoch_of() { date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s; }
fi

# Windows PowerShell (always there on Windows), else PowerShell 7. The script
# comes on stdin, so no argument needs Windows quoting.
ny_powershell() {
  local ps="${NEEDS_YOU_POWERSHELL:-}"
  [ -n "$ps" ] || ps=$(command -v powershell.exe 2>/dev/null || command -v pwsh 2>/dev/null)
  [ -n "$ps" ] || return 1
  "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command - 2>/dev/null | tr -d '\r'
}

NY_PS_IDLE='Add-Type -TypeDefinition "using System;using System.Runtime.InteropServices;public static class NyIdle{[StructLayout(LayoutKind.Sequential)]struct L{public uint s;public uint t;}[DllImport(\"user32.dll\")]static extern bool GetLastInputInfo(ref L l);public static uint Ms(){L l=new L();l.s=8;if(!GetLastInputInfo(ref l))return 0;return (uint)Environment.TickCount-l.t;}}"; [NyIdle]::Ms()'

NY_IDLE="" NY_IDLE_VIA=""
# Prints the seconds and also leaves them in NY_IDLE (when not in a subshell).
ny_idle_seconds() {
  local ms="" s=""
  NY_IDLE="" NY_IDLE_VIA=""
  if [ -n "${NEEDS_YOU_IDLE_SECONDS_CMD:-}" ]; then
    s=$(/bin/sh -c "$NEEDS_YOU_IDLE_SECONDS_CMD" </dev/null 2>/dev/null | tr -dc '0-9')
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
            ms=$(xprintidle 2>/dev/null | tr -dc '0-9'); NY_IDLE_VIA=xprintidle
          fi
          if [ -z "$ms" ] && command -v gdbus >/dev/null 2>&1; then
            ms=$(ny_mutter_idle_ms); NY_IDLE_VIA="gdbus (GNOME Mutter)"
          fi
        fi ;;
      windows)
        ms=$(printf '%s\n' "$NY_PS_IDLE" | ny_powershell | tr -dc '0-9'); NY_IDLE_VIA="PowerShell GetLastInputInfo" ;;
    esac
    [ -n "$ms" ] && s=$(( ms / 1000 ))
  fi
  case "$s" in ''|*[!0-9]*) NY_IDLE_VIA=""; return 1 ;; esac
  NY_IDLE="$s"
  printf '%s\n' "$s"
}

ny_mutter_idle_ms() {
  gdbus call --session --timeout 2 --dest org.gnome.Mutter.IdleMonitor \
    --object-path /org/gnome/Mutter/IdleMonitor/Core \
    --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null \
    | sed -n 's/^(uint64 \([0-9][0-9]*\),)$/\1/p'
}

# Away: idle for at least MINUTES. Unknown idle time is never away.
ny_owner_away() {
  local idle
  idle=$(ny_idle_seconds) || return 1
  [ "$idle" -ge $(( $1 * 60 )) ] 2>/dev/null
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
      NY_TITLE="$title" NY_BODY="$body" ny_powershell >/dev/null <<'PS'
$t=$env:NY_TITLE;$b=$env:NY_BODY;try{[void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime];[void][Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime];$x=New-Object Windows.Data.Xml.Dom.XmlDocument;$x.LoadXml('<toast><visual><binding template="ToastGeneric"><text>'+[Security.SecurityElement]::Escape($t)+'</text><text>'+[Security.SecurityElement]::Escape($b)+'</text></binding></visual></toast>');[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show([Windows.UI.Notifications.ToastNotification]::new($x))}catch{Add-Type -AssemblyName System.Windows.Forms;$n=New-Object System.Windows.Forms.NotifyIcon;$n.Icon=[System.Drawing.SystemIcons]::Information;$n.Visible=$true;$n.ShowBalloonTip(8000,$t,$b,'Info');Start-Sleep 9;$n.Dispose()}
PS
      ;;
    *) return 1 ;;
  esac
}

# "cd <folder> && claude --resume <id>": works in bash, zsh, cmd and PowerShell
# 7. The folder is in double quotes, or single quotes when it holds a character
# a POSIX shell would expand inside double quotes.
ny_resume_cmd() {
  local cwd="$1" id="$2" sq="'"
  [ -n "$id" ] || return 0
  case "$id" in *[!A-Za-z0-9_.-]*) return 0 ;; esac
  if [ -z "$cwd" ]; then printf 'claude --resume %s\n' "$id"; return; fi
  case "$cwd" in
    *[\"\$\`!]*) printf "cd '%s' && claude --resume %s\n" "${cwd//$sq/$sq\\$sq$sq}" "$id" ;;
    *) printf 'cd "%s" && claude --resume %s\n' "$cwd" "$id" ;;
  esac
}

# The inbox page in the browser instead of the Swift window: on Linux and
# Windows, and on a Mac with NEEDS_YOU_WEB=1.
ny_web_inbox() { [ "$NY_OS" != macos ] || [ "${NEEDS_YOU_WEB:-0}" = 1 ]; }
