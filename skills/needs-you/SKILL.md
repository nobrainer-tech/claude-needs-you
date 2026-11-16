---
name: needs-you
description: "Set up, test or troubleshoot the Needs You window: one macOS window that lists every Claude Code session waiting for the owner (a question, a plan to approve, a permission prompt), opens the exact session on a click, greys out handled ones, and switches autopilot per session or for all. Use for needs-you, the inbox window, notify me when Claude asks, the window does not show, test the window, or change its text."
---

# Needs You

The hook `hooks/needs-you.sh` writes one entry per waiting session to
`~/.claude/needs-you/inbox/` and opens the window (`bin/needs-you-window`) if it
is not open. The window lists the entries, waiting ones first, and refreshes
itself every second. It never answers a permission prompt and never blocks a
session.

| When the session | The entry says |
|---|---|
| asks a question (`AskUserQuestion`) | the question |
| ends a turn with a question (desktop app) | that question |
| has a plan to approve (`ExitPlanMode`) | "A plan is waiting for your approval" |
| needs a permission | the prompt, or "Permission needed: <tool>" |
| had an action blocked | "Blocked: <tool>" |

Sessions that already waited before they ran again (a question left open when
the app was closed) come in through `needs-you-scan`: on `SessionStart`, when the
window opens and every 5 minutes. It lists questions from the last day.

An entry is handled (greyed, at the bottom) once the owner writes to that
session or one of its own tool calls finishes. Entries go after 24 hours or
with "Clear handled".

## Check the setup

Run `nb-autopilot doctor`. It needs `jq`; the window needs the Swift compiler of
the Xcode Command Line Tools (`xcode-select --install`, only the owner can run
it). Without the compiler, requests show as a `terminal-notifier` banner or a
dialog instead.

## Test it

Tell the owner first: a window appears on their screen. Then write the test
event to a file with the Write tool and pipe it to the hook:

```json
{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Test: this is the Needs You window."}]}}
```

```bash
"${CLAUDE_PLUGIN_ROOT}/hooks/needs-you.sh" < /path/to/event.json
```

The entry appears within a second (the first run builds the window, a few
seconds). The same message from the same session counts once per 2 minutes.
`needs-you-window` opens the window by hand.

## When it does not show

1. `nb-autopilot status`: while autopilot is on for all sessions or for this
   one, questions get an answer instead of an entry. That is intended.
2. `nb-autopilot doctor`: `jq` missing means the hook exits silently; a missing
   Swift compiler means banners or dialogs instead of the window.
3. Hooks load when a session starts. A session that was open before the plugin
   was installed needs a restart.
4. A terminal session is listed with its folder name and has no link.

## Change the text

Settings go in `~/.claude/needs-you/settings.json`, a JSON object of
`NEEDS_YOU_*` names and text. It is read on every request, so open sessions
pick a change up at once. `"NEEDS_YOU_LANG": "pl"` switches every text to the
built-in Polish (`texts/pl.json`); a single `NEEDS_YOU_*` text overrides it.
The `env` block of `~/.claude/settings.json` wins over the file but reaches
only sessions started after the change. The window keeps the texts it opened
with: after a change, close it and the next request opens it again. `NEEDS_YOU_IDLE_CMD` runs a
command of the owner's (for example a message to the phone) when a request
comes while the Mac has been idle for `NEEDS_YOU_IDLE_MINUTES` (default 10).

Do not edit the hook to answer permission prompts or to click for the owner.
For working unattended, use the `autopilot` skill: it answers questions,
approves plans and grants permissions, leaves owner-only steps to the owner and
logs every decision.
