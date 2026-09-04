#!/usr/bin/env bash
# Open the session picker in a popup.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# Reclaim panes stranded in clientless __claude_view_* sessions by a picker
# killed mid-view: swap back into the tombstone slot (its command line embeds
# the pane id), or break out as a new window if the tombstone is gone. Kill
# only after the pane is confirmed out — a race must displace, never destroy.
sweep_orphan_views() {
  local vs kid ph_pid ph target="${1:-}"
  for vs in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^__claude_view_'); do
    # list-clients exits 0 even with no clients attached — test the output.
    [ -n "$(tmux list-clients -t "=$vs" 2>/dev/null)" ] && continue    # actively viewed
    kid=$(tmux list-panes -t "=$vs" -F '#{pane_id}' 2>/dev/null | head -1)
    ph_pid=$(pgrep -f "placeholder $kid\$" 2>/dev/null | head -1)
    ph=''
    [ -n "$ph_pid" ] &&
      ph=$(tmux list-panes -a -F '#{pane_id} #{pane_pid}' 2>/dev/null |
        awk -v p="$ph_pid" '$2 == p { print $1; exit }')
    if [ -n "$ph" ]; then
      if tmux swap-pane -d -s "$kid" -t "$ph" 2>/dev/null; then
        tmux display-message "claude: restored pane $kid from an interrupted popup view" 2>/dev/null
      else
        claude_dbg "sweep $vs: swap-back to $ph failed, left for retry"
        continue
      fi
    elif [ -n "$kid" ] && [ -n "$target" ]; then
      tmux break-pane -d -s "$kid" -t "=$target:" 2>/dev/null &&
        tmux display-message "claude: pane $kid recovered as a new window" 2>/dev/null
    elif [ -z "$kid" ]; then
      tmux kill-session -t "=$vs" 2>/dev/null    # empty husk
    else
      claude_dbg "sweep $vs: no tombstone and no target session, left for retry"
      continue
    fi
    # A racing sweep may have swapped the pane back in between our restore
    # and this kill — only kill once the pane is confirmed out.
    tmux list-panes -t "=$vs" -F '#{pane_id}' 2>/dev/null | grep -qx "$kid" ||
      tmux kill-session -t "=$vs" 2>/dev/null
    claude_dbg "sweep $vs: pane=${kid:-none} tombstone=${ph:-gone}"
  done
}

# Manual recovery entry — safe next to a live picker (attached views are skipped).
if [ "${1:-}" = '--sweep' ]; then
  sweep_orphan_views "$(tmux display-message -p '#{session_name}' 2>/dev/null)"
  exit 0
fi

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
popup_prefix="$(get_tmux_option @claude_popup_prefix 'floax-')"
w="$(get_tmux_option @claude_popup_width '90%')"
h="$(get_tmux_option @claude_popup_height '90%')"

# The client that pressed the key, and the session it is currently attached to.
# Looked up by exact client_name match rather than "first client anywhere that
# looks nested" — with more than one client attached (e.g. a stray popup left
# open in another window), a global scan can grab an unrelated client's session
# and detach it instead of the one this invocation actually cares about.
me="${1:-}"
my_session="$(tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
  awk -v me="$me" '$1 == me { print $2; exit }')"

# Toggle: C-M-s should close the picker if it is already open
if pgrep -f "[p]icker\.sh" >/dev/null 2>&1; then
  tmux display-popup -C -c "$me" 2>/dev/null || tmux display-popup -C 2>/dev/null
  exit 0
fi

# No picker alive → any view leftovers are orphans; reclaim before opening.
sweep_orphan_views "$my_session"

# open_picker <host> — popup on <host> (default client when empty); floax-style
# rounded border in the theme accent (@selected). Returns display-popup status.
open_picker() {
  local title=' Claude agents · enter: jump · ctrl-o: popup · ctrl-x: kill · ctrl-j/k: scroll '
  local args=()
  [ -n "$1" ] && args+=(-c "$1")
  tmux display-popup "${args[@]}" -w "$w" -h "$h" -b rounded -S 'fg=#{@selected}' -s 'fg=default' -T "$title" -E "$DIR/picker.sh"
}

# A popup-style session: the launcher's `claude-` prefix or an external popup
# tool's prefix (e.g. tmux-floax's `floax-*`). tmux has no "is popup" attribute,
# so the name prefix is the only marker (floax itself detects its sessions by
# `^floax-`). Empty prefixes are skipped so ""* can't match every session.
is_popup_session() {
  local session="${1:-}"
  [ -z "$session" ] && return 1
  { [ -n "$prefix" ] && [[ "$session" == "$prefix"* ]]; } && return 0
  { [ -n "$popup_prefix" ] && [[ "$session" == "$popup_prefix"* ]]; } && return 0
  return 1
}

if is_popup_session "$my_session"; then
  # Inside a session popup: close it, then reopen the picker on the outer client.
  #
  # display-popup returns to its caller *before* tmux finishes destroying the
  # closing overlay, and a popup opened during that window never receives keyboard
  # input (it hangs). So wait for the popup's client to leave, settle past the
  # teardown, then reopen — retrying a reopen that is rejected mid-teardown (it
  # returns almost instantly, whereas a popup that opened blocks while in use).
  # Detach only the client that pressed the key; other terminals attached to
  # the same session must survive. Then wait for that client to leave — the
  # popup teardown race below is about this popup, not the session's clients.
  tmux detach-client -t "$me"
  for _ in $(seq 1 100); do
    tmux list-clients -F '#{client_name}' 2>/dev/null | grep -qx "$me" || break
    sleep 0.05
  done
  host="$(tmux show-options -gqv @claude_parent 2>/dev/null)"
  # A stale parent would make every retry fail; fall back to the default client.
  if [ -n "$host" ] && ! tmux list-clients -F '#{client_name}' 2>/dev/null | grep -qx "$host"; then
    host=''
  fi

  sleep 0.1
  rc=0
  for _ in $(seq 1 40); do
    before=$SECONDS
    open_picker "$host"
    rc=$?
    { [ "$rc" -eq 0 ] || [ $((SECONDS - before)) -ge 1 ]; } && break
    sleep 0.1
  done
  exit "$rc"
else
  # Normal case: this client is already the host, with no overlay to race.
  host="$me"
  # A manual/no-arg invocation has no client to record — keep the last parent
  # instead of clobbering the option with an empty string.
  [ -n "$host" ] && tmux set-option -g @claude_parent "$host"
fi

open_picker "$host"
