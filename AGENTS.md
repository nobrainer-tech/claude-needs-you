# AGENTS.md

Guide for agents and contributors working on this repository.

## What this is

Needs You is a macOS-only Claude Code plugin. One hook script does two jobs:

- **Popup.** When a session waits for the user (a question, a plan, a permission prompt), it shows a notification. In the Claude desktop app, a click opens that session.
- **Autopilot.** While switched on (`nb-autopilot on [HH:MM]`), a question is refused with an instruction to take the session's own recommended answer. Each decision is logged. Permission prompts and plans are never answered.

`README.md` is the user-facing description; read it before changing behavior.

## Layout

| Path | Purpose |
|---|---|
| `hooks/needs-you.sh` | The hook. Reads hook JSON on stdin; prints nothing or a `PreToolUse` deny. |
| `hooks/hooks.json` | Wires the script to `PreToolUse`, `Notification`, `PermissionRequest`, `PermissionDenied`. |
| `bin/nb-autopilot` | CLI: `on`, `off`, `status`, `report`, `doctor`. |
| `skills/autopilot/`, `skills/needs-you/` | Skills shipped with the plugin (switching autopilot; setup and troubleshooting). |
| `.claude-plugin/` | `plugin.json` and `marketplace.json`. |
| `tests/test.sh` | The test suite. |
| `.github/workflows/test.yml` | CI: syntax, JSON validity, tests (macOS), ShellCheck (Ubuntu). |

## Commands

Run these before opening a PR (they mirror CI):

```bash
bash -n hooks/needs-you.sh && bash -n bin/nb-autopilot && bash -n tests/test.sh
jq -e . .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json > /dev/null
bash tests/test.sh      # prints PASS per check and "ALL PASS" at the end
shellcheck hooks/needs-you.sh bin/nb-autopilot tests/test.sh
```

The tests put fake `terminal-notifier`, `osascript` and `open` first on `PATH` and use a temporary `HOME`. Nothing appears on screen and no real state is touched. Requires `jq`.

## Conventions

- Plain Bash with no dependencies beyond `jq` and macOS tools. No network calls.
- The hook must never break a session: on any failure it exits silently (`exit 0`). Keep that property when adding code.
- Autopilot fails closed: if a decision cannot be written to the log, do not answer; show the popup instead.
- Autopilot never runs more than 24 hours and never answers permission prompts or plan approvals.
- State lives in `~/.claude/needs-you/` (`autopilot.json`, `decisions.jsonl`) and marks in `~/Library/Caches/needs-you/`. Tests must use a temporary `HOME`, never the real one.
- Every behavior change needs a test in `tests/test.sh`. If you change what autopilot does, update the table in `README.md` and the `autopilot` skill; they describe the same rules.
- If you change the hook events or matchers, update `hooks/hooks.json` and the manual-install JSON in `README.md` together.
- The README states the number of checks in the suite; update it when the count changes.

## Gotchas

- The click-to-open link only works for desktop-app sessions (it relies on `CLAUDE_CODE_HOST_SESSION_ID`). Terminal sessions get a popup without a link.
- Identical messages from one session show once per two minutes; a newer question replaces the dialog on screen.
- `terminal-notifier` is optional; without it the hook falls back to an AppleScript dialog.
- Autopilot only tells the model what to do; it grants no permission and clicks nothing.
- Never switch autopilot on from automated code or tests against the real home folder; the skill allows it only when the user asks.
