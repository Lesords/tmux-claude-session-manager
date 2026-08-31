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

# fzf has no timer and popup panes are not send-keys-addressable (no
# TMUX_PANE inside popups), so a background loop POSTs refresh-preview to
# fzf's --listen server every N seconds. 0 disables.
interval="$(get_tmux_option @claude_preview_refresh '0.5')"
[[ $interval =~ ^[0-9]+([.][0-9]+)?$ ]] || interval=0.5    # junk → default
[[ $interval =~ ^0+([.]0+)?$ ]] && interval=0              # 0 / 0.0 = off
listen=()
if [ "$interval" != 0 ] && command -v curl >/dev/null 2>&1; then
  port=$((20000 + RANDOM % 12000))
  listen=(--listen="127.0.0.1:$port")
  ( while :; do
      sleep "$interval"
      [ "$PPID" -eq 1 ] && exit   # picker died without running its trap
      curl -fs -X POST -H 'Content-Type: text/plain' \
        --data-binary 'refresh-preview' "http://127.0.0.1:$port/" \
        >/dev/null 2>&1 || exit
    done ) &
  refresher=$!
  trap 'kill "$refresher" 2>/dev/null' EXIT INT TERM
fi

# ctrl-x kills the agent process itself: a dedicated session dies with its last
# window, while a loose pane keeps the shell that hosted it. An empty pid (row
# corrupted, or the agent exited since the listing) is a no-op. The reload waits
# a beat so the pane options reflect the kill before the list refreshes.
# Borderless fzf: the popup border comes from the list.sh display-popup.
# Dual mode (scheme A): enter = switch session + focus pane (legacy)
#                       ctrl-o = popup view (swap-pane -d, host not switched)
raw=$("$DIR/agents.sh" | fzf --ansi \
  --delimiter='\t' --with-nth=6,7,8,9,10,11 \
  --tabstop=1 \
  --header-lines=1 \
  --reverse --cycle \
  --expect=ctrl-o \
  --preview='tmux capture-pane -e -J -p -t {2}' --preview-window='up,70%,follow' \
  --bind='ctrl-j:preview-down,ctrl-k:preview-up' \
  --bind='ctrl-r:refresh-preview' \
  --bind='ctrl-alt-s:abort' \
  --bind="ctrl-x:execute-silent(p={3}; [ -n \"\$p\" ] && kill \"\$p\")+reload(sleep 0.3; '$self' --list)" \
  ${listen[@]+"${listen[@]}"} \
  ${extra_opts[@]+"${extra_opts[@]}"})
key=$(printf '%s' "$raw" | head -n1)
sel=$(printf '%s' "$raw" | tail -n +2 | head -n1)

[ -z "$sel" ] && exit 0
pane=$(printf '%s' "$sel" | cut -f2)
kind=$(printf '%s' "$sel" | cut -f4)

parent=$(tmux show-options -gqv @claude_parent 2>/dev/null)
session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)

switch_focus() {
  if [ "$kind" = loose ]; then
    if [ -n "$parent" ]; then
      tmux switch-client -c "$parent" -t "$session" 2>/dev/null
    else
      tmux switch-client -t "$session" 2>/dev/null
    fi
    tmux select-window -t "$pane" 2>/dev/null
    tmux select-pane -t "$pane" 2>/dev/null
  else
    origin=$(tmux show-options -qv -t "$session" @claude_origin 2>/dev/null)
    [ -n "$origin" ] && [ -n "$parent" ] &&
      tmux switch-client -c "$parent" -t "$origin" 2>/dev/null
    tmux switch-client -c "$parent" -t "$session" 2>/dev/null || tmux switch-client -t "$session" 2>/dev/null
    tmux select-window -t "$pane" 2>/dev/null
    tmux select-pane -t "$pane" 2>/dev/null
  fi
}

if [ "$key" = "ctrl-o" ]; then
  # ctrl-o: popup view (swap-pane -d), fallback to switch
  claude_attach_pane "$pane" "$session" 2>/dev/null && exit 0
  switch_focus; exit 0
fi

# enter: switch session + focus (legacy)
switch_focus; exit 0
