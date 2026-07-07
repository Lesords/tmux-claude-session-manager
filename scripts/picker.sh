#!/usr/bin/env bash
# Interactive picker for running Claude sessions.
#
#   picker.sh           fzf picker; on enter, switches the parent client to the
#                       pane running the chosen Claude and focuses it.
#   picker.sh --list    print the rows only (used by fzf's ctrl-x reload).
#
# Scans EVERY tmux pane across all sessions and lists any pane whose process
# tree contains a `claude` process — so Claude started directly in a pane (not
# via `prefix + y`) is listed too. Status (working/waiting/idle) is read from
# the per-pane state file written by the Claude Code hooks (see README).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

emit_rows() {
  local now pane_id claude_pid state at icon rank ago path entry pane_pid pane_pids
  local -A pane_by_pid      # pane_pid -> "pane_id\tpath" (small: one entry per pane)
  local state_dir
  now=$(date +%s)
  state_dir="$(claude_state_dir)"

  # pane_pid -> pane metadata + a space-joined list of all pane_pids. list-panes
  # -a covers every session, so launcher-created `claude-*` sessions are included.
  pane_pids=""
  while IFS=$'\t' read -r pane_pid pane_id path; do
    [ -z "$pane_pid" ] && continue
    pane_by_pid["$pane_pid"]="${pane_id}"$'\t'"${path}"
    pane_pids="$pane_pids $pane_pid"
  done < <(tmux list-panes -a -F '#{pane_pid}'$'\t''#{pane_id}'$'\t''#{pane_current_path}' 2>/dev/null)

  # ps | awk finds each `claude` process's owning pane; the while loop (runs in a
  # subshell, inherits pane_by_pid) decorates each match with state + path and
  # prints a row; sort orders by rank then age. Doing the parent-chain walk in
  # awk keeps it at C speed instead of building a 1500+-entry map in bash.
  # Unmatched claude (other users, non-tmux) reaches PID 1 and prints nothing.
  ps -Ao pid=,ppid=,comm= 2>/dev/null |
  awk -v panes="$pane_pids" '
    BEGIN { n = split(panes, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") pane[a[i]] = 1 }
    { ppid[$1] = $2; if ($3 == "claude") claude[$1] = 1 }
    END {
      for (c in claude) {
        # Claude may BE the pane process itself: the launcher runs
        # `new-session ... "claude"`, and the shell execs claude (single-command
        # optimization), so claude pid == pane_pid. Check that first.
        if (c in pane) { print c "\t" c; continue }
        # Otherwise walk the parent chain until an ancestor is a pane_pid
        # (claude typed interactively in a pane shell). Unmatched claude
        # (other users, non-tmux) reaches PID 1 and prints nothing.
        x = c
        for (i = 0; i < 60; i++) {
          pp = ppid[x]
          if (pp == "") break
          if (pp in pane) { print c "\t" pp; break }
          if (pp == "1") break
          x = pp
        }
      }
    }' |
  while IFS=$'\t' read -r claude_pid pane_pid; do
    [ -z "$pane_pid" ] && continue
    entry="${pane_by_pid[$pane_pid]:-}"
    [ -z "$entry" ] && continue
    pane_id=${entry%%$'\t'*}
    path=${entry#*$'\t'}
    # dedup per pane: keep only the first claude mapping to each pane.
    case "${seen:-}" in *" $pane_id "*) continue ;; esac
    seen="${seen:-} $pane_id "

    # State lives in a per-pane file: one bash builtin read, no tmux round-trip.
    state=""; at=""
    [ -r "$state_dir/$pane_id" ] && read -r state at < "$state_dir/$pane_id" || true
    case "$state" in
    waiting) icon=$'\033[33m●\033[0m waiting' rank=0 ;; # yellow - needs input
    idle) icon=$'\033[32m●\033[0m idle   ' rank=1 ;;    # green  - done, your turn
    working) icon=$'\033[31m●\033[0m working' rank=3 ;; # red    - busy, leave it
    *) icon=$'\033[90m●\033[0m   ?    ' rank=2 ;;       # grey   - unknown (no hook yet)
    esac
    if [ -n "$at" ]; then ago="$(((now - at) / 60))m"; else ago='-'; fi
    # rank \t pane_id \t claude_pid \t icon \t age \t path
    # (rank/pane_id/claude_pid hidden via --with-nth=4,5,6)
    printf '%s\t%s\t%s\t%s\t%5s\t%s\n' "$rank" "$pane_id" "$claude_pid" "$icon" "$ago" "${path/#$HOME/~}"
  done | sort -t$'\t' -k1,1n -k5,5n
  # rank asc (attention-needed floats up), then age asc so the session that
  # finished just now sits at the top of its group. -k5,5n reads the leading
  # number of the age field ("5m" -> 5; "-" -> 0).
}

[ "${1:-}" = '--list' ] && {
  emit_rows
  exit 0
}

if ! command -v fzf >/dev/null 2>&1; then
  tmux display-message "tmux-claude-session-manager: fzf is required for the picker"
  exit 0
fi

self="${BASH_SOURCE[0]}"
export FZF_DEFAULT_OPTS=''
sel=$(emit_rows | fzf --ansi --delimiter='\t' --with-nth=4,5,6 \
  --reverse --cycle \
  --header='Claude sessions · enter: jump · ctrl-x: kill claude · ctrl-j/k: scroll preview' \
  --preview="tmux capture-pane -e -J -p -t {2}" --preview-window='right,62%' \
  --bind='ctrl-j:preview-down,ctrl-k:preview-up' \
  --bind="ctrl-x:execute-silent(kill {3})+reload($self --list)")

[ -z "$sel" ] && exit 0
pane_id=$(printf '%s' "$sel" | cut -f2)

# Jump to the chosen pane. Two cases:
#   - The pane lives in a "popup-style" session: the launcher's `claude-<hash>`
#     (@claude_session_prefix) or a popup tool like tmux-floax's `floax-<origin>`
#     (@claude_popup_prefix). We must NOT switch the outer client into it
#     full-screen; instead repurpose THIS picker popup to attach to that session
#     — mirroring how the launcher/popup tool itself shows it, and leaving the
#     outer client untouched. detach (prefix+d) or the tool's toggle closes it.
#   - Otherwise (Claude running directly in a normal pane): move the parent
#     client to that pane's window and focus it. window_id (@N) is global, so
#     switch-client lands on the right window across sessions.
prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
popup_prefix="$(get_tmux_option @claude_popup_prefix 'floax-')"
target=$(tmux list-panes -a -F '#{pane_id}'$'\t''#{session_name}'$'\t''#{window_id}' 2>/dev/null |
  awk -F'\t' -v p="$pane_id" '$1 == p { print $2 "\t" $3; exit }')
session=${target%%$'\t'*}
window=${target#*$'\t'}
[ -z "$session" ] && exit 0

# A prefix of "" disables that check (avoids `*` matching every session).
is_popup=0
{ [ -n "$prefix" ] && [[ "$session" == "$prefix"* ]]; } && is_popup=1
{ [ -n "$popup_prefix" ] && [[ "$session" == "$popup_prefix"* ]]; } && is_popup=1

if [ "$is_popup" -eq 1 ]; then
  exec tmux attach-session -t "$session"
else
  parent=$(tmux show-options -gqv @claude_parent 2>/dev/null)
  if [ -n "$window" ]; then
    if [ -n "$parent" ]; then
      tmux switch-client -c "$parent" -t "$window" 2>/dev/null
    else
      tmux switch-client -t "$window" 2>/dev/null
    fi
  fi
  tmux select-pane -t "$pane_id" 2>/dev/null
fi
