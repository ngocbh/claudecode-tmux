#!/bin/sh

set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' 0 HUP INT TERM

repo=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
test_home="$tmp/home"
codex_home="$tmp/codex-home"
xdg_config_home="$tmp/xdg-config"
tmux_tmpdir="$tmp/tmux"
fake_bin="$tmp/bin"
claude_settings="$test_home/.claude/settings.json"
codex_hooks="$codex_home/hooks.json"
codex_config="$codex_home/config.toml"
default_codex_hooks="$test_home/.codex/hooks.json"
tmux_conf="$test_home/.tmux.conf"

mkdir -p "$test_home/.claude" "$test_home/.codex" "$codex_home" \
  "$xdg_config_home" "$tmux_tmpdir" "$fake_bin"

# Never let the installer talk to a real tmux server.
cat >"$fake_bin/tmux" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$fake_bin/tmux"

cat >"$claude_settings" <<'EOF'
{
  "theme": "keep-claude-top-level",
  "hooks": {
    "SessionStart": [
      {
        "matcher": "keep-claude-group",
        "hooks": [
          {"type": "command", "command": "keep-claude-session-start"}
        ]
      },
      {
        "hooks": [
          {"type": "command", "command": "/old/claude-tmux-state stale"}
        ]
      }
    ],
    "CustomClaudeEvent": [
      {
        "hooks": [
          {"type": "command", "command": "keep-claude-custom-event"}
        ]
      }
    ]
  }
}
EOF

cat >"$codex_hooks" <<'EOF'
{
  "version": 1,
  "owner": "keep-codex-top-level",
  "hooks": {
    "SessionStart": [
      {
        "matcher": "keep-codex-group",
        "hooks": [
          {"type": "command", "command": "keep-codex-session-start", "async": true}
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {"type": "command", "command": "/old/claude-tmux-state stale codex"}
        ]
      }
    ],
    "CustomCodexEvent": [
      {
        "hooks": [
          {"type": "command", "command": "keep-codex-custom-event"}
        ]
      }
    ]
  }
}
EOF

# A custom CODEX_HOME must leave the default path completely untouched.
printf '%s\n' '{"sentinel":"default-codex-home-must-not-change"}' >"$default_codex_hooks"
cp "$default_codex_hooks" "$tmp/default-codex-hooks.before"
# Hook trust is interactive; the installer must not bypass it in config.toml.
printf '%s\n' 'model = "keep-codex-config-untouched"' >"$codex_config"
cp "$codex_config" "$tmp/codex-config.before"
printf '%s\n' 'set -g status-left "keep-user-tmux-config"' >"$tmux_conf"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_jq() {
  file=$1
  filter=$2
  message=$3
  jq -e "$filter" "$file" >/dev/null 2>&1 || fail "$message"
}

run_install() {
  env HOME="$test_home" CODEX_HOME="$codex_home" \
    XDG_CONFIG_HOME="$xdg_config_home" TMUX_TMPDIR="$tmux_tmpdir" TMUX= \
    PATH="$fake_bin:$PATH" sh "$repo/install.sh"
}

run_uninstall() {
  env HOME="$test_home" CODEX_HOME="$codex_home" \
    XDG_CONFIG_HOME="$xdg_config_home" TMUX_TMPDIR="$tmux_tmpdir" TMUX= \
    PATH="$fake_bin:$PATH" sh "$repo/uninstall.sh"
}

prepare_case() {
  case_root=$1
  mkdir -p "$case_root/home/.claude" "$case_root/codex-home" \
    "$case_root/xdg-config" "$case_root/tmux"
}

run_case_install() {
  case_root=$1
  env HOME="$case_root/home" CODEX_HOME="$case_root/codex-home" \
    XDG_CONFIG_HOME="$case_root/xdg-config" TMUX_TMPDIR="$case_root/tmux" TMUX= \
    PATH="$fake_bin:$PATH" sh "$repo/install.sh"
}

run_case_uninstall() {
  case_root=$1
  env HOME="$case_root/home" CODEX_HOME="$case_root/codex-home" \
    XDG_CONFIG_HOME="$case_root/xdg-config" TMUX_TMPDIR="$case_root/tmux" TMUX= \
    PATH="$fake_bin:$PATH" sh "$repo/uninstall.sh"
}

run_install >"$tmp/install.log" 2>&1
run_install >>"$tmp/install.log" 2>&1

# Existing data and hook groups survive both idempotent installs.
assert_jq "$claude_settings" \
  '.theme == "keep-claude-top-level" and
   ([.hooks.SessionStart[] | select(.matcher == "keep-claude-group")] | length) == 1 and
   (.hooks.CustomClaudeEvent[0].hooks[0].command == "keep-claude-custom-event")' \
  'Claude settings were clobbered'
