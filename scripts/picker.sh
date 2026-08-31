#!/usr/bin/env bash
# Interactive picker for running Claude agents.
#
#   picker.sh           fzf picker; on enter, jumps to the chosen agent.
#   picker.sh --list    print the rows only (used by fzf's ctrl-x reload).
#
# Rows come from agents.sh, which reads the @pane_* options that
# tmux-agent-sidebar's hooks maintain. Two kinds of row jump differently:
#   dedicated  an agent in a `claude-*` session this plugin launched — resumed in
#              the popup, over the window it was launched from.
#   loose      an agent running in any other pane — focused in place.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

[ "${1:-}" = '--list' ] && exec "$DIR/agents.sh"

command -v fzf >/dev/null 2>&1 || {
  tmux display-message "tmux-claude-session-manager: fzf is required for the picker"
  exit 0
}

self="$DIR/picker.sh"
export FZF_DEFAULT_OPTS=''
export CLAUDE_PICKER="$self"

# Arbitrary user fzf options (e.g. custom --bind or --preview-window)
extra_opts=()
fzf_options="$(get_tmux_option @claude_fzf_options '')"
[ -n "$fzf_options" ] && eval "extra_opts=($fzf_options)"

# ctrl-x kills the agent process itself: a dedicated session dies with its last
# window, while a loose pane keeps the shell that hosted it. An empty pid (row
# corrupted, or the agent exited since the listing) is a no-op. The reload waits
# a beat so the pane options reflect the kill before the list refreshes.
# Borderless fzf: the popup border comes from the list.sh display-popup.
sel=$("$DIR/agents.sh" | fzf --ansi \
  --delimiter='\t' --with-nth=6,7,8,9,10,11 \
  --tabstop=1 \
  --header-lines=1 \
  --reverse --cycle \
  --preview='tmux capture-pane -e -J -p -t {2}' --preview-window='up,70%,follow' \
  --bind='ctrl-j:preview-down,ctrl-k:preview-up' \
  --bind='ctrl-alt-s:abort' \
  --bind="ctrl-x:execute-silent(p={3}; [ -n \"\$p\" ] && kill \"\$p\")+reload(sleep 0.3; '$self' --list)" \
  ${extra_opts[@]+"${extra_opts[@]}"})

[ -z "$sel" ] && exit 0
pane=$(printf '%s' "$sel" | cut -f2)
kind=$(printf '%s' "$sel" | cut -f4)

parent=$(tmux show-options -gqv @claude_parent 2>/dev/null)
session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)

if [ "$kind" = loose ]; then
  # Focus the pane in place on the outer client. This popup closes on its own
  # when the script exits.
  if [ -n "$parent" ]; then
    tmux switch-client -c "$parent" -t "$session" 2>/dev/null
  else
    tmux switch-client -t "$session" 2>/dev/null
  fi
  tmux select-window -t "$pane" 2>/dev/null
  tmux select-pane -t "$pane" 2>/dev/null
  exit 0
fi

# Move the parent client to the window the session was launched from (best-effort),
# focus the chosen Claude's own window inside that session, then resume it in THIS
# popup over the top. Falls back to resuming over the current window when
# origin/parent are unknown.
origin=$(tmux show-options -qv -t "$session" @claude_origin 2>/dev/null)
[ -n "$origin" ] && [ -n "$parent" ] &&
  tmux switch-client -c "$parent" -t "$origin" 2>/dev/null

tmux select-window -t "$pane" 2>/dev/null
tmux select-pane -t "$pane" 2>/dev/null
tmux attach-session -t "$session"
