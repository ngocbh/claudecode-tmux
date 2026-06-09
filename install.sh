#!/bin/sh
# claude-tmux installer — idempotent, non-destructive.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/ngocbh/claude-tmux/main/install.sh | sh
# Or from a clone:
#   git clone https://github.com/ngocbh/claude-tmux && cd claude-tmux && ./install.sh
set -eu

REPO_URL="https://github.com/ngocbh/claude-tmux.git"
BIN_DIR="$HOME/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-tmux"
SNIPPET="$CFG_DIR/claude-tmux.tmux"
SETTINGS="$HOME/.claude/settings.json"
TMUX_CONF="$HOME/.tmux.conf"
MARK_BEGIN="# >>> claude-tmux >>>"
MARK_END="# <<< claude-tmux <<<"

log() { printf '\033[36m[claude-tmux]\033[0m %s\n' "$1"; }
err() { printf '\033[31m[claude-tmux] error:\033[0m %s\n' "$1" >&2; }

# --- locate the source tree, or bootstrap by cloning (curl | sh) ------------
SRC=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)
if [ -z "${SRC:-}" ] || [ ! -f "$SRC/bin/claude-tmux-status" ]; then
  command -v git >/dev/null 2>&1 || { err "git is required to bootstrap the install"; exit 1; }
  DEST="${XDG_DATA_HOME:-$HOME/.local/share}/claude-tmux"
  if [ -d "$DEST/.git" ]; then
    log "updating existing clone at $DEST"
    git -C "$DEST" pull --ff-only --quiet || true
  else
    log "cloning $REPO_URL -> $DEST"
    git clone --depth 1 --quiet "$REPO_URL" "$DEST"
  fi
  exec sh "$DEST/install.sh"
fi

command -v tmux >/dev/null 2>&1 || err "tmux not found on PATH (install it; the indicator needs it)"

# --- 1. scripts -------------------------------------------------------------
log "installing scripts -> $BIN_DIR"
mkdir -p "$BIN_DIR"
cp "$SRC/bin/claude-tmux-status" "$SRC/bin/claude-tmux-state" "$BIN_DIR/"
chmod +x "$BIN_DIR/claude-tmux-status" "$BIN_DIR/claude-tmux-state"

# --- 2. tmux snippet + source line in ~/.tmux.conf --------------------------
log "writing tmux snippet -> $SNIPPET"
mkdir -p "$CFG_DIR"
sed "s|@STATUS_CMD@|$BIN_DIR/claude-tmux-status|g" "$SRC/tmux/claude-tmux.tmux" >"$SNIPPET"
[ -f "$CFG_DIR/config" ] || cp "$SRC/config.example" "$CFG_DIR/config" 2>/dev/null || true

touch "$TMUX_CONF"
if grep -qF "$MARK_BEGIN" "$TMUX_CONF"; then
  log "~/.tmux.conf already wired up"
else
  log "adding source line -> $TMUX_CONF"
  {
    printf '\n%s\n' "$MARK_BEGIN"
    printf 'source-file %s\n' "$SNIPPET"
    printf '%s\n' "$MARK_END"
  } >>"$TMUX_CONF"
fi
if tmux info >/dev/null 2>&1; then
  tmux source-file "$TMUX_CONF" >/dev/null 2>&1 && log "reloaded running tmux" || true
fi

# --- 3. Claude Code hooks (merged into settings.json) -----------------------
if command -v jq >/dev/null 2>&1; then
  log "merging hooks -> $SETTINGS"
  mkdir -p "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || printf '{}\n' >"$SETTINGS"
  tmp=$(mktemp)
  jq --arg cmd "$BIN_DIR/claude-tmux-state" '
    def grp($arg): {hooks: [{type: "command", command: ($cmd + " " + $arg)}]};
    def strip_ct: map(select((.hooks // [] | map(.command // "") | any(test("claude-tmux-state"))) | not));
    .hooks = (.hooks // {})
    | .hooks.SessionStart     = ((.hooks.SessionStart     // []) | strip_ct) + [grp("idle")]
    | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | strip_ct) + [grp("running")]
    | .hooks.PostToolUse      = ((.hooks.PostToolUse      // []) | strip_ct) + [grp("running")]
    | .hooks.Notification     = ((.hooks.Notification     // []) | strip_ct) + [grp("asking")]
    | .hooks.Stop             = ((.hooks.Stop             // []) | strip_ct) + [grp("idle")]
    | .hooks.SessionEnd       = ((.hooks.SessionEnd       // []) | strip_ct) + [grp("clear")]
  ' "$SETTINGS" >"$tmp" && mv "$tmp" "$SETTINGS"
else
  err "jq not found — skipped Claude Code hooks. Install jq and re-run, or add hooks manually (see README)."
fi

log "done."
log "Run Claude in a tmux pane; its state shows as a window-tab tint + a chip"
log "for other sessions on the right of the status bar. Tune ~/.config/claude-tmux/config."