assert_jq "$codex_hooks" \
  '.version == 1 and .owner == "keep-codex-top-level" and
   ([.hooks.SessionStart[] | select(.matcher == "keep-codex-group")] | length) == 1 and
   (.hooks.CustomCodexEvent[0].hooks[0].command == "keep-codex-custom-event")' \
  'Codex hooks were clobbered'
cmp "$tmp/default-codex-hooks.before" "$default_codex_hooks" >/dev/null 2>&1 || \
  fail 'installer ignored custom CODEX_HOME'
cmp "$tmp/codex-config.before" "$codex_config" >/dev/null 2>&1 || \
  fail 'installer modified Codex config.toml or bypassed hook trust'

# The tmux block is present once and user config is untouched.
[ "$(grep -c '^# >>> claude-tmux >>>$' "$tmux_conf")" -eq 1 ] || \
  fail 'tmux begin marker was duplicated'
[ "$(grep -c '^# <<< claude-tmux <<<$' "$tmux_conf")" -eq 1 ] || \
  fail 'tmux end marker was duplicated'
grep -qF 'set -g status-left "keep-user-tmux-config"' "$tmux_conf" || \
  fail 'user tmux config was lost'

# Claude's existing six managed groups remain idempotent.
assert_jq "$claude_settings" \
  '([.hooks[][]?.hooks[]? |
      select((.command // "") | contains("claude-tmux-state"))] | length) == 6' \
  'Claude managed hooks were duplicated or omitted'

# Compare the full managed Codex hook shape, not only event counts.
jq -S '
  [.hooks | to_entries[]
   | .key as $event
   | .value[]
   | select(any(.hooks[]?; (.command // "") | contains("claude-tmux-state")))
   | {event: $event, matcher: (.matcher // null), hooks: .hooks}]
  | sort_by(.event)
' "$codex_hooks" >"$tmp/codex-managed.actual"

jq -n -S --arg cmd "$test_home/.local/bin/claude-tmux-state" '
  def hooks($state): [{
    type: "command",
    command: ($cmd + " " + $state + " codex"),
    timeout: 3,
    async: false
  }];
  [
    {event: "SessionStart",     matcher: "^(startup|resume|clear)$", hooks: hooks("idle")},
    {event: "UserPromptSubmit", matcher: null,                       hooks: hooks("running")},
    {event: "PreToolUse",       matcher: "^request_user_input$",     hooks: hooks("asking")},
    {event: "PermissionRequest",matcher: null,                       hooks: hooks("asking")},
    {event: "PostToolUse",      matcher: null,                       hooks: hooks("running")},
    {event: "Stop",             matcher: null,                       hooks: hooks("idle")},
    {event: "SessionEnd",       matcher: null,                       hooks: hooks("clear")}
  ] | sort_by(.event)
' >"$tmp/codex-managed.expected"

cmp "$tmp/codex-managed.expected" "$tmp/codex-managed.actual" >/dev/null 2>&1 || {
  diff -u "$tmp/codex-managed.expected" "$tmp/codex-managed.actual" >&2 || :
  fail 'Codex managed hooks do not match the required synchronous mappings'
}

grep -qF 'Hooks need review' "$tmp/install.log" || \
  fail 'installer omitted the Codex startup review prompt'
grep -qF 'Review hooks' "$tmp/install.log" || \
  fail 'installer omitted the Codex Review hooks instruction'
grep -q '/hooks' "$tmp/install.log" || fail 'installer omitted the Codex /hooks fallback'
grep -qi 'trust' "$tmp/install.log" || fail 'installer omitted the Codex trust instruction'

run_uninstall >"$tmp/uninstall.log" 2>&1

# Uninstall drops only claude-tmux hook groups from both products.
assert_jq "$claude_settings" \
  '.theme == "keep-claude-top-level" and
   ([.hooks[][]?.hooks[]? |
      select((.command // "") | contains("claude-tmux-state"))] | length) == 0 and
   ([.hooks.SessionStart[] | select(.matcher == "keep-claude-group")] | length) == 1 and
   (.hooks.CustomClaudeEvent[0].hooks[0].command == "keep-claude-custom-event")' \
  'uninstall damaged unrelated Claude settings or left managed hooks'
assert_jq "$codex_hooks" \
  '.version == 1 and .owner == "keep-codex-top-level" and
   ([.hooks[][]?.hooks[]? |
      select((.command // "") | contains("claude-tmux-state"))] | length) == 0 and
   ([.hooks.SessionStart[] | select(.matcher == "keep-codex-group")] | length) == 1 and
   (.hooks.CustomCodexEvent[0].hooks[0].command == "keep-codex-custom-event")' \
  'uninstall damaged unrelated Codex hooks or left managed hooks'
cmp "$tmp/default-codex-hooks.before" "$default_codex_hooks" >/dev/null 2>&1 || \
  fail 'uninstaller ignored custom CODEX_HOME'
cmp "$tmp/codex-config.before" "$codex_config" >/dev/null 2>&1 || \
  fail 'uninstaller modified Codex config.toml'

# A failed install must preserve malformed Claude settings byte-for-byte and
# stop before claiming that Codex trust or the overall install completed.
bad_claude="$tmp/bad-claude-install"
prepare_case "$bad_claude"
printf '%s' '{"hooks":' >"$bad_claude/home/.claude/settings.json"
cp "$bad_claude/home/.claude/settings.json" "$bad_claude/settings.before"
if run_case_install "$bad_claude" >"$bad_claude/install.log" 2>&1; then
  fail 'install accepted malformed Claude settings'
fi
cmp "$bad_claude/settings.before" "$bad_claude/home/.claude/settings.json" >/dev/null 2>&1 || \
  fail 'failed install changed malformed Claude settings'
grep -qF "$bad_claude/home/.claude/settings.json" "$bad_claude/install.log" || \
  fail 'Claude settings failure did not name its path'
if grep -qF 'One-time Codex setup' "$bad_claude/install.log" || \
   grep -q 'done\.' "$bad_claude/install.log"; then
  fail 'failed Claude hook install printed a success message'
fi

# Codex hooks must also be exactly one top-level object; an array is valid JSON
# but not a valid hooks document and must remain untouched on failure.
bad_codex="$tmp/bad-codex-install"
prepare_case "$bad_codex"
printf '{}\n' >"$bad_codex/home/.claude/settings.json"
printf '[{"not":"a top-level object"}]\n' >"$bad_codex/codex-home/hooks.json"
cp "$bad_codex/codex-home/hooks.json" "$bad_codex/hooks.before"
if run_case_install "$bad_codex" >"$bad_codex/install.log" 2>&1; then
  fail 'install accepted non-object Codex hooks'
fi
cmp "$bad_codex/hooks.before" "$bad_codex/codex-home/hooks.json" >/dev/null 2>&1 || \
  fail 'failed install changed non-object Codex hooks'
grep -qF "$bad_codex/codex-home/hooks.json" "$bad_codex/install.log" || \
  fail 'Codex hooks failure did not name its path'
if grep -qF 'One-time Codex setup' "$bad_codex/install.log" || \
   grep -q 'done\.' "$bad_codex/install.log"; then
  fail 'failed Codex hook install printed a success message'
fi

# Two individually valid JSON objects are still not one valid hook document.
# The slurped object-count guard must reject them without changing the file.
multi_codex="$tmp/multi-codex-install"
prepare_case "$multi_codex"
printf '{}\n' >"$multi_codex/home/.claude/settings.json"
printf '{}\n{}\n' >"$multi_codex/codex-home/hooks.json"
cp "$multi_codex/codex-home/hooks.json" "$multi_codex/hooks.before"
if run_case_install "$multi_codex" >"$multi_codex/install.log" 2>&1; then
  fail 'install accepted concatenated Codex hook documents'
fi
cmp "$multi_codex/hooks.before" "$multi_codex/codex-home/hooks.json" >/dev/null 2>&1 || \
  fail 'failed install changed concatenated Codex hook documents'
grep -qF "$multi_codex/codex-home/hooks.json" "$multi_codex/install.log" || \
  fail 'concatenated Codex hooks failure did not name its path'

# Uninstall attempts both hook files, but invalid inputs stay byte-identical and
# make the overall cleanup explicitly incomplete.
bad_uninstall="$tmp/bad-uninstall"
prepare_case "$bad_uninstall"
: >"$bad_uninstall/home/.claude/settings.json"
printf '42\n' >"$bad_uninstall/codex-home/hooks.json"
cp "$bad_uninstall/home/.claude/settings.json" "$bad_uninstall/settings.before"
cp "$bad_uninstall/codex-home/hooks.json" "$bad_uninstall/hooks.before"
if run_case_uninstall "$bad_uninstall" >"$bad_uninstall/uninstall.log" 2>&1; then
  fail 'uninstall accepted empty/scalar hook documents'
fi
cmp "$bad_uninstall/settings.before" "$bad_uninstall/home/.claude/settings.json" >/dev/null 2>&1 || \
  fail 'failed uninstall changed empty Claude settings'
cmp "$bad_uninstall/hooks.before" "$bad_uninstall/codex-home/hooks.json" >/dev/null 2>&1 || \
  fail 'failed uninstall changed scalar Codex hooks'
grep -qF "$bad_uninstall/home/.claude/settings.json" "$bad_uninstall/uninstall.log" || \
  fail 'failed uninstall did not name the Claude settings path'
grep -qF "$bad_uninstall/codex-home/hooks.json" "$bad_uninstall/uninstall.log" || \
  fail 'failed uninstall did not name the Codex hooks path'
grep -qi 'incomplete uninstall' "$bad_uninstall/uninstall.log" || \
  fail 'failed hook cleanup did not report an incomplete uninstall'
if grep -q 'uninstalled\.' "$bad_uninstall/uninstall.log"; then
  fail 'failed hook cleanup printed a complete-uninstall message'
fi

# Without jq, install may leave the independently useful scripts/tmux snippet
# in place, but hook setup is incomplete: it must return nonzero and must not
# print the overall success message.
no_jq_install="$tmp/no-jq-install"
prepare_case "$no_jq_install"
mkdir -p "$no_jq_install/path"
for tool in dirname mkdir cp chmod sed touch grep; do
  ln -s "$(command -v "$tool")" "$no_jq_install/path/$tool"
done
ln -s "$fake_bin/tmux" "$no_jq_install/path/tmux"
if (
  HOME="$no_jq_install/home"
  CODEX_HOME="$no_jq_install/codex-home"
  XDG_CONFIG_HOME="$no_jq_install/xdg-config"
  TMUX_TMPDIR="$no_jq_install/tmux"
  TMUX=
  PATH="$no_jq_install/path"
  export HOME CODEX_HOME XDG_CONFIG_HOME TMUX_TMPDIR TMUX PATH
  exec /bin/sh "$repo/install.sh"
) >"$no_jq_install/install.log" 2>&1; then
  fail 'install without jq reported complete success while hooks were skipped'
fi
grep -qi 'jq not found' "$no_jq_install/install.log" || \
  fail 'install without jq omitted the prerequisite error'
if grep -q 'done\.' "$no_jq_install/install.log"; then
  fail 'missing-jq install printed a complete-install message'
fi
[ ! -e "$no_jq_install/home/.claude/settings.json" ] || \
  fail 'missing-jq install created Claude settings without merged hooks'
[ ! -e "$no_jq_install/codex-home/hooks.json" ] || \
  fail 'missing-jq install created Codex hooks without a generated replacement'

# Without jq, warn before removing binaries, keep existing hooks untouched, and
# end nonzero without a complete-uninstall message. The minimal PATH proves jq
# cannot be discovered while still providing the one external utility needed.
no_jq="$tmp/no-jq-uninstall"
prepare_case "$no_jq"
mkdir -p "$no_jq/home/.local/bin" "$no_jq/path"
printf '{}\n' >"$no_jq/codex-home/hooks.json"
cp "$no_jq/codex-home/hooks.json" "$no_jq/hooks.before"
: >"$no_jq/home/.local/bin/claude-tmux-state"
ln -s "$(command -v rm)" "$no_jq/path/rm"
ln -s "$fake_bin/tmux" "$no_jq/path/tmux"
if (
  HOME="$no_jq/home"
  CODEX_HOME="$no_jq/codex-home"
  XDG_CONFIG_HOME="$no_jq/xdg-config"
  TMUX_TMPDIR="$no_jq/tmux"
  TMUX=
  PATH="$no_jq/path"
  export HOME CODEX_HOME XDG_CONFIG_HOME TMUX_TMPDIR TMUX PATH
  exec /bin/sh "$repo/uninstall.sh"
) >"$no_jq/uninstall.log" 2>&1; then
  fail 'uninstall without jq reported complete success while hooks existed'
fi
case $(sed -n '1p' "$no_jq/uninstall.log") in
  *'INCOMPLETE UNINSTALL'*) ;;
  *) fail 'missing-jq warning was not emitted before binary cleanup' ;;
esac
cmp "$no_jq/hooks.before" "$no_jq/codex-home/hooks.json" >/dev/null 2>&1 || \
  fail 'missing-jq uninstall changed Codex hooks'
[ ! -f "$no_jq/home/.local/bin/claude-tmux-state" ] || \
  fail 'missing-jq uninstall did not continue safe binary cleanup'
if grep -q 'uninstalled\.' "$no_jq/uninstall.log"; then
  fail 'missing-jq uninstall printed a complete-uninstall message'
fi

printf '%s\n' 'PASS: idempotent Claude and Codex hook install/uninstall'
