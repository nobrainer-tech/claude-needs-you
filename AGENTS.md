# AGENTS.md

Guide for agents and contributors working on this repository. `README.md` is
the user-facing description; read it before changing behavior.

## What this is

Needs You is a Claude Code plugin for macOS. One hook script does two jobs:

- **Inbox window.** When a session waits for the user (a question, a plan to
  approve, a permission prompt), it writes an entry to an inbox, and one small
  window lists every waiting session, newest first. A click opens that session
  in the Claude desktop app. Answered entries grey out, drop to the bottom and
  disappear after a day.
- **Autopilot.** Per session (the checkbox in the window) or for all sessions
  until a set time (`nb-autopilot on [HH:MM]`), the hook answers for the user:
  a question gets the session's own recommended answer, a plan is approved and
  a permission is granted. It answers only while the user is away from the Mac
  (no input for `NEEDS_YOU_AUTOPILOT_IDLE_MINUTES`, default 5) and for a day at
  most. Requests that name an owner-only step (merge, push, deploy, publish,
  delete, archive, money, accounts, access, credentials, production) always go
  to the window. Every decision is logged before it is made.

## Layout

| Path | Purpose |
|---|---|
| `hooks/needs-you.sh` | The hook. Reads hook JSON on stdin; writes inbox entries, opens the window; prints nothing or a `PreToolUse` deny. |
| `hooks/autopilot.sh` | Autopilot part, sourced by the hook. Holds `OWNER_ONLY`, the regex of steps autopilot never decides. |
| `hooks/settings.sh` | Fills `NEEDS_YOU_*` variables from `~/.claude/needs-you/settings.json` and `texts/<lang>.json`. |
| `hooks/session-info.sh` | Title, sidebar section, project and link of a desktop-app session. |
| `hooks/hooks.json` | Wires the hook to `PreToolUse`, `Notification`, `PermissionRequest`, `PermissionDenied`, `UserPromptSubmit`, `PostToolUse`, `SessionStart`, `SessionEnd`. |
| `bin/nb-autopilot` | CLI: `on [HH:MM]`, `off`, `session on\|off ID`, `status`, `report`, `doctor`. |
| `bin/needs-you-window` | Builds the window once per source version into `~/Library/Caches/needs-you/bin/` and starts it (`--check`, `--build`, `--snapshot OUT.png`). |
| `bin/needs-you-scan` | Finds sessions that already wait (from transcripts and the app's own marks), also after an app restart. |
| `app/*.swift` | The window: Swift and AppKit, no dependencies. `app/fonts`, `app/img` are its assets. |
| `texts/` | Built-in translations (`pl.json`). |
| `skills/autopilot/`, `skills/needs-you/` | Skills shipped with the plugin. |
| `.claude-plugin/` | `plugin.json` and `marketplace.json`; the version lives in both. |
| `tests/` | `test.sh` (inbox), `autopilot-test.sh`, `scan-test.sh`, `window-test.sh`; shared set-up in `lib.sh`. |
| `.github/workflows/test.yml` | CI: syntax, JSON, all four suites on macOS, ShellCheck on Ubuntu. |

## Commands

Run these before opening a PR (they mirror CI):

```bash
for f in hooks/*.sh bin/nb-autopilot bin/needs-you-window bin/needs-you-scan tests/*.sh; do bash -n "$f" || exit 1; done
jq -e . .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json > /dev/null
bash tests/test.sh
bash tests/autopilot-test.sh
bash tests/scan-test.sh
bash tests/window-test.sh window.png   # builds the window, renders the inbox to a PNG; look at it
shellcheck -x hooks/*.sh bin/nb-autopilot bin/needs-you-window bin/needs-you-scan tests/*.sh
```

The tests put stand-ins for the window, `terminal-notifier`, `osascript`,
`open` and `ioreg` first on `PATH` and use a temporary `HOME`. Nothing appears
on screen and no real state is touched. They need `jq`; the window test needs
the Xcode Command Line Tools.

## Conventions

- Plain Bash plus `jq` and macOS tools; the window is plain Swift. No network
  calls, no daemon.
- The hook must never break a session: on any failure it exits silently
  (`exit 0`). Keep that property when adding code.
- Autopilot fails closed: no log record, no decision. It never answers a request
  that matches `OWNER_ONLY`; widen that list rather than narrow it.
- State lives in `~/.claude/needs-you/` (`inbox/`, `autopilot.json`,
  `decisions.jsonl`, `settings.json`) and builds in `~/Library/Caches/needs-you/`.
  Tests use a temporary `HOME`, never the real one.
- Every behavior change needs a test. If you change what autopilot answers,
  update together: `hooks/autopilot.sh`, the "What autopilot answers" section of
  `README.md`, `skills/autopilot/SKILL.md` and the window's hint text.
- If you change hook events or matchers, update `hooks/hooks.json` and the
  "How it works" and manual-install parts of `README.md` together.
- A new user-facing text gets a `NEEDS_YOU_*` variable, an English default, an
  entry in `texts/pl.json` and a line in the README "Settings" section.
- The README states the number of checks per suite; update it when it changes.
- A release bumps the version in `.claude-plugin/plugin.json` and both places in
  `.claude-plugin/marketplace.json`. Users get it with
  `claude plugin marketplace update claude-needs-you` and
  `claude plugin update needs-you@claude-needs-you`; open sessions keep the old
  hook until they restart.

## Gotchas

- Click-to-open works only for desktop-app sessions (`CLAUDE_CODE_HOST_SESSION_ID`);
  terminal sessions are listed with their folder and no link.
- The same request from one session counts once per two minutes; a newer
  question from a session replaces its older entry.
- A session keeps the environment it started with; `settings.json` in
  `~/.claude/needs-you/` is read on every request, so prefer it for settings.
- The window is rebuilt only when `app/*.swift` changes (the cache key is their
  hash). A running window keeps the plugin version that started it; after an
  update, quit it and the next request opens the new one.
- Autopilot only tells the model what to do through a `PreToolUse` deny or a
  permission decision; for owner-only steps it does nothing at all.
- Never switch autopilot on from automated code or tests against the real home
  folder; the skill allows it only when the user asks.
