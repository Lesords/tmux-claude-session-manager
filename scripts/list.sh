#!/usr/bin/env bash
# Open the session picker in a popup.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
popup_prefix="$(get_tmux_option @claude_popup_prefix 'floax-')"
w="$(get_tmux_option @claude_popup_width '90%')"
h="$(get_tmux_option @claude_popup_height '90%')"
origin_client="${1:-}"

is_popup_session() {
  local session="${1:-}"
  [ -z "$session" ] && return 1

  { [ -n "$prefix" ] && [[ "$session" == "$prefix"* ]]; } ||
    { [ -n "$popup_prefix" ] && [[ "$session" == "$popup_prefix"* ]]; }
}

client_session() {
  local client="${1:-}"
  [ -z "$client" ] && return 0

  tmux list-clients -F '#{client_name}'$'\t''#{session_name}' 2>/dev/null |
    awk -F'\t' -v c="$client" '$1 == c { print $2; exit }'
}

is_host_client() {
  local session

  session="$(client_session "${1:-}")"
  [ -n "$session" ] && ! is_popup_session "$session"
}

# The session of a client attached to a popup-style session (launcher's
# `claude-` or a popup tool like floax's `floax-`). tmux has no "is popup"
# attribute — popups are transient client overlays, so the session name prefix
# is the only persistent marker (floax itself detects its sessions by `^floax-`).
# Empty when invoked from a normal (non-popup) pane.
nested_session() {
  local session

  if [ -n "$origin_client" ]; then
    session="$(client_session "$origin_client")"
    is_popup_session "$session" && printf '%s\n' "$session"
    return 0
  fi

  tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
    awk -v p="$prefix" -v pp="$popup_prefix" \
      '((p != "" && index($2, p) == 1) || (pp != "" && index($2, pp) == 1)) { print $2; exit }'
}

# A client NOT attached to a popup-style session — the outer client that should
# host the picker popup.
host_client() {
  if [ -n "$origin_client" ] && is_host_client "$origin_client"; then
    printf '%s\n' "$origin_client"
    return 0
  fi

  tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
    awk -v p="$prefix" -v pp="$popup_prefix" \
      '!((p != "" && index($2, p) == 1) || (pp != "" && index($2, pp) == 1)) { print $1; exit }'
}

# If we are inside a session popup, close it (detach its client).
host=""
sess="$(nested_session)"
if [ -n "$sess" ]; then
  host="$(tmux show-options -t "$sess" -qv @claude_origin_client 2>/dev/null)"
  is_host_client "$host" || host=""

  tmux detach-client -s "$sess"
  # Wait until the session is gone
  for _ in $(seq 1 100); do
    [ -z "$(nested_session)" ] && break
    sleep 0.05
  done
fi

[ -n "$host" ] || host="$(host_client)"
tmux set-option -g @claude_parent "$host"

# Host the picker on the outer client. -c is honored because that client has no
# popup open now; fall back to the default client if none was found.
if [ -n "$host" ]; then
  tmux display-popup -c "$host" -w "$w" -h "$h" -E "$DIR/picker.sh"
else
  tmux display-popup -w "$w" -h "$h" -E "$DIR/picker.sh"
fi
