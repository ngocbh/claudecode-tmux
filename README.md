# claude-tmux

See, at a glance, what every [Claude Code](https://docs.claude.com/en/docs/claude-code)
session running in your **tmux** is doing — working, waiting on you, or idle —
across all your sessions.

- **Window-tab tint** for the session you're in: the tab of any *inactive*
  window running Claude turns **orange** while it works and **red** while it's
  asking you something.
- **Status-right chips** for your *other* sessions: a compact
  `[win]name●` badge per Claude (amber ● working · red ? needs-you · ✓ idle),
  so you can watch sessions you're not currently looking at.

It's driven by Claude Code **hooks** (no polling of the TUI), so state is exact.

```
 ┌─ window tabs (current session) ──────┐         ┌─ other sessions ─┐
 │ 0:editor  1:logs  [2:claude]●        │   ...   │ [3]api●  [1]docs✓ │
 └──────────────────────────────────────┘         └──────────────────┘
        orange tab = Claude busy in window 2          chips for other sessions
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
