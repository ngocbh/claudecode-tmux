# claude-tmux

Run several [Claude Code](https://docs.claude.com/en/docs/claude-code) sessions
at once and stop babysitting them. Kick off work in a handful of **tmux** panes,
go heads-down in one, and let the status bar tell you — without switching tabs —
the moment another session **finishes** or **gets blocked waiting on your
input**, so you know exactly which tab to jump to next.

- **Window-tab tint** for the sessions you're *not* looking at: the tab of any
  inactive window running Claude turns **orange** while it works and **red** the
  instant it's waiting on you — so a tab lighting up red is your cue to switch.
- **Status-right chips** for your *other* sessions: a compact `[win]name●` badge
  per Claude (amber ● working · red ? needs-you · ✓ done), so you can watch every
  session you're not currently in from one place.

It's driven by Claude Code **hooks** (no polling of the TUI), so the state is
exact: a session flips to *needs-you* the moment it actually asks, and to *done*
the moment it actually stops — no guessing, no missed prompts.

```
 ┌─ window tabs (current session) ──────┐         ┌─ other sessions ─┐
 │ 0:editor  1:logs  [2:claude]●        │   ...   │ [3]api●  [1]docs✓ │
 └──────────────────────────────────────┘         └──────────────────┘
        orange = busy · red = waiting on you       ✓ done · ? needs you · ● working
```

## Install

One line (clones to `~/.local/share/claude-tmux`, wires everything up):

```sh
curl -fsSL https://raw.githubusercontent.com/ngocbh/claude-tmux/main/install.sh | sh
```

or from a clone:

```sh
git clone https://github.com/ngocbh/claude-tmux && cd claude-tmux && make install
```

Then start Claude **inside a tmux pane** (`claude`) and watch the status bar.
The install is idempotent and non-destructive — re-run it any time (e.g. to
update after `git pull`).

### Requirements
- `tmux` (3.x)
- `jq` (to merge the Claude Code hooks into `~/.claude/settings.json`)
- `git` (only for the `curl | sh` bootstrap)

## What it touches
| Path | Change |
|------|--------|
| `~/.local/bin/claude-tmux-{state,status}` | the two scripts |
| `~/.config/claude-tmux/claude-tmux.tmux` | generated tmux snippet (sourced) |
| `~/.config/claude-tmux/config` | your color/icon overrides (created from `config.example`) |
| `~/.tmux.conf` | a fenced `source-file` line (between `# >>> claude-tmux >>>` markers) |
| `~/.claude/settings.json` | `hooks` entries (merged with `jq`, never clobbered) |
| `~/.cache/claude-tmux/` | per-pane state files (runtime) |

Your existing `status-right` is preserved: the snippet reads it and prepends the
chips (idempotently — it skips if already prepended, and any `set -g status-right`
in your `~/.tmux.conf` resets it before the snippet runs, so reloads never stack).
Want the chips on the right instead? Edit `~/.config/claude-tmux/claude-tmux.tmux`
and change the order to `"$cur#(...)"`.

## Configure

Edit `~/.config/claude-tmux/config` (sh syntax; tmux style strings). For example:

```sh
CT_RUN_CHIP='fg=colour016,bg=#ffd000,bold'   # brighter "working" chip
CT_ICON_RUN='▶'
```

See [`config.example`](config.example) for every knob. Changes show on the next
status refresh (~1s); no reinstall needed.

## How it works
Claude Code hooks call `claude-tmux-state <state>` on lifecycle events
(`SessionStart`/`UserPromptSubmit`/`PostToolUse` → `running`, `Notification` →
`asking`, `Stop` → `idle`, `SessionEnd` → `clear`). Each Claude writes its state
to `~/.cache/claude-tmux/pane-<pane-id>` (keyed by `$TMUX_PANE`) and tints its
window tab. `claude-tmux-status` runs from `status-right` every second,
aggregating all state files into the cross-session chips (skipping the session
you're viewing, which the tab tint already covers).

**Why a finished session doesn't turn red:** Claude Code fires `Notification`
both for a real prompt *and* for the 60-second "waiting for your input" idle
timeout. To keep red meaning *"needs you"* (and not *"done, and you haven't come
back yet"*), `claude-tmux-state` drops a `Notification` that arrives while the
pane is already `idle` — a stopped Claude isn't running anything, so it can't be
genuinely blocked on you.

### Stale sessions
State self-heals: a closed pane/window, or a Claude that crashed back to a shell,
is detected and cleaned within ~1s (the file is pruned and the window tab
re-tinted). Worst case (a crash leaving some non-shell process foreground), reset
with `rm ~/.cache/claude-tmux/pane-*`.

## Uninstall

```sh
make uninstall      # or: sh ~/.local/share/claude-tmux/uninstall.sh
```

Removes the scripts, the tmux source block, the hooks, and the state cache, and
restores your original `status-right`.

## License
MIT — see [LICENSE](LICENSE).
