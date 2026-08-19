#!/bin/sh

set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' 0 HUP INT TERM

test_home="$tmp/home"
fake_bin="$tmp/bin"
mkdir -p "$test_home/.cache/claude-tmux" "$fake_bin"

cat >"$fake_bin/tmux" <<'EOF'
#!/bin/sh
[ -z "${TMUX_LOG:-}" ] || printf '%s\n' "$*" >>"$TMUX_LOG"
case "$1" in
  display-message) printf '%s\n' '@1' ;;
  list-panes)      printf '%s\n' '%1' ;;
esac
EOF
chmod +x "$fake_bin/tmux"

state_file="$test_home/.cache/claude-tmux/pane-1"
expected_file="$tmp/expected-state"
writer=$(CDPATH= cd "$(dirname "$0")/.." && pwd)/bin/claude-tmux-state

assert_file_eq() {
  cmp "$expected_file" "$state_file" >/dev/null 2>&1 && return 0

  printf '%s\n' 'FAIL: state file bytes differ' >&2
  cmp "$expected_file" "$state_file" >&2 || :
  printf '%s\n' 'expected:' >&2
  sed -n l "$expected_file" >&2
  printf '%s\n' 'actual:' >&2
  if [ -f "$state_file" ]; then
    sed -n l "$state_file" >&2
  else
    printf '%s\n' '(missing)' >&2
  fi
  exit 1
}

# Codex asking events are unambiguous and must bypass Claude's idle guard.
printf 'idle\t@1\n' >"$state_file"
env HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" \
  PATH="$fake_bin:$PATH" TMUX=1 TMUX_PANE=%1 \
  "$writer" asking codex </dev/null
printf 'asking\t@1\n' >"$expected_file"
assert_file_eq

# With no source argument, retain the legacy Claude Notification behavior.
printf 'idle\t@1\n' >"$state_file"
env HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" \
  PATH="$fake_bin:$PATH" TMUX=1 TMUX_PANE=%1 \
  "$writer" asking </dev/null
printf 'idle\t@1\n' >"$expected_file"
assert_file_eq

# A pre-window-id cache record must not trigger the same-state shortcut. It is
# upgraded to the tab-delimited format and both tab styles are recomputed.
tmux_log="$tmp/tmux.log"
: >"$tmux_log"
printf 'running\n' >"$state_file"
env HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" \
  PATH="$fake_bin:$PATH" TMUX=1 TMUX_PANE=%1 TMUX_LOG="$tmux_log" \
  "$writer" running codex </dev/null
printf 'running\t@1\n' >"$expected_file"
assert_file_eq
grep -q 'set-option -w -t @1 window-status-style' "$tmux_log" || {
  printf '%s\n' 'FAIL: old state record was upgraded without retinting the inactive tab' >&2
  exit 1
}
grep -q 'set-option -w -t @1 window-status-current-style' "$tmux_log" || {
  printf '%s\n' 'FAIL: old state record was upgraded without retinting the selected tab' >&2
  exit 1
}

printf '%s\n' 'PASS: source-aware and upgrade-safe state writer'
