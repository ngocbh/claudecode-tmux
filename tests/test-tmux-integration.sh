#!/bin/sh

set -eu

repo=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
writer=$repo/bin/claude-tmux-state
reader=$repo/bin/claude-tmux-status
tmux_bin=$(command -v tmux) || {
  printf '%s\n' 'FAIL: tmux is required for the real-server integration test' >&2
  exit 1
}

tmp=$(mktemp -d)
sock=$tmp/s
test_home=$tmp/home
xdg_config_home=$tmp/xdg
control_pid=
control_open=0

cleanup() {
  if [ "$control_open" -eq 1 ]; then
    exec 9>&-
    control_open=0
  fi
  if [ -n "$control_pid" ]; then
    kill "$control_pid" >/dev/null 2>&1 || :
    wait "$control_pid" >/dev/null 2>&1 || :
  fi
  "$tmux_bin" -S "$sock" kill-server >/dev/null 2>&1 || :
  if [ -n "$tmp" ] && [ -d "$tmp" ]; then
    rm -R "$tmp"
  fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  actual=$1
  expected=$2
  message=$3
  [ "$actual" = "$expected" ] || {
    printf 'FAIL: %s\nexpected: [%s]\nactual:   [%s]\n' \
      "$message" "$expected" "$actual" >&2
    exit 1
  }
}

assert_state() {
  pane=$1
  state=$2
  window=$3
  state_file=$test_home/.cache/claude-tmux/pane-${pane#%}
  printf '%s\t%s\n' "$state" "$window" >"$tmp/expected-state"
  cmp "$tmp/expected-state" "$state_file" >/dev/null 2>&1 || \
    fail "wrong state-file bytes for $pane ($state)"
}

window_style() {
  "$tmux_bin" -S "$sock" show-options -w -t "$1" -v window-status-style
}

window_current_style() {
  "$tmux_bin" -S "$sock" \
    show-options -w -t "$1" -v window-status-current-style
}

wait_for_sleep() {
  pane=$1
  count=0
  while [ "$count" -lt 5 ]; do
    command_name=$("$tmux_bin" -S "$sock" \
      display-message -p -t "$pane" '#{pane_current_command}')
    [ "$command_name" = sleep ] && return 0
    count=$((count + 1))
    sleep 1
  done
  fail "pane $pane did not reach the sleep fixture"
}

wait_for_wrapper() {
  pane=$1
  pane_pid=$2
  count=0
  while [ "$count" -lt 5 ]; do
    command_name=$("$tmux_bin" -S "$sock" \
      display-message -p -t "$pane" '#{pane_current_command}')
    case "$command_name" in
      bash | zsh | sh | fish | ksh | dash | -bash | -zsh | -sh)
        if ps -eo pid=,ppid=,comm= 2>/dev/null | \
          awk -v root="$pane_pid" \
            '$2 == root && $3 == "sleep" { found=1 } END { exit(found ? 0 : 1) }'
        then
          return 0
        fi
        ;;
    esac
    count=$((count + 1))
    sleep 1
  done
  fail "pane $pane did not become a shell wrapper with a live sleep child"
}

mkdir -p "$test_home" "$xdg_config_home/claude-tmux"
cat >"$xdg_config_home/claude-tmux/config" <<'CONFIG'
CT_RUN_TAB='fg=colour1,bold'
CT_ASK_TAB='fg=colour2,bold'
CT_RUN_CHIP='fg=green'
CT_ASK_CHIP='fg=red'
CT_IDLE_CHIP='fg=blue'
CT_ICON_RUN='R'
CT_ICON_ASK='A'
CT_ICON_IDLE='I'
CT_SEP='SEP'
CT_CLICKABLE=''
CONFIG

# Every tmux command names this private socket. The first command also disables
# configuration loading, and the synthetic HOME keeps the real user untouched.
unset TMUX TMUX_PANE
HOME=$test_home XDG_CONFIG_HOME=$xdg_config_home SHELL=/bin/sh \
  "$tmux_bin" -S "$sock" -f /dev/null \
  new-session -d -s attached -n work 'exec sleep 300'
HOME=$test_home XDG_CONFIG_HOME=$xdg_config_home \
  "$tmux_bin" -S "$sock" \
  new-session -d -s remote -n work 'exec sleep 300'
"$tmux_bin" -S "$sock" split-window -d -t remote:0 'exec sleep 300'
HOME=$test_home XDG_CONFIG_HOME=$xdg_config_home \
  "$tmux_bin" -S "$sock" \
  new-session -d -s wrapper -n work 'sleep 300 & wait'

server_pid=$("$tmux_bin" -S "$sock" display-message -p '#{pid}')
test_tmux=$sock,$server_pid,0
apane=$("$tmux_bin" -S "$sock" list-panes -t attached:0 -F '#{pane_id}')
awin=$("$tmux_bin" -S "$sock" display-message -p -t "$apane" '#{window_id}')
set -- $("$tmux_bin" -S "$sock" list-panes -t remote:0 -F '#{pane_id}')
[ "$#" -eq 2 ] || fail 'remote fixture did not get exactly two panes'
rpane1=$1
rpane2=$2
rwin=$("$tmux_bin" -S "$sock" display-message -p -t "$rpane1" '#{window_id}')
rindex=$("$tmux_bin" -S "$sock" display-message -p -t "$rpane1" '#{window_index}')
wpane=$("$tmux_bin" -S "$sock" list-panes -t wrapper:0 -F '#{pane_id}')
wwin=$("$tmux_bin" -S "$sock" display-message -p -t "$wpane" '#{window_id}')
wpid=$("$tmux_bin" -S "$sock" display-message -p -t "$wpane" '#{pane_pid}')

