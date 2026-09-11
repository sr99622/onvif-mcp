# Hermes TUI: light blue session-title badge (local tweak)

Date applied: 2026-08-27
Hermes version at time of change: 0.20.6 (checkout in ~/.hermes/hermes-agent)

## What this is

The right-hand edge field of the TUI status bar — the session-title badge
(the short summary of the current session, e.g. a title auto-derived from
your conversation) — ships with a YELLOW background:

    'status-bar-session-title': 'bg:#FFD700 #1a1a2e bold',

This tweak changes it to light blue (#A9DFFF), keeping the dark navy text
(#1a1a2e) for contrast:

    'status-bar-session-title': 'bg:#A9DFFF #1a1a2e bold',

## Why an update can erase it

The change is a one-line edit to a core source file
(~/.hermes/hermes-agent/cli.py). `hermes update` / `git restore -- ui-tui`
style recovery paths and clean checkouts will revert it. There is no config
option for this specific badge: the skin system (config.yaml display.skin,
get_prompt_toolkit_style_overrides in hermes_cli/skin_engine.py) has no key
for status-bar-session-title, so no skin — including your poseidon skin —
can set it either way. It can only be done by editing cli.py.

## Where it lives

File:  ~/.hermes/hermes-agent/cli.py
       (class HermesCLI, method _build_tui_style_dict's base style dict,
        self._tui_style_base)

- The badge fragment is emitted with style class 'status-bar-session-title'
  in _right_align_status_title_fragments (look for:
      ("class:status-bar-session-title", badge), )
- The color is defined once in the style dict:
      'status-bar-session-title': 'bg:#FFD700 #1a1a2e bold',

NOTE on a second TUI: this checkout also ships an Ink/React TUI under
ui-tui/src/components/appChrome.tsx (StatusRule, right-edge label). That one
renders the title in accent color with NO background and is NOT what a
normal `hermes` session uses. Don't bother editing it for this tweak.

## Check if the change is still present

    grep -n "status-bar-session-title" ~/.hermes/hermes-agent/cli.py | tail -1

Expected if intact:   'status-bar-session-title': 'bg:#A9DFFF #1a1a2e bold',
Expected if reverted: 'status-bar-session-title': 'bg:#FFD700 #1a1a2e bold',

## Re-apply

Option A — apply the saved patch (preferred; works while the file is still
on the same base commit):

    cd ~/.hermes/hermes-agent
    git apply /home/stephen/docs/hermes-tui-session-title-light-blue.patch

If `git apply` fails because an update moved or reworded the surrounding
lines, use option B.

Option B — one-line sed (robust to line-number drift; only touches the
style definition, not the fragment-emission line):

    sed -i "s/'status-bar-session-title': 'bg:#FFD700 #1a1a2e bold'/'status-bar-session-title': 'bg:#A9DFFF #1a1a2e bold'/" ~/.hermes/hermes-agent/cli.py

Option C — if a future update changed the ORIGINAL default color too (i.e.
option B's pattern doesn't match), open cli.py and search for
status-bar-session-title (two hits: one emission, one style definition).
Set the style definition to exactly:

    'status-bar-session-title': 'bg:#A9DFFF #1a1a2e bold',

## After re-applying

Fully quit and relaunch your TUI session — a running hermes process holds
the old style dict in memory; re-rendering does not pick up source changes.

## Color alternatives (same line, same format)

    bg:#A9DFFF  -> current: light blue
    bg:#CFE8FF  -> paler / softer blue
    bg:#87CEEB  -> more saturated sky blue (already used for image-badge)
    bg:#FFD700  -> stock yellow (to revert)

Format is prompt_toolkit style syntax: 'bg:<background> <foreground> bold'.

## Backup copy of the original line (pre-tweak)

    'status-bar-session-title': 'bg:#FFD700 #1a1a2e bold',
