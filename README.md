# claude-tmux

Run several [Claude Code](https://docs.claude.com/en/docs/claude-code) or Codex CLI sessions
at once and stop babysitting them. Kick off work in a handful of **tmux** panes,
go heads-down in one, and let the status bar tell you — without switching tabs —
the moment another session **finishes** or **gets blocked waiting on your
input**, so you know exactly which tab to jump to next.

- **Window-tab tint** for Claude sessions: its tab turns **orange** while it
  works and **red** the instant it's waiting on you, including the current tab.
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

Then start Claude or Codex **inside a tmux pane** (`claude` or `codex`) and watch
the status bar. In Codex, first use `/hooks` to review and trust the
`claude-tmux-codex` handlers, then restart Codex so its startup hook runs.
The install is idempotent and non-destructive — re-run it any time (e.g. to
update after `git pull`).

### Requirements
- `tmux` (2.7+ for status indicators; 3.2+ for clickable chips)
- `jq` (to merge Claude Code and Codex hooks, and read Codex events)
- For Codex: a CLI version with native lifecycle hooks (verified with 0.153.3)
- `git` (only for the `curl | sh` bootstrap)

## What it touches
| Path | Change |
|------|--------|
| `~/.local/bin/claude-tmux-{state,status,jump}` | the scripts (`jump` only used by clickable chips) |
| `~/.local/bin/claude-tmux-codex` | Codex lifecycle adapter |
| `~/.local/bin/claude-tmux-ssh` | SSH connection with tmux socket forwarding |
| `~/.config/claude-tmux/claude-tmux.tmux` | generated tmux snippet (sourced) |
| `~/.config/claude-tmux/claude-tmux-click.tmux` | clickable-chip bindings (sourced only when `CT_CLICKABLE=1`) |
| `~/.config/claude-tmux/config` | your color/icon overrides (created from `config.example`) |
| `~/.tmux.conf` | a fenced `source-file` line (between `# >>> claude-tmux >>>` markers) |
| `~/.claude/settings.json` | `hooks` entries (merged with `jq`, never clobbered) |
| `${CODEX_HOME:-~/.codex}/hooks.json` | Codex `hooks` entries (merged with `jq`) |
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

### Clickable chips (opt-in)

Set `CT_CLICKABLE=1` to make the chips clickable — **left-click a chip to switch
to that session and select its window**, so you can jump to the Claude that needs
you without typing a `tmux` command. Then reload tmux (`tmux source-file
~/.tmux.conf`).

The **running server** must be 3.2 or newer. Check with
`tmux display-message -p '#{version}'`; `tmux -V` only checks the executable.
Tmux 2.7 drops clicks outside its window list, so loading a binding cannot enable
chip clicks there. The plugin omits clickable ranges and bindings on unsupported
servers. Installing a newer executable does not upgrade an existing server.
Start the newer tmux with a separate socket (for example, `tmux -L modern new -A
-s ide`) to keep old sessions running during the transition. New shells and
forwarded compute-node connections must use a client matching their server.

Needs **tmux 3.2+**, and enabling it turns on tmux **mouse mode** (`set -g mouse
on`) — that's what lets tmux capture the click, but it also changes terminal
behavior: drag-to-select text now needs **Shift**, and scrolling enters
copy-mode. That's why it's off by default. (Your own window *tabs* are already
clickable once mouse mode is on — that's tmux's built-in behavior; this only adds
the cross-session chips.)

## How it works
Claude Code hooks call `claude-tmux-state <state>` on lifecycle events
(`SessionStart`/`UserPromptSubmit`/`PostToolUse` → `running`, `Notification` →
`asking`, `Stop` → `idle`, `SessionEnd` → `clear`). Each Claude writes its state
to `~/.cache/claude-tmux/<server-host>-<server-pid>/pane-<pane-id>` (keyed by `$TMUX_PANE`) and tints its
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
with `rm ~/.cache/claude-tmux/<server-host>-<server-pid>/pane-*`.

### tmux on a login node, agents on a compute node

From the login-node tmux pane, connect with:

```sh
claude-tmux-ssh COMPUTE_NODE           # Keeps the current directory
claude-tmux-ssh COMPUTE_NODE /path/to/project
# On the compute node:
codex                                # Or claude
```

Ordinary SSH does not propagate `TMUX` or `TMUX_PANE`, and a tmux Unix socket
belongs to the host running the server. This helper forwards that socket over
SSH and exports the matching pane environment to the remote login shell. The
hooks can then update the original window. The installed Misha `ide ssh`
command uses this helper automatically when invoked inside tmux.

This requires a shared home directory between the two nodes, compatible tmux
clients, and OpenSSH Unix-socket forwarding on both ends. The forwarding socket
lives in a private temporary directory on the compute node and is cleaned up
when the remote shell exits. Normal SSH authentication and host-key checks apply.
Use an exact compute hostname, not an alias that can resolve to different hosts
between connections. Each tmux server has its own state directory so pane IDs
on separate servers cannot overwrite or prune one another's indicators.
The bridge prepends the local tmux executable's directory to the remote `PATH`,
so a newer server installed on shared storage uses the same client remotely.

Reconnect through the helper and restart or resume Codex to update an existing
plain-SSH session. If an agent crashes while SSH stays open, the login tmux
server cannot detect the remote shell prompt; run `claude-tmux-state clear`
on the compute node or close that SSH connection to clear a stale indicator.

### Codex

The installer also registers [native Codex hooks](https://learn.chatgpt.com/docs/hooks).
`SessionStart` marks the pane idle (or running after compaction),
`UserPromptSubmit`/`PostToolUse` mark it running, `PermissionRequest` marks it
asking, `Stop`/`Interrupt` mark it idle, and `SessionEnd` clears it. A `PreToolUse`
hook also marks `request_user_input` and `request_user_input_async` calls asking.
These explicit attention events bypass Claude's idle-notification filter.
The adapter returns no approval decision and does not change Codex permissions.

Codex must trust the hooks before they run: review them with `/hooks`. If hooks
were explicitly disabled in your Codex configuration, enable them with
`codex features enable hooks`. Start a new Codex process after installation.
Asynchronous questions can overlap ongoing work, so later tool activity may
show running while a question remains open. Parallel tool events share one pane
indicator. Remote app-server sessions need the tmux environment on the hook host.

## Uninstall

```sh
make uninstall      # or: sh ~/.local/share/claude-tmux/uninstall.sh
```

Removes the scripts, the tmux source block, the hooks, and the state cache, and
restores your original `status-right`.

## Verification

The standalone checks require Python 3, tmux, and jq. They create isolated tmux
servers and a temporary installation, preserving your running sessions:

```sh
python3 tests/check_tmux.py
# From a login node, using an already allocated compute node with shared home:
python3 tests/check_tmux.py --remote-host COMPUTE_NODE
```

## License
MIT — see [LICENSE](LICENSE).
