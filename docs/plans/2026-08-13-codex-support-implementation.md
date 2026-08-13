# Plan: Codex CLI support

**Goal**: Make the existing tmux indicator track both Claude Code and Codex CLI
without breaking installed names, state files, hooks, or user configuration.

**Architecture**: Feed native Codex lifecycle hooks into the existing writer,
distinguish Codex's definite asking events from Claude's ambiguous Notification,
and preserve all current reader/tmux contracts.

**Tech Stack**: POSIX `sh`, `jq`, tmux, JSON hook configuration.

## Dependencies

| Group | Steps | Can Parallelize |
| --- | --- | --- |
| 1 | Steps 1-2 | No; both establish hook/writer contracts |
| 2 | Step 3 | No; documents the final implementation |
| 3 | Step 4 | No; end-to-end verification |

The worktree already contains user edits in `CLAUDE.md`, `README.md`, and
`bin/claude-tmux-state`. Preserve them. Task commits are intentionally omitted
where they would absorb those pre-existing changes.

## Step 1: Make the state writer source-aware

**Files**: `bin/claude-tmux-state`, `tests/test-state.sh`

### 1a. Write the failing regression

Create a POSIX-shell test with a temporary `HOME` and fake `tmux`. Seed an idle
`pane-1` file, invoke `claude-tmux-state asking codex`, and assert it becomes
asking. Reset it, invoke legacy `claude-tmux-state asking`, and assert the
Claude idle guard leaves it idle. Assert both files retain the tab-delimited
window id.

### 1b. Verify failure

```sh
sh tests/test-state.sh
```

### 1c. Implement

Read `${2:-claude}` in the writer and run the Notification heuristic only for
the default/Claude source. Update the usage and comments without changing the
state-file format or tint aggregation.

### 1d. Verify

```sh
sh -n bin/claude-tmux-state tests/test-state.sh
sh tests/test-state.sh
```

## Step 2: Merge and remove Codex hooks non-destructively

**Files**: `install.sh`, `uninstall.sh`, `tests/test-install.sh`

**Depends on**: Step 1

### 2a. Write the failing regression

Create a temporary home, custom `CODEX_HOME`, isolated tmux directory, and
pre-existing unrelated hooks in both JSON files. Run install twice and assert:
unrelated hooks remain; each managed hook appears exactly once; Codex commands
end in `codex`; SessionStart excludes `compact`; and structured input uses an
exact `request_user_input` matcher. Run uninstall and assert only
`claude-tmux-state` groups disappear.

### 2b. Verify failure

```sh
sh tests/test-install.sh
```

### 2c. Implement

Resolve `CODEX_HOOKS` from `${CODEX_HOME:-$HOME/.codex}`. Merge the approved
event mapping into `hooks.json` with `jq`, using short command-hook timeouts and
the existing strip/readd pattern. Extend uninstall to clean both hook files and
preserve unrelated top-level keys. Log the one-time `/hooks` trust step.

### 2d. Verify

```sh
sh -n install.sh uninstall.sh tests/test-install.sh
sh tests/test-install.sh
```

## Step 3: Update user and maintainer documentation

**Files**: `README.md`, `CLAUDE.md`, `config.example`,
`bin/claude-tmux-status`, `tmux/claude-tmux.tmux`

**Depends on**: Steps 1-2

Document dual-agent behavior, touched Codex path, `/hooks` trust, exact event
mapping, `CODEX_HOME`, and known approval/free-form-question/Ctrl+C limits.
Describe the existing product name as retained for compatibility. Make only
wording changes to reader/snippet/config comments; do not alter rendering.

Verify links, commands, event names, and that every behavior change is reflected
in both user and maintainer docs.

## Step 4: End-to-end verification

**Depends on**: Steps 1-3

```sh
sh -n install.sh uninstall.sh bin/claude-tmux-* tests/*.sh
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck install.sh uninstall.sh bin/claude-tmux-* tests/*.sh
fi
sh tests/test-state.sh
sh tests/test-install.sh
git diff --check
```

Then repeat the documented sandbox install/uninstall manually and inspect both
hook files. If a usable isolated Codex CLI is available, verify `/hooks` sees
the definitions; do not alter the user's real Codex configuration or tmux
server during automated verification.
