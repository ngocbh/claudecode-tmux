# CLAUDE.md

Guidance for Claude Code working in this repo.

## What this is

`claude-tmux` — a tiny, dependency-light tool that surfaces each Claude Code
session's run-state in the **tmux** status bar:
- a **window-tab tint** (orange=working, red=asking) for the session you're in, and
- **status-right chips** (`[win]name●`) for your *other* sessions.

State is driven by Claude Code **hooks** (not by scraping the TUI), so it's exact.
There is no application to build and no test framework — "running it" means
installing into tmux and watching the status bar.

## Layout

```
bin/claude-tmux-state    writer  — called by hooks; writes state + tints the window tab
bin/claude-tmux-status   reader  — called by tmux status-right via #(); renders chips, self-heals
tmux/claude-tmux.tmux    snippet template (@STATUS_CMD@ substituted at install)
install.sh / uninstall.sh idempotent, non-destructive (curl|sh self-bootstraps via git clone)
config.example           every tunable; copied to ~/.config/claude-tmux/config on install
Makefile                 `make install` / `make uninstall`
README.md                user-facing docs
```

## How it works (data flow)

1. Hooks in `~/.claude/settings.json` run `claude-tmux-state <state>`:
   `SessionStart`/`UserPromptSubmit`/`PostToolUse`→`running`, `Notification`→`asking`,
   `Stop`→`idle`, `SessionEnd`→`clear`.
2. `claude-tmux-state` writes `~/.cache/claude-tmux/pane-<id>` (keyed by `$TMUX_PANE`),
   file format **`<state>\t<window_id>`**, and sets `window-status-style` on its window
   (aggregate of all Claude panes in that window, priority asking > running > idle).
3. `claude-tmux-status` runs from `status-right` every second: reads all state files,
   prunes stale ones, and prints a chip per Claude **for sessions not currently attached**
   (the focused session is covered by the tab tint).

## Conventions / invariants — preserve these

- **POSIX sh only** (`#!/bin/sh`). No bashisms. Keep it portable (Linux + macOS).
- **State file format is `state<TAB>window_id`.** Always read the state with
  `cut -f1` and the window id with `cut -f2` (old single-field files are tolerated
  because `cut -f1` passes a delimiter-less line through). Don't `cat` the file as the state.
- **Installer must stay idempotent and non-destructive.** Three mechanisms — do not break:
  - tmux.conf edit is fenced by `# >>> claude-tmux >>>` / `# <<< claude-tmux <<<`
    markers; add only if absent; uninstall deletes the fenced block via `awk`.
  - hooks are merged with `jq` using `strip_ct` (drop any group whose command matches
    `claude-tmux-state`, then re-add) so re-install replaces instead of duplicating and
    never clobbers unrelated hooks.
  - the snippet's `run-shell` reads the live `status-right` and prepends our chip
    *into* it, guarded by a `case *claude-tmux-status*` check; since any
    `set -g status-right` in `~/.tmux.conf` runs before the appended snippet, a
    reload resets to the original first, so the chip never stacks. (Do NOT nest the
    original inside a user option like `#{@base}` — tmux won't re-expand a format
    that lands inside another option's value, so the original's `#{...}`/`%...`
    would render literally.)
- **Colors/icons are tunables**, overridable from `~/.config/claude-tmux/config`.
  The defaults are defined as `CT_*` shell vars at the top of the scripts.
  ⚠️ The window-tab colors (`CT_RUN_TAB`, `CT_ASK_TAB`) are defined in **both**
  `bin/claude-tmux-state` and `bin/claude-tmux-status` (the latter re-tints during
  self-heal). Keep the two in sync, and keep `config.example` listing every knob.
- **Window-tint recompute logic is duplicated**: `claude-tmux-state` section 2 and
  `claude-tmux-status`'s `retint_window()`. Change both together.
- **Self-healing prune** (in `claude-tmux-status`): a state file is dropped when its
  pane is gone OR its `pane_current_command` is a shell (Claude exited/crashed back to
  a prompt). The window is re-tinted using the stored window id. Don't switch to a
  positive "is it Claude?" match — matching the shell set is what makes it safe to never
  prune a live Claude (a running TUI never reports a bare shell as its pane command).

## tmux gotchas to remember

- `status-right #()` output is computed **once by the server and shared across all
  clients** — it is *not* per-client. That's why "show only other sessions" is done by
  excluding `tmux list-clients` sessions, not by asking "which client is this".
- `window-status-style` only renders for **inactive** windows (the active one uses
  `window-status-current-style`), so the tab tint shows exactly when a tab isn't focused.
  It also only takes effect if the user's `window-status-format` doesn't hardcode its own
  colors (the tmux default does respect the style).
- `status-interval` is integer seconds; **1 is the floor** (no sub-second polling). The
  writer calls `tmux refresh-client -S` for snappier same-client updates.

## Verifying a change

There is no CI. Before considering a change done:

- Syntax: `sh -n install.sh uninstall.sh bin/claude-tmux-*` (and `shellcheck` if available).
- **Sandbox the installer** so it never touches your real config or tmux server — run it
  against a throwaway `$HOME` and an isolated tmux socket:

  ```sh
  SB=$(mktemp -d); SOCK=$(mktemp -d)
  env -u TMUX HOME="$SB" TMUX_TMPDIR="$SOCK" sh ./install.sh
  # inspect $SB/.local/bin, $SB/.config/claude-tmux, $SB/.tmux.conf, $SB/.claude/settings.json
  env -u TMUX HOME="$SB" TMUX_TMPDIR="$SOCK" sh ./uninstall.sh
  rm -rf "$SB" "$SOCK"
  ```
  Check: re-running install doesn't duplicate markers/hooks; unrelated hooks survive;
  uninstall removes everything it added and nothing it didn't.
- Live check: install for real, run `claude` in a tmux pane, confirm the tab tints and a
  chip appears from another session.

## Docs upkeep

Any behavior change must update the affected docs in the same change: `README.md`
(user-facing), `config.example` (if you add/rename a `CT_*` tunable), and this file.

## Release

Public repo `github.com/ngocbh/claude-tmux`, branch **`main`** — the `curl | sh`
one-liner and `install.sh`'s bootstrap both reference `main`, so keep the default
branch named `main`.
