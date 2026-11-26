# PowerShell for Windows: the idle time and the toast (sourced by
# hooks/platform.sh). Both scripts reach PowerShell on stdin, so no argument
# needs Windows quoting; tests/platform-test.sh parses them with PowerShell.
# shellcheck shell=bash

# Windows PowerShell (always there on Windows), else PowerShell 7. The script
# comes on stdin, so no argument needs Windows quoting.
ny_powershell() {
  local ps="${NEEDS_YOU_POWERSHELL:-}"
  [ -n "$ps" ] || ps=$(command -v powershell.exe 2>/dev/null || command -v pwsh 2>/dev/null)
  [ -n "$ps" ] || return 1
  "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command - 2>/dev/null | tr -d '\r'
}

# Milliseconds since the last input, through user32's GetLastInputInfo; nothing
# when the call fails. The C# is in a PowerShell single-quoted string, where
# its double quotes are plain characters (in a double-quoted one, \" would end
# the string: PowerShell escapes with a backtick). One line: PowerShell runs
# "-Command -" line by line. tests/platform-test.sh parses it with PowerShell.
ny_ps_idle_script() {
  cat <<'PS'
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class NyIdle { [StructLayout(LayoutKind.Sequential)] struct L { public uint s; public uint t; } [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref L l); public static long Ms() { L l = new L(); l.s = 8; if (!GetLastInputInfo(ref l)) return -1; return (long)unchecked((uint)Environment.TickCount - l.t); } }'; $m = [NyIdle]::Ms(); if ($m -ge 0) { $m }
PS
}

# The toast: Windows PowerShell's WinRT notifications; PowerShell 7 has no
# WinRT, so there it falls back to a tray balloon. Texts come from NY_TITLE and
# NY_BODY. tests/platform-test.sh parses it with PowerShell.
ny_ps_toast_script() {
  cat <<'PS'
$t=$env:NY_TITLE;$b=$env:NY_BODY;try{[void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime];[void][Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime];$x=New-Object Windows.Data.Xml.Dom.XmlDocument;$x.LoadXml('<toast><visual><binding template="ToastGeneric"><text>'+[Security.SecurityElement]::Escape($t)+'</text><text>'+[Security.SecurityElement]::Escape($b)+'</text></binding></visual></toast>');[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show([Windows.UI.Notifications.ToastNotification]::new($x))}catch{Add-Type -AssemblyName System.Windows.Forms;$n=New-Object System.Windows.Forms.NotifyIcon;$n.Icon=[System.Drawing.SystemIcons]::Information;$n.Visible=$true;$n.ShowBalloonTip(8000,$t,$b,'Info');Start-Sleep 9;$n.Dispose()}
PS
}
