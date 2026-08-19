# CLAUDE.md

Guidance for coding agents working in this repo.

## What this is

`claude-tmux` — a tiny, dependency-light tool that surfaces each Claude Code or
Codex CLI session's run-state in the **tmux** status bar:
- a **window-tab tint** (orange=working, red=asking) for the session you're in, and
- **status-right chips** (`[win]name●`) for your *other* sessions.

State is driven by both products' **hooks** (not by scraping either TUI). The
historical `claude-tmux` executable, config, and cache names remain unchanged
for backward compatibility. There is no application to build; the shell tests
cover hook installation/state handling, while a full live check means
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
tests/test-install.sh     sandboxed Claude + Codex install/uninstall and failure-safety coverage
tests/test-state.sh       source-aware writer regression coverage
tests/test-tmux-integration.sh  isolated real-tmux writer/reader integration coverage
Makefile                 `make install` / `make uninstall`
README.md                user-facing docs
```

## How it works (data flow)

1. Claude Code hooks in `~/.claude/settings.json` run
   `claude-tmux-state <state>`: `SessionStart`→`idle`,
   `UserPromptSubmit`/`PostToolUse`→`running`, `Notification`→`asking`, `Stop`→`idle`,
   and `SessionEnd`→`clear`. **The `Notification` state is special-cased**
   (section 0 of `claude-tmux-state`): Claude Code fires `Notification` for *both* a
   real prompt and the 60s "waiting for your input" idle timeout. The idle timeout is
   not a prompt, so it must never turn the tab red — instead it's treated as a reliable
   "Claude is idle now" signal and **downgraded to `idle`**. That downgrade is what
   clears a stuck `running` tint after a **Ctrl+C interrupt**: interrupting a running
   task fires *no* hook at all (Claude Code deliberately skips `Stop` on a user
   interrupt, and the synthetic `[Request interrupted by user]` message triggers no
   `UserPromptSubmit`), so nothing else moves the pane off `running` — without this the
   tab stays orange until your next prompt. The idle timeout is detected two ways:
   (a) the payload message says it's waiting for input — the *only* detector that fires
   while the pane is still `running`, i.e. the interrupt case; or (b) the pane is
   already `idle` (a stopped Claude can't be blocked on you) — the reliable net against
   a false red. Cost: up to ~60s of stale tint if you interrupt and then walk away.
   Don't re-map `Notification`→`asking` without keeping guard (b), and don't turn the
   idle-timeout branch back into a no-op — clearing the interrupted tint depends on it.
2. Codex hooks in `${CODEX_HOME:-$HOME/.codex}/hooks.json` run
   `claude-tmux-state <state> codex`. The exact mapping is:
   `SessionStart(startup|resume|clear)`→`idle` (`compact` excluded),
   `UserPromptSubmit`→`running`, `PreToolUse(request_user_input)`→`asking`,
   `PermissionRequest`→`asking`, `PostToolUse`→`running`, `Stop`→`idle`, and
   `SessionEnd`→`clear`. The explicit `codex` source bypasses Claude's ambiguous
   `Notification` guard. The installer does not touch Codex `config.toml`; after
   install, the user must restart Codex and use the **Hooks need review** startup
   prompt to inspect/trust these non-managed hooks. If they continue without
   trusting, `/hooks` provides the same review flow later.
3. `claude-tmux-state` writes `~/.cache/claude-tmux/pane-<id>` (keyed by `$TMUX_PANE`),
   file format **`<state>\t<window_id>`**, and sets both `window-status-style` and
   `window-status-current-style` on its window (aggregate of all tracked-agent panes
   in that window, priority asking > running > idle). This tints inactive and selected
   tabs alike.
4. `claude-tmux-status` runs from `status-right` every second: reads all state files,
   prunes stale ones, and prints a chip per agent **for sessions not currently attached**
   (the focused session is covered by the tab tint).
5. **Clickable chips (opt-in, `CT_CLICKABLE`).** When enabled, `claude-tmux-status`
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
  The writer's "skip when state word is unchanged" shortcut in
  `claude-tmux-state` MUST also confirm `cut -sf2` is non-empty — otherwise an
  upgrade from a pre-format-change file (just `running\n`) silently shortcuts
  past the window-tint section and leaves the tab untinted until the state word
  actually changes. `-s` is what makes this work: it suppresses lines with no
  TAB delimiter so old files yield empty and fall through.
- **The writer is source-aware.** Its optional second argument is the event
  source (`claude` by default for backward compatibility, or `codex`). Only an
  `asking` event from Claude goes through the ambiguous-`Notification` guard;
  Codex's structured `request_user_input` and `PermissionRequest` events must
  remain `asking` even if the pane was previously idle.
- **Installer must stay idempotent and non-destructive.** Three mechanisms — do not break:
  - tmux.conf edit is fenced by `# >>> claude-tmux >>>` / `# <<< claude-tmux <<<`
    markers; add only if absent; uninstall deletes the fenced block via `awk`.
  - hooks are merged into both `~/.claude/settings.json` and
    `${CODEX_HOME:-$HOME/.codex}/hooks.json` with `jq` using `strip_ct` (drop any
    group whose command matches `claude-tmux-state`, then re-add) so re-install
    replaces instead of duplicating and never clobbers unrelated hooks.
  - the snippet's `run-shell` reads the live `status-right` and prepends our chip
    *into* it, guarded by a `case *claude-tmux-status*` check; since any
    `set -g status-right` in `~/.tmux.conf` runs before the appended snippet, a
    reload resets to the original first, so the chip never stacks. (Do NOT nest the
    original inside a user option like `#{@base}` — tmux won't re-expand a format
    that lands inside another option's value, so the original's `#{...}`/`%...`
    would render literally.)
