#!/usr/bin/env bash
# Record a Claude Code session's state for the picker.
# Wire this into Claude Code hooks (see README):  state.sh <working|waiting|idle>
#
# Claude Code hooks inherit the Claude process environment, so $TMUX_PANE is set
# whenever Claude runs inside tmux. Outside tmux this is a no-op.
[ -z "$TMUX_PANE" ] && exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# State is stored per-pane as a tiny file named by pane_id (e.g. "%4"), one line
# "<state> <unix-ts>". Per-pane files keep several Claude instances in the same
# session independent, and reading them in the picker needs no tmux round-trip.
# A shared host is safe: claude_state_dir() bakes the UID into the path.
state_dir="$(claude_state_dir)"
mkdir -p "$state_dir"
printf '%s %s\n' "${1:-idle}" "$(date +%s)" > "$state_dir/$TMUX_PANE"
exit 0
