# AGENTS.md

Guide for agents and contributors working on this repository. `README.md` is
the user-facing description; read it before changing behavior.

## What this is

Needs You is a Claude Code plugin for macOS, Linux and Windows (Git Bash), for
sessions of the Claude desktop app and of the terminal. One hook script does
two jobs:

- **Inbox window.** When a session waits for the user (a question, a plan to
  approve, a permission prompt), it writes an entry to an inbox, and one small
  window lists every waiting session, newest first: a native Swift window on
  macOS, a local page in the browser on Linux and Windows. A click opens a
  desktop-app session; a terminal session's row copies its
  `cd <folder> && claude --resume <id>`. Answered entries grey out, drop to the bottom and
  disappear after a day.
- **Autopilot.** Per session (the checkbox in the window) or for all sessions
  until a set time (`nb-autopilot on [HH:MM]`), the hook answers for the user:
  a question gets the session's own recommended answer, a plan is approved and
  a permission is granted. It answers only while the user is away from the Mac
  (no input for `NEEDS_YOU_AUTOPILOT_IDLE_MINUTES`, default 5) and for a day at
  most. When the idle time cannot be read, it counts as present and autopilot
  does not answer. Requests that name an owner-only step (merge, push, deploy, publish,
  delete, archive, money, accounts, access, credentials, production) always go
  to the window. Every decision is logged before it is made.

## Layout

