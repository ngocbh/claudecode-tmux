# Claude-tmux Codex Support Design

## Goal

Extend `claude-tmux` so Claude Code and Codex CLI sessions share the existing
tmux window tints, status-right chips, stale-session cleanup, and click-to-jump
behavior.

## Chosen architecture

Keep every existing public path and format for backward compatibility:
`claude-tmux-*` binaries, `CT_*` settings, `~/.cache/claude-tmux`, tmux marker
comments, and `ct<window_id>` click ranges. The reader and click handler are
already agent-agnostic; Codex only needs to feed the existing writer.

Install user-level Codex lifecycle hooks in
`${CODEX_HOME:-$HOME/.codex}/hooks.json`. Merge them with `jq` using the same
strip-and-readd strategy as the Claude Code hooks so reinstalling is idempotent
and unrelated hooks survive. Codex requires the user to review and trust new
non-managed hooks at the **Hooks need review** startup gate (or later through
`/hooks`); the installer must explain that rather than bypassing trust.

The Codex transitions are:

| Codex event | Match | State |
| --- | --- | --- |
| `SessionStart` | `startup`, `resume`, or `clear` | `idle` |
| `UserPromptSubmit` | all | `running` |
| `PreToolUse` | `request_user_input` | `asking` |
| `PermissionRequest` | all | `asking` |
| `PostToolUse` | all | `running` |
| `Stop` | all | `idle` |
| `SessionEnd` | all | `clear` |

`SessionStart(source=compact)` is deliberately excluded because automatic
compaction can happen during an active turn. Hooks remain synchronous so rapid
state transitions cannot complete out of order.

## Writer compatibility

Add an optional source argument:

```text
claude-tmux-state <running|asking|idle|clear> [claude|codex]
```

The omitted source retains today's Claude behavior. Codex hooks pass `codex`.
Only Claude `asking` events use the Notification idle-timeout heuristic; Codex
`PermissionRequest` and `request_user_input` events are definite requests and
must not be suppressed merely because the previous state was idle. The state
file stays exactly `state<TAB>window_id`.

## Tab tint semantics

tmux uses `window-status-style` for inactive tabs and
`window-status-current-style` for the selected tab. The writer and the reader's
self-healing retint path set both options to the same aggregate run/ask color,
and unset both when the window becomes idle. Existing `CT_RUN_TAB` and
`CT_ASK_TAB` settings apply to both; no additional knobs or format rewrites are
needed.

## Limitations and recovery

Codex has no documented hook when an approval is resolved, so an approved
long-running tool may remain red until `PostToolUse`. A free-form assistant
question that ends a turn is indistinguishable from ordinary completion and
therefore shows idle; structured `request_user_input` shows asking. Codex also
skips `Stop` on a canceled turn, with no Claude-style 60-second idle
notification, so an interrupted turn can stay orange until another lifecycle
event or until the process exits and the existing self-healer prunes it. These
constraints are documented rather than papered over with unstable transcript
or TUI scraping.

## Verification

Add POSIX-shell regression tests for the source-aware writer, selected and
inactive tab styles on a real isolated tmux server, and sandboxed double
install/uninstall behavior with unrelated Claude and Codex hooks. Run `sh -n`,
shellcheck when available, the regression scripts, and the repository's
documented isolated installer smoke test.
