# Changelog

## 0.5.0 (2026-11-25)

Needs You now works in Claude Code on macOS, Linux and Windows, and with
sessions in the terminal, not only in the Claude desktop app.

- **Terminal sessions.** A session of the Claude Code CLI or an IDE extension
  gets the name you gave it (`/rename`) or its transcript's summary as its
  title, and its row shows `cd <folder> && claude --resume <id>`. A click
  copies it (macOS window, page) or the dialog has a Copy button.
- **Linux and Windows.** A local inbox page in your browser, with the same
  look as the macOS window and no server or network; a native notification
  (`notify-send`, a Windows toast); the desktop app's data in `~/.config/Claude`
  or `%APPDATA%\Claude` (best effort).
- **Autopilot waits while you are there.** It answers only after
  `NEEDS_YOU_AUTOPILOT_IDLE_MINUTES` (default 5) without keyboard or mouse
  input. Idle time comes from `ioreg` (macOS), `xprintidle` or GNOME's idle
  monitor (Linux) and `GetLastInputInfo` (Windows). When the system cannot tell,
  autopilot does not answer. The steps only you may take are unchanged.
- **`nb-autopilot doctor`** checks what your system needs, says whether the
  idle time can be read, and prints the install command per system.
- New settings: `NEEDS_YOU_AUTOPILOT_IDLE_MINUTES`, `NEEDS_YOU_IDLE_SECONDS_CMD`,
  `NEEDS_YOU_WEB`, `NEEDS_YOU_REOPEN_MINUTES`, `NEEDS_YOU_APP_DIR`,
  `NEEDS_YOU_OPEN_CMD`, and the texts of the page and the Copy button (Polish
  included).
- Tests run on macOS, Ubuntu and Windows (Git Bash) in CI; a new suite,
  `tests/platform-test.sh`, covers the branches of each system with stand-ins.

## 0.3.0 (2026-11-16)

- Sessions that already wait are listed too, also after the Claude app
  restarts (`needs-you-scan`).

## 0.2.1 (2026-11-16)

- Texts and settings from `~/.claude/needs-you/settings.json`, with a built-in
  Polish translation.

## 0.2.0 (2026-11-16)

- One inbox window for every waiting session, with autopilot per session.

## 0.1.0 (2026-11-09)

- The popup hook and the night autopilot, with their tests.
