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
bin/claude-tmux-jump     click handler — invoked from the MouseDown1Status binding (clickable chips); switches to a chip's session/window
tmux/claude-tmux.tmux    snippet template (@STATUS_CMD@ / @CLICK_CONF@ substituted at install)
tmux/claude-tmux-click.tmux  clickable-chip bindings template (@JUMP_CMD@ substituted); sourced by the snippet only when CT_CLICKABLE is on
install.sh / uninstall.sh idempotent, non-destructive (curl|sh self-bootstraps via git clone)
config.example           every tunable; copied to ~/.config/claude-tmux/config on install
Makefile                 `make install` / `make uninstall`
README.md                user-facing docs
```

## How it works (data flow)

1. Hooks in `~/.claude/settings.json` run `claude-tmux-state <state>`:
   `SessionStart`/`UserPromptSubmit`/`PostToolUse`→`running`, `Notification`→`asking`,
   `Stop`→`idle`, `SessionEnd`→`clear`. **The `Notification`→`asking` mapping is
   filtered** (section 0 of `claude-tmux-state`): Claude Code fires `Notification`
   for *both* a real prompt and the 60s "waiting for your input" idle timeout, so a
   `Notification` is dropped when the pane is already `idle` (a stopped Claude can't
   be blocked on you) or when the payload message says it's just waiting for input.
   Without this, a finished, unattended session falsely flips to red ~60s after it
   stops. Don't naively re-map `Notification`→`asking` without keeping this guard.
2. `claude-tmux-state` writes `~/.cache/claude-tmux/pane-<id>` (keyed by `$TMUX_PANE`),
   file format **`<state>\t<window_id>`**, and sets `window-status-style` on its window
   (aggregate of all Claude panes in that window, priority asking > running > idle).
3. `claude-tmux-status` runs from `status-right` every second: reads all state files,
   prunes stale ones, and prints a chip per Claude **for sessions not currently attached**
   (the focused session is covered by the tab tint).
4. **Clickable chips (opt-in, `CT_CLICKABLE`).** When enabled, `claude-tmux-status`
   wraps each chip in a tmux range tagged with the chip's window id —
   `#[range=user|ct<window_id>]…#[norange]` — and the snippet sources
   `claude-tmux-click.tmux`, which does (a) `set -g mouse on` and (b) binds
   **`MouseDown1Status`** (see the invariant below for why not `StatusRight`) to an
   `if-shell` that jumps when the click landed on a `ct@…` chip and otherwise runs
   tmux's default `select-window -t =`. On a chip click tmux sets
   `#{mouse_status_range}` to the tag (e.g. `ct@5`); `claude-tmux-jump` strips `ct`,
   resolves the window id to its session, and does `switch-client` + `select-window`.
   Default off; off = byte-for-byte the old behavior (no ranges emitted, click file
   not sourced, no mouse/binding touched).

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
- **Clickable chips are opt-in and must stay non-destructive.** `CT_CLICKABLE`
  (default empty = off) is read in two places: `claude-tmux-status` (decides
  whether to emit the `#[range=user|ct<window_id>]` wrapper) and the snippet's
  `if-shell` gate (sources the config and, only when enabled, `source-file`s
  `claude-tmux-click.tmux`, which runs `set -g mouse on` + binds the click). Both
  gate on the **same truthiness set** `1|true|yes|on` — so `CT_CLICKABLE=0`
  disables (don't switch either to a bare `-n`/non-empty test, which would read
  `0` as on). Don't move the mouse-enable outside the toggle: flipping a user's
  `mouse` setting unprompted is the one intrusive thing we promised not to do by
  default.
- **Chip range encoding is `ct<window_id>`** (e.g. `ct@5`). The reader builds it
  from the live pane map's window id; `claude-tmux-jump` strips the `ct` tag and
  trusts the remaining `@N` as a server-unique window id (so it resolves the
  session even from another one — don't switch to a `session:window` string,
  which breaks on colons in session names and on renames).