wait_for_sleep "$apane"
wait_for_sleep "$rpane1"
wait_for_sleep "$rpane2"
wait_for_wrapper "$wpane" "$wpid"

run_writer() {
  HOME=$test_home XDG_CONFIG_HOME=$xdg_config_home \
    TMUX=$test_tmux TMUX_PANE=$1 \
    "$writer" "$2" codex </dev/null
}

run_reader() {
  HOME=$test_home XDG_CONFIG_HOME=$xdg_config_home TMUX=$test_tmux \
    "$reader"
}

# A wrapper-launched agent leaves a shell as pane_current_command. Its live
# non-shell descendant must keep the reader from treating the state as stale.
run_writer "$wpane" running
assert_state "$wpane" running "$wwin"
run_reader >"$tmp/wrapper-status"
assert_state "$wpane" running "$wwin"
assert_eq "$(window_style "$wwin")" 'fg=colour1,bold' \
  'reader pruned or retinted a live wrapper-launched agent'
run_writer "$wpane" clear
[ ! -f "$test_home/.cache/claude-tmux/pane-${wpane#%}" ] || \
  fail 'wrapper fixture clear did not remove its state'
"$tmux_bin" -S "$sock" kill-session -t wrapper

# State files contain state<TAB>window_id, and the aggregate window tint uses
# asking > running > idle across multiple tracked panes.
run_writer "$rpane1" running
assert_state "$rpane1" running "$rwin"
assert_eq "$(window_style "$rwin")" 'fg=colour1,bold' \
  'one running pane did not tint its window running'
assert_eq "$(window_current_style "$rwin")" 'fg=colour1,bold' \
  'one running pane did not tint its selected window tab'

run_writer "$rpane2" asking
assert_state "$rpane2" asking "$rwin"
assert_eq "$(window_style "$rwin")" 'fg=colour2,bold' \
  'asking did not outrank running'
assert_eq "$(window_current_style "$rwin")" 'fg=colour2,bold' \
  'asking did not tint the selected window tab'

run_writer "$rpane2" idle
assert_state "$rpane2" idle "$rwin"
assert_eq "$(window_style "$rwin")" 'fg=colour1,bold' \
  'running did not survive when the asking pane became idle'

run_writer "$rpane1" idle
assert_eq "$(window_style "$rwin")" '' \
  'all-idle window retained a local tint'
assert_eq "$(window_current_style "$rwin")" '' \
  'all-idle selected window retained a local tint'

# Recreate the asking-over-running aggregate. Killing the asking pane without a
# clear event then exercises the reader's stale-pane prune and window retint.
run_writer "$rpane1" running
run_writer "$rpane2" asking
assert_eq "$(window_style "$rwin")" 'fg=colour2,bold' \
  'stale-pane fixture did not start asking'

# The attached session has live state but must be omitted from status-right.
run_writer "$apane" asking
assert_state "$apane" asking "$awin"
assert_eq "$(window_style "$awin")" 'fg=colour2,bold' \
  'attached-session fixture did not start asking'

# Control mode provides a real attached client without needing a terminal.
fifo=$tmp/control.in
mkfifo "$fifo"
(
  unset TMUX TMUX_PANE
  HOME=$test_home
  XDG_CONFIG_HOME=$xdg_config_home
  export HOME XDG_CONFIG_HOME
  exec "$tmux_bin" -S "$sock" -C attach-session -t attached
) <"$fifo" >"$tmp/control.log" 2>&1 &
control_pid=$!
exec 9>"$fifo"
control_open=1

count=0
client_session=
while [ "$count" -lt 5 ]; do
  client_session=$("$tmux_bin" -S "$sock" \
    list-clients -F '#{session_name}' 2>/dev/null || :)
  [ "$client_session" = attached ] && break
  count=$((count + 1))
  sleep 1
done
assert_eq "$client_session" attached 'control-mode client did not attach'

"$tmux_bin" -S "$sock" kill-pane -t "$rpane2"
run_reader >"$tmp/status.actual"
printf ' #[fg=green][%s]remoteR#[default] SEP ' "$rindex" \
  >"$tmp/status.expected"
cmp "$tmp/status.expected" "$tmp/status.actual" >/dev/null 2>&1 || \
  fail 'status output was not exactly the one unattached remote chip'

[ -f "$test_home/.cache/claude-tmux/pane-${apane#%}" ] || \
  fail 'attached-session state was pruned instead of excluded'
[ ! -f "$test_home/.cache/claude-tmux/pane-${rpane2#%}" ] || \
  fail 'gone pane state was not self-healed'
assert_eq "$(window_style "$rwin")" 'fg=colour1,bold' \
  'stale asking pane was pruned without retinting to running'
assert_eq "$(window_current_style "$rwin")" 'fg=colour1,bold' \
  'stale asking pane left the selected tab asking'

run_writer "$apane" clear
[ ! -f "$test_home/.cache/claude-tmux/pane-${apane#%}" ] || \
  fail 'clear did not remove the attached pane state'
assert_eq "$(window_style "$awin")" '' \
  'clear did not remove the attached window tint'
assert_eq "$(window_current_style "$awin")" '' \
  'clear did not remove the attached selected-window tint'

printf 'PASS: real tmux writer/reader integration (%s)\n' \
  "$("$tmux_bin" -V)"
