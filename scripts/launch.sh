#!/usr/bin/env bash
# Launch (or re-attach to) a Claude session for a directory, shown in a popup.
# Args: <dir> [origin-window-id] [origin-client]   (expanded by run-shell)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

path="${1:-$PWD}"
window="${2:-}"
client="${3:-}"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
pp="$(get_tmux_option @claude_popup_prefix 'floax-')"
cmd="$(get_tmux_option @claude_command 'claude')"
args="$(get_tmux_option @claude_args '')"
[ -n "$args" ] && cmd="$cmd $args"
w="$(get_tmux_option @claude_popup_width '90%')"
h="$(get_tmux_option @claude_popup_height '90%')"

session="${prefix}$(session_hash "$path")"

# One popup per client: launching from inside any popup session (ours or an
# external tool's like floax) would replace and kill it. Empty prefixes
# never match; same rule as list.sh's is_popup_session.
cur_session="$(tmux display-message -p '#S')"
if [[ ( -n "$prefix" && "$cur_session" == "$prefix"* ) ||
      ( -n "$pp" && "$cur_session" == "$pp"* ) ]]; then
  tmux display-message '🫪 Already inside a popup session'
  exit 0
fi

if ! tmux has-session -t "$session" 2>/dev/null; then
  [ -d "$path" ] || {
    tmux display-message "tmux-claude-session-manager: $path no longer exists"
    exit 0
  }
  tmux new-session -d -s "$session" -c "$path" "$cmd"
fi

# Record which window launched it, so the picker can jump back here later.
[ -n "$window" ] && tmux set-option -t "$session" @claude_origin "$window"

# Pin the popup to the client that pressed the key (falls back to tmux's
# default active client when unknown), so it opens on the right terminal.
if [ -n "$client" ]; then
  tmux display-popup -c "$client" -w "$w" -h "$h" -E "tmux attach-session -t '$session'"
else
  tmux display-popup -w "$w" -h "$h" -E "tmux attach-session -t '$session'"
fi
