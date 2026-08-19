# claude-tmux

Run several [Claude Code](https://docs.claude.com/en/docs/claude-code) and
[Codex CLI](https://developers.openai.com/codex/) sessions at once and stop
babysitting them. Kick off work in a handful of **tmux** panes, go heads-down in
one, and let the status bar tell you — without switching tabs — the moment
another session **finishes** or **gets blocked waiting on your input**, so you
know exactly which tab to jump to next.

The project keeps the historical `claude-tmux` name, commands, and config/cache
paths for backward compatibility. Those same paths now track both agents.

- **Window-tab tint** for every tracked session: its tab turns **orange** while
  Claude Code or Codex works and **red** when a hook reports that it's waiting
  on you. This applies to both the selected tab and inactive tabs, so the state
  remains visible before and after you switch windows.
- **Status-right chips** for your *other* sessions: a compact `[win]name●` badge
  per agent (amber ● working · red ? needs-you · ✓ done), so you can watch every
  session you're not currently in from one place.

It's driven by Claude Code and Codex **hooks**, not by polling either TUI. Hook
coverage differs slightly between the two products; the exact mappings and
Codex caveats are documented below.

```
 ┌─ window tabs (current session) ──────┐         ┌─ other sessions ─┐
 │ 0:editor  1:logs  [2:claude]●        │   ...   │ [3]codex● [1]docs✓│
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

Then start Claude Code or Codex **inside a tmux pane** (`claude` or `codex`) and
watch the status bar. The install is idempotent and non-destructive — re-run it
any time (e.g. to update after `git pull`).

**One-time Codex setup:** after installation, start or restart Codex. At the
**Hooks need review** prompt, choose **Review hooks**, inspect the newly
installed non-managed hooks, and trust them so Codex can execute them. If you
choose **Continue without trusting**, run `/hooks` later to review and enable
them. They live in `${CODEX_HOME:-$HOME/.codex}/hooks.json`; the installer does
not modify Codex's `config.toml` or bypass this trust step.

### Requirements

- Claude Code and/or Codex CLI, run inside tmux
- `tmux` (3.x)
- `jq` (to merge hooks into both agents' existing hook files; without it the
  installer reports incomplete setup and exits nonzero)
- `git` (only for the `curl | sh` bootstrap)

## What it touches

| Path | Change |
|------|--------|
| `~/.local/bin/claude-tmux-{state,status,jump}` | the scripts (`jump` only used by clickable chips) |
| `~/.config/claude-tmux/claude-tmux.tmux` | generated tmux snippet (sourced) |
| `~/.config/claude-tmux/claude-tmux-click.tmux` | clickable-chip bindings (sourced only when `CT_CLICKABLE=1`) |
| `~/.config/claude-tmux/config` | your color/icon overrides (created from `config.example`) |
| `~/.tmux.conf` | a fenced `source-file` line (between `# >>> claude-tmux >>>` markers) |
| `~/.claude/settings.json` | Claude Code `hooks` entries (merged with `jq`, never clobbered) |
| `${CODEX_HOME:-$HOME/.codex}/hooks.json` | Codex `hooks` entries (merged with `jq`, never clobbered) |
| `~/.cache/claude-tmux/` | per-pane state files (runtime) |

Codex's `${CODEX_HOME:-$HOME/.codex}/config.toml` is intentionally untouched;
hook trust remains an explicit user action through the startup review or
`/hooks`.

Your existing `status-right` is preserved: the snippet reads it and prepends the
chips (idempotently — it skips if already prepended, and any `set -g status-right`
in your `~/.tmux.conf` resets it before the snippet runs, so reloads never stack).
Want the chips on the right instead? Edit `~/.config/claude-tmux/claude-tmux.tmux`
and change the order to `"$cur#(...)"`.

## Configure

Edit `~/.config/claude-tmux/config` (sh syntax; tmux style strings). The same
colors and icons apply to Claude Code and Codex. For example:

```sh
CT_RUN_CHIP='fg=colour016,bg=#ffd000,bold'   # brighter "working" chip
CT_ICON_RUN='▶'
```

See [`config.example`](config.example) for every knob. Changes show on the next
status refresh (~1s); no reinstall needed.

### Clickable chips (opt-in)

Set `CT_CLICKABLE=1` to make the chips clickable — **left-click a chip to switch
to that session and select its window**, so you can jump to the agent that needs
you without typing a `tmux` command. Then reload tmux (`tmux source-file
~/.tmux.conf`).

Needs **tmux 3.2+**, and enabling it turns on tmux **mouse mode** (`set -g mouse
on`) — that's what lets tmux capture the click, but it also changes terminal
behavior: drag-to-select text now needs **Shift**, and scrolling enters
copy-mode. That's why it's off by default. (Your own window *tabs* are already
clickable once mouse mode is on — that's tmux's built-in behavior; this only adds
the cross-session chips.)

## How it works

Each agent's hooks call the same source-aware writer. It writes
`~/.cache/claude-tmux/pane-<pane-id>` (keyed by `$TMUX_PANE`) and tints that
pane's window tab. `claude-tmux-status` runs from `status-right` every second,
aggregating all state files into the cross-session chips (skipping the sessions
currently attached to a client, which the tab tint already covers).

Claude Code maps `SessionStart` → `idle`, `UserPromptSubmit` and `PostToolUse` →
`running`, `Notification` → `asking`, `Stop` → `idle`, and `SessionEnd` →
`clear`.

[Codex hooks](https://developers.openai.com/codex/config-advanced#hooks) map the
events as follows:

- `SessionStart` with source `startup`, `resume`, or `clear` → `idle`;
  `compact` is deliberately excluded because compaction can happen mid-turn.
- `UserPromptSubmit` → `running`.
- `PreToolUse` for `request_user_input` → `asking`.
- `PermissionRequest` → `asking`.
- `PostToolUse` → `running`.
- `Stop` → `idle`.
- `SessionEnd` → `clear`.

Codex hook commands call `claude-tmux-state <state> codex`. That explicit source
keeps Codex's unambiguous asking events out of Claude Code's special
`Notification` guard.

**Why a finished session doesn't turn red:** Claude Code fires `Notification`
both for a real prompt *and* for the 60-second "waiting for your input" idle
timeout. To keep red meaning *"needs you"* (and not *"done, and you haven't come
back yet"*), `claude-tmux-state` never lets that idle timeout turn the tab red —
it treats it as an *idle* signal instead.

**After you interrupt with Ctrl+C:** interrupting a running task doesn't fire any
Claude Code hook (Claude Code deliberately skips its "stopped" hook on a user
interrupt), so the orange tint can't clear the *instant* you hit Ctrl+C. It
becomes accurate for the new active turn when you submit your next prompt, then
that turn's `Stop` clears it. If you walk away instead, the 60-second "waiting
for your input" idle notification downgrades the stale orange back to idle.

### Codex-specific caveats

Codex exposes structured lifecycle events, but not every conversational pause
has a distinct asking hook:

- A free-form assistant question that ends a turn appears `idle`; structured
  `request_user_input` questions and permission approvals appear `asking`.
- After you approve a long-running tool, the pane can remain red until that
  tool's `PostToolUse` event changes it back to `running`.
- After Ctrl+C or another cancellation, orange can remain until another
  lifecycle event fires or the Codex process exits and self-healing removes the
  state. Codex does not emit Claude Code's 60-second idle notification.

### Stale sessions

State self-heals: a closed pane/window, or an agent that crashed back to a
shell, is detected and cleaned within ~1s (the file is pruned and the window tab
re-tinted). Worst case (a crash leaving some non-shell process foreground),
reset with `rm ~/.cache/claude-tmux/pane-*`.

## Uninstall

```sh
make uninstall      # or: sh ~/.local/share/claude-tmux/uninstall.sh
```

Removes the scripts, the tmux source block, both agents' managed hook groups,
and the state cache, and restores your original `status-right`.

## License
MIT — see [LICENSE](LICENSE).
