#!/bin/sh
# claude-tmux uninstaller — reverses install.sh.
set -eu

BIN_DIR="$HOME/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-tmux"
SETTINGS="$HOME/.claude/settings.json"
CODEX_HOOKS="${CODEX_HOME:-$HOME/.codex}/hooks.json"
TMUX_CONF="$HOME/.tmux.conf"
MARK_BEGIN="# >>> claude-tmux >>>"
MARK_END="# <<< claude-tmux <<<"

log() { printf '\033[36m[claude-tmux]\033[0m %s\n' "$1"; }
err() { printf '\033[31m[claude-tmux] error:\033[0m %s\n' "$1" >&2; }

hooks_incomplete=0
if command -v jq >/dev/null 2>&1; then
  jq_available=1
else
  jq_available=0
  if [ -f "$SETTINGS" ] || [ -f "$CODEX_HOOKS" ]; then
    hooks_incomplete=1
    err "INCOMPLETE UNINSTALL: jq not found; existing hook files will be left unchanged ($SETTINGS, $CODEX_HOOKS)"
  fi
fi

# scripts
rm -f "$BIN_DIR/claude-tmux-status" "$BIN_DIR/claude-tmux-state" "$BIN_DIR/claude-tmux-jump"
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
  # Clickable chips overrode MouseDown1Status — restore tmux's default tab-click.
  # (mouse setting left as-is; we don't know if the user wanted it on.)
  tmux bind-key -n MouseDown1Status select-window -t = 2>/dev/null || true
  tmux unbind-key -n MouseDown1StatusRight 2>/dev/null || true   # legacy dev binding
  tmux source-file "$TMUX_CONF" >/dev/null 2>&1 || true
fi
rm -rf "$CFG_DIR"

# hooks
remove_hooks() {
  hook_file=$1
  [ -f "$hook_file" ] || return 0
  tmp=$(mktemp)
  if ! jq -e -s '
    def require_single_object:
      if (length == 1 and (.[0] | type) == "object")
      then .[0]
      else error("expected exactly one top-level JSON object")
      end;
    def strip_ct: map(select((.hooks // [] | map(.command // "") | any(test("claude-tmux-state"))) | not));
    require_single_object
    |
    if (.hooks | type) == "object"
    then .hooks |= (with_entries(.value |= strip_ct) | with_entries(select((.value | length) > 0)))
    else . end
    | if (.hooks == {}) then del(.hooks) else . end
  ' "$hook_file" >"$tmp"; then
    rm -f "$tmp"
    err "INCOMPLETE UNINSTALL: could not update $hook_file; expected exactly one top-level JSON object; original left unchanged"
    return 1
  fi
  if ! mv "$tmp" "$hook_file"; then
    rm -f "$tmp"
    err "INCOMPLETE UNINSTALL: could not safely replace $hook_file; original left unchanged"
    return 1
  fi
  log "removed hooks from $hook_file"
}

if [ "$jq_available" -eq 1 ]; then
  remove_hooks "$SETTINGS" || hooks_incomplete=1
  remove_hooks "$CODEX_HOOKS" || hooks_incomplete=1
fi

# state cache
rm -rf "$HOME/.cache/claude-tmux"

if [ "$hooks_incomplete" -ne 0 ]; then
  err "INCOMPLETE UNINSTALL: hook cleanup did not finish; fix the errors above and re-run uninstall.sh"
  exit 1
fi
log "uninstalled. (the cloned repo, if any, is left in place)"
