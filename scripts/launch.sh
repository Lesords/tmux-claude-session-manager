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
cmd="$(get_tmux_option @claude_command 'claude')"
args="$(get_tmux_option @claude_args '')"
[ -n "$args" ] && cmd="$cmd $args"
w="$(get_tmux_option @claude_popup_width '90%')"
h="$(get_tmux_option @claude_popup_height '90%')"

session="${prefix}$(session_hash "$path")"

if [[ "$(tmux display-message -p '#S')" == "$prefix"* ]]; then
  tmux display-message '🫪 Popup window already open'
  exit 0
fi

tmux has-session -t "$session" 2>/dev/null ||
  tmux new-session -d -s "$session" -c "$path" "$cmd"

# Record where it was launched, so picker opened inside the popup can return
# to the same outer client instead of whichever normal client tmux lists first.
[ -n "$window" ] && tmux set-option -t "$session" @claude_origin "$window"
[ -n "$client" ] && tmux set-option -t "$session" @claude_origin_client "$client"

if [ -n "$client" ]; then
  tmux display-popup -c "$client" -w "$w" -h "$h" -E "tmux attach-session -t $session"
else
  tmux display-popup -w "$w" -h "$h" -E "tmux attach-session -t $session"
fi