| Path | Purpose |
|---|---|
| `hooks/needs-you.sh` | The hook. Reads hook JSON on stdin; writes inbox entries, opens the window; prints nothing or a `PreToolUse` deny. |
| `hooks/autopilot.sh` | Autopilot part, sourced by the hook. Holds `OWNER_ONLY`, the regex of steps autopilot never decides. |
| `hooks/platform.sh` | Everything that differs per system: OS, GNU/BSD `stat` and `date`, idle time, the app's data folder, opening, notifications, the resume command, locks (`ny_lock`). |
| `hooks/powershell.sh` | Windows PowerShell scripts (idle time, toast), sent on stdin. |
| `hooks/settings.sh` | Fills `NEEDS_YOU_*` variables from `~/.claude/needs-you/settings.json` and `texts/<lang>.json`. |
| `hooks/session-info.sh` | Title, sidebar section, project and link of a desktop-app session. |
| `hooks/hooks.json` | Wires the hook to `PreToolUse`, `Notification`, `PermissionRequest`, `PermissionDenied`, `UserPromptSubmit`, `PostToolUse`, `SessionStart`, `SessionEnd`. |
| `bin/nb-autopilot` | CLI: `on [HH:MM]`, `off`, `session on\|off ID`, `status`, `report`, `doctor`. |
| `bin/needs-you-window` | macOS: builds the Swift window once per source version into `~/Library/Caches/needs-you/bin/` and starts it. Linux, Windows (or `NEEDS_YOU_WEB=1`): installs the page to `~/.claude/needs-you/web/` and rewrites its `data.js` (`--refresh`). |
| `bin/needs-you-scan` | Finds sessions that already wait (from transcripts and the app's own marks), also after an app restart. |
| `app/*.swift` | The macOS window: Swift and AppKit, no dependencies. |
| `app/web/index.html` | The page for Linux and Windows: no server, no network, reloads `data.js` every two seconds. |
| `app/fonts`, `app/img` | Assets of both. |
| `texts/` | Built-in translations (`pl.json`). |
| `skills/autopilot/`, `skills/needs-you/` | Skills shipped with the plugin. |
| `.claude-plugin/` | `plugin.json` and `marketplace.json`; the version lives in both. |
| `tests/` | `test.sh` (inbox), `autopilot-test.sh`, `scan-test.sh`, `platform-test.sh`, `window-test.sh` (macOS); shared set-up in `lib.sh`. |
| `CHANGELOG.md` | What each release changed for users. |
| `.github/workflows/test.yml` | CI: syntax, JSON and the suites on macOS, Ubuntu and Windows; the window test on macOS; ShellCheck on Ubuntu. |

## Commands

Run these before opening a PR (they mirror CI):

```bash
for f in hooks/*.sh bin/nb-autopilot bin/needs-you-window bin/needs-you-scan tests/*.sh; do bash -n "$f" || exit 1; done
jq -e . .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json texts/*.json > /dev/null
bash tests/test.sh
bash tests/autopilot-test.sh
bash tests/scan-test.sh
bash tests/platform-test.sh            # Linux, Windows and macOS branches
bash tests/window-test.sh window.png   # macOS: builds the window, renders the inbox to a PNG; look at it
shellcheck -x hooks/*.sh bin/nb-autopilot bin/needs-you-window bin/needs-you-scan tests/*.sh
```

The tests put stand-ins for the window, the notifiers, `open`, `pbcopy`, the
idle tools and `uname` first on `PATH` and use a temporary `HOME`, so one
machine can test every system's branch. Nothing appears on screen and no real
state is touched. They need `jq`; the window test needs the Xcode Command Line
Tools.

## Conventions

- Plain Bash plus `jq`; the macOS window is plain Swift, the page plain HTML.
  No network calls, no server, no daemon.
- Anything that differs per system goes through `hooks/platform.sh`, checked
  by feature or `uname`, never by a macOS-only flag (`stat -f`, `date -j`,
  `date -r`). A missing tool degrades to "unknown", never to a broken session.
- Lock with `ny_lock`/`ny_unlock` (an exclusive create by bash), not `mkdir`:
  `mkdir` let two writers take the same lock on Ubuntu 26.04.
- The hook must never break a session: on any failure it exits silently
  (`exit 0`). Keep that property when adding code.
- Autopilot fails closed: no log record, no decision. It never answers a request
  that matches `OWNER_ONLY`; widen that list rather than narrow it.
- State lives in `~/.claude/needs-you/` (`inbox/`, `autopilot.json`,
  `decisions.jsonl`, `settings.json`, `web/`) and macOS builds in
  `~/Library/Caches/needs-you/`.
  Tests use a temporary `HOME`, never the real one.
- Every behavior change needs a test. If you change what autopilot answers,
  update together: `hooks/autopilot.sh`, the "What autopilot answers" section of
  `README.md`, `skills/autopilot/SKILL.md` and the hint text of the window and
  the page.
- If you change hook events or matchers, update `hooks/hooks.json` and the
  "How it works" and manual-install parts of `README.md` together.
- A new user-facing text gets a `NEEDS_YOU_*` variable, an English default, an
  entry in `texts/pl.json` and a line in the README "Settings" section.
- The README states the number of checks per suite; update it when it changes.
- A release bumps the version in `.claude-plugin/plugin.json` and both places in
  `.claude-plugin/marketplace.json`, and adds a `CHANGELOG.md` entry. Users get it with
  `claude plugin marketplace update claude-needs-you` and
  `claude plugin update needs-you@claude-needs-you`; open sessions keep the old
  hook until they restart.

## Gotchas

- Click-to-open works only for desktop-app sessions (`CLAUDE_CODE_HOST_SESSION_ID`);
  a terminal session gets its `/rename` name or transcript summary and a resume
  command to copy.
- On Windows the hook needs Claude Code to run it in Git Bash; the `jq` wrapper
  in `platform.sh` stops MSYS from rewriting text that looks like a path.
- The page cannot run commands or tell whether it is still open: its Autopilot
  buttons copy the `nb-autopilot` command, and a request reopens it after
  `NEEDS_YOU_REOPEN_MINUTES`.
- Linux and Windows have passed CI with stand-ins only; notifications, the page
  and idle detection were not yet tried on a real desktop there.
- The same request from one session counts once per two minutes; a newer
  question from a session replaces its older entry.
- A session keeps the environment it started with; `settings.json` in
  `~/.claude/needs-you/` is read on every request, so prefer it for settings.
- The macOS window is rebuilt only when `app/*.swift` changes (the cache key is their
  hash). A running window keeps the plugin version that started it; after an
  update, quit it and the next request opens the new one.
- Autopilot only tells the model what to do through a `PreToolUse` deny or a
  permission decision; for owner-only steps it does nothing at all.
- Never switch autopilot on from automated code or tests against the real home
  folder; the skill allows it only when the user asks.
