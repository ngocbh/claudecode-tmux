#!/bin/sh
# claude-tmux uninstaller — reverses install.sh.
set -eu

BIN_DIR="$HOME/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-tmux"
SETTINGS="$HOME/.claude/settings.json"
TMUX_CONF="$HOME/.tmux.conf"
MARK_BEGIN="# >>> claude-tmux >>>"
MARK_END="# <<< claude-tmux <<<"

log() { printf '\033[36m[claude-tmux]\033[0m %s\n' "$1"; }

# scripts
rm -f "$BIN_DIR/claude-tmux-status" "$BIN_DIR/claude-tmux-state"
log "removed scripts from $BIN_DIR"

# tmux source block (between markers)
if [ -f "$TMUX_CONF" ] && grep -qF "$MARK_BEGIN" "$TMUX_CONF"; then
  tmp=$(mktemp)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0==b {skip=1}
    skip { if ($0==e) skip=0; next }
    {print}
  ' "$TMUX_CONF" >"$tmp" && mv "$tmp" "$TMUX_CONF"
  log "removed source block from $TMUX_CONF"
fi

# strip our chip from the running server's status-right, then re-source
if command -v tmux >/dev/null 2>&1 && tmux info >/dev/null 2>&1; then
  cur=$(tmux show -gv status-right 2>/dev/null || true)
  tmux set -g status-right "$(printf '%s' "$cur" | sed 's|#([^)]*claude-tmux-status[^)]*)||g')" 2>/dev/null || true
  tmux set -gu @claude_tmux_base 2>/dev/null || true   # legacy installs
  tmux source-file "$TMUX_CONF" >/dev/null 2>&1 || true
fi
rm -rf "$CFG_DIR"

# hooks
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  tmp=$(mktemp)
  jq '
    def strip_ct: map(select((.hooks // [] | map(.command // "") | any(test("claude-tmux-state"))) | not));
    if (.hooks | type) == "object"
    then .hooks |= (with_entries(.value |= strip_ct) | with_entries(select((.value | length) > 0)))
    else . end
    | if (.hooks == {}) then del(.hooks) else . end
  ' "$SETTINGS" >"$tmp" && mv "$tmp" "$SETTINGS"
  log "removed hooks from $SETTINGS"
fi

# state cache
rm -rf "$HOME/.cache/claude-tmux"
log "uninstalled. (the cloned repo, if any, is left in place)"