- **Bind `MouseDown1Status`, NOT `MouseDown1StatusRight`** — even though the chips
  render in `status-right`. tmux fires `MouseDown1Status` for a click on *any*
  status range — our chips (`range=user|ct@…`) AND the default window tabs
  (`range=window`) — and never the region-specific `StatusRight`/`StatusLeft` key.
  (Verified empirically: bind all four `MouseDown1Status*` keys to log
  `#{mouse_status_range}`; a chip click logs `KEY=Status msr=[ct@…]`.) Because we
  share the key with tmux's tab-click default, the binding **must** branch:
  `if-shell -F '#{m:ct@*,#{mouse_status_range}}'` → jump, else `select-window -t =`.
  Never bind `MouseDown1Status` to a bare jump — that silently kills clicking your
  own window tabs. The `select-window -t =` fallback (`=` = clicked window) only
  resolves as a native tmux command in the key's command queue, so it must stay in
  the binding, not inside the jump subprocess.
- **The click bindings live in their own sourced file (`claude-tmux-click.tmux`),
  not inside a `run-shell`.** tmux format-expands `#{…}` in a `run-shell` argument
  before the shell runs, which would blow away `#{mouse_status_range}`/`#{client_name}`
  at bind time (the symptom: `list-keys` shows `claude-tmux-jump ` with no arg).
  Building them in a plain sourced file keeps the formats verbatim until a click.
  `@JUMP_CMD@` is substituted into that file (absolute path, so it works regardless
  of PATH in tmux's shell); `@CLICK_CONF@` is substituted into the snippet's
  `source-file`. The snippet gates the source with `if-shell` reading `CT_CLICKABLE`
  from config. Uninstall restores the default `MouseDown1Status select-window -t =`
  but leaves the `mouse` option as the user had it.
- **Window-tint recompute logic is duplicated**: `claude-tmux-state` section 2 and
  `claude-tmux-status`'s `retint_window()`. Change both together.
- **Self-healing prune** (in `claude-tmux-status`): a state file is dropped when its
  pane is gone OR its `pane_current_command` is a shell **and** the pane's process
  tree has no non-shell descendants. The shell-name check alone is wrong for builds
  that launch Claude via a wrapper script (e.g. `bash …/claude --…`, common on
  managed installs): `pane_current_command` reports `bash` for the lifetime of the
  session, so without the descendant check the reader prunes every state file on the
  very next tick. The descendant check uses a single cached `ps -eo pid,ppid,comm`
  pass (lazy — only built when at least one pane looks idle) and walks the pane
  subtree skipping intermediate shell wrappers. The window is re-tinted using the
  stored window id. Don't switch to a positive "is it Claude?" match — matching the
  shell set is what makes it cheap, and the descendant probe is what makes it safe.

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
- `#[range=...]` directives **are honored from `#()` command output**, not just from
  static format strings (same parser as the `#[fg=...]` we already emit) — but range
  *position* tracking from `#()` was buggy in old tmux; it's reliable on **3.2+**.
  That's the floor for clickable chips. `#{mouse_status_range}` (the user range under
  the click) and the `StatusLeft`/`StatusRight` mouse keys are all 3.0+.
- **Clicks need `mouse on`.** With mouse off tmux never sees status clicks (the
  terminal handles selection), so the binding is inert — that's why clickable chips
  are gated behind a toggle that also enables mouse.
- **A status range click fires `MouseDown1Status`, not the region key.** This is the
  single most important clickable-chips fact (see the invariant above): the chips are
  in `status-right`, yet the click is delivered on `MouseDown1Status`, the same key as
  the window tabs. So the binding is shared and must branch (jump vs. default
  `select-window`). To debug which key/range a click produces, temporarily bind all of
  `MouseDown1Status{,Left,Right,Default}` to `run-shell "printf 'KEY=… msr=[%s]\n'
  '#{mouse_status_range}' >> /tmp/log"` and click — but **restore the default
  `bind -n MouseDown1Status select-window -t =` afterward**, or you've broken tab
  clicking. Verify the real binding with `tmux list-keys -T root MouseDown1Status` —
  the stored command must still show `#{mouse_status_range}` (if it shows an empty arg,
  a `run-shell` ate the format; keep the bindings in the plain sourced file).

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
  chip appears from another session. For clickable chips: set `CT_CLICKABLE=1`, reload
  tmux, and confirm a left-click on a chip switches to that session's window (and that
  the default window-tab click still works).

## Docs upkeep

Any behavior change must update the affected docs in the same change: `README.md`
(user-facing), `config.example` (if you add/rename a `CT_*` tunable), and this file.

## Release

Public repo `github.com/ngocbh/claude-tmux`, branch **`main`** — the `curl | sh`
one-liner and `install.sh`'s bootstrap both reference `main`, so keep the default
branch named `main`.