- **Hook JSON replacement is failure-safe.** Install and uninstall use
  `jq -e -s` and accept exactly one top-level JSON object. Invalid, empty,
  scalar, array, or concatenated documents must fail without changing the
  original file. Install stops before printing trust/success; uninstall still
  attempts both hook files, reports incomplete cleanup, and exits nonzero. Do
  not create a missing hook file until its generated replacement is ready.
  Missing `jq` likewise makes install/uninstall exit nonzero without a complete
  success message; safe script/tmux cleanup or setup already performed may
  remain, and re-running after installing `jq` completes the idempotent flow.
- **Codex hook trust stays user-controlled.** The installer writes synchronous
  (`async: false`, 3-second timeout) non-managed hooks and tells the user to
  restart Codex, choose **Review hooks** at the startup gate, and use `/hooks`
  later if needed; it must not edit `${CODEX_HOME:-$HOME/.codex}/config.toml` or
  bypass trust. Preserve the `SessionStart` matcher
  `^(startup|resume|clear)$` so
  mid-turn `compact` events do not incorrectly mark the pane idle.
- **Colors/icons are tunables**, overridable from `~/.config/claude-tmux/config`.
  The defaults are defined as `CT_*` shell vars at the top of the scripts.
  ⚠️ The window-tab colors (`CT_RUN_TAB`, `CT_ASK_TAB`) are defined in **both**
  `bin/claude-tmux-state` and `bin/claude-tmux-status` (the latter re-tints during
  self-heal), and each tint path must update/unset both inactive and selected-tab
  style options. Keep the two scripts in sync, and keep `config.example` listing
  every knob.
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
  `claude-tmux-status`'s `retint_window()`. Change both together. Each path must set
  or unset both `window-status-style` (inactive tabs) and
  `window-status-current-style` (the selected tab).
- **Self-healing prune** (in `claude-tmux-status`): a state file is dropped when its
  pane is gone OR its `pane_current_command` is a shell **and** the pane's process
  tree has no non-shell descendants. The shell-name check alone is wrong for builds
  that launch an agent via a wrapper script (e.g. `bash …/claude --…` or a Codex
  wrapper): `pane_current_command` reports `bash` for the lifetime of the session,
  so without the descendant check the reader prunes every state file on the very
  next tick. The descendant check uses a single cached `ps -eo pid,ppid,comm` pass
  (lazy — only built when at least one pane looks idle) and walks the pane subtree
  skipping intermediate shell wrappers. The window is re-tinted using the stored
  window id. Don't switch to a positive agent-name match — matching the shell set
  is what makes it cheap, and the descendant probe is what makes it safe.

## tmux gotchas to remember

- `status-right #()` output is computed **once by the server and shared across all
  clients** — it is *not* per-client. That's why "show only other sessions" is done by
  excluding `tmux list-clients` sessions, not by asking "which client is this".
- tmux renders inactive tabs with `window-status-style` and the selected tab with
  `window-status-current-style`; the writer and self-healer must update both from the
  same aggregate state. These options only take effect if the corresponding user
  format does not hardcode its own colors (the tmux defaults respect the styles).
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

- Syntax: `sh -n install.sh uninstall.sh bin/claude-tmux-* tests/*.sh` (and
  `shellcheck` if available).
- Tests: `sh tests/test-install.sh`, `sh tests/test-state.sh`, and
  `sh tests/test-tmux-integration.sh`. The installer test covers both hook files,
  custom `CODEX_HOME`, exact Codex hook shapes, idempotency, unrelated-hook
  preservation, untouched `config.toml`, and byte-for-byte failure safety for
  invalid JSON plus explicit incomplete-install/uninstall behavior without
  `jq`. The integration test uses a private real tmux server to cover
  state files, aggregate tints on inactive and selected tabs, wrapper-launched
  agents, attached-session exclusion, status chips, clear, and stale-pane
  self-healing.
- **Sandbox the installer** so it never touches your real config or tmux server — run it
  against a throwaway `$HOME` and an isolated tmux socket:

  ```sh
  SB=$(mktemp -d); SOCK=$(mktemp -d); CODEX_SB="$SB/codex-home"
  env -u TMUX HOME="$SB" CODEX_HOME="$CODEX_SB" TMUX_TMPDIR="$SOCK" sh ./install.sh
  # inspect $SB/.claude/settings.json, $CODEX_SB/hooks.json, and tmux/config files
  env -u TMUX HOME="$SB" CODEX_HOME="$CODEX_SB" TMUX_TMPDIR="$SOCK" sh ./uninstall.sh
  rm -rf "$SB" "$SOCK"
  ```
  Check: re-running install doesn't duplicate markers/hooks; unrelated hooks survive;
  custom `CODEX_HOME` is honored; Codex `config.toml` stays untouched; malformed,
  empty, scalar, array, or concatenated JSON stays byte-identical on failure; uninstall
  removes everything it added and nothing it didn't.
- Live check: install for real, run `claude` and `codex` in tmux panes, choose
  **Review hooks** at Codex's startup gate (or use `/hooks` later) to trust the
  installed hooks, and confirm tab tints plus chips from other sessions. Exercise
  `request_user_input`, an approval, and stop/end paths. For
  clickable chips: set `CT_CLICKABLE=1`, reload tmux, and confirm a left-click on a chip
  switches to that session's window (and that the default window-tab click still works).

## Docs upkeep

Any behavior change must update the affected docs in the same change: `README.md`
(user-facing), `config.example` (if you add/rename a `CT_*` tunable), and this file.

## Release

Public repo `github.com/ngocbh/claude-tmux`, branch **`main`** — the `curl | sh`
one-liner and `install.sh`'s bootstrap both reference `main`, so keep the default
branch named `main`.
