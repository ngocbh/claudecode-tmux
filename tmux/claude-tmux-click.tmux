# claude-tmux clickable chips — sourced by claude-tmux.tmux ONLY when CT_CLICKABLE
# is enabled (the main snippet gates this with if-shell). Left-click a status chip
# to jump to its session/window.
#
# Why MouseDown1Status (not StatusRight): tmux fires MouseDown1Status for a click on
# ANY status range — both our chips (range "ct@<window_id>") and normal window tabs
# (range "window") — and never the region-specific StatusRight key. So we bind that
# one key and branch on #{mouse_status_range}: jump on a "ct@" chip, otherwise fall
# back to tmux's default `select-window -t =` so window tabs keep working.
#
# Kept as a plain sourced file (not assembled inside a run-shell) on purpose: tmux
# format-expands #{...} found in a run-shell argument, which would blow away the
# #{mouse_status_range}/#{client_name} formats before they could be stored. Here they
# survive verbatim in the bound command and expand per-click. The `=` target in the
# fallback resolves to the clicked window — it only works as a native tmux command in
# the key's command queue (not from a subprocess), which is why the branch lives here.
set -g mouse on
bind-key -n MouseDown1Status if-shell -F '#{m:ct@*,#{mouse_status_range}}' "run-shell '@JUMP_CMD@ #{mouse_status_range} #{client_name}'" 'select-window -t ='
