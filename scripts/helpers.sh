#!/usr/bin/env bash
# Shared helpers for tmux-claude-session-manager.

# get_tmux_option <option-name> <default>
# Echoes the global tmux option value, or the default when unset/empty.
get_tmux_option() {
  local value
  value="$(tmux show-option -gqv "$1" 2>/dev/null)"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$2"
  fi
}

# session_hash <string>
# Short, stable, portable 8-char hash for deriving a session name from a path.
# Prefers md5sum (Linux), falls back to md5 (macOS) then shasum. The trailing
# newline matches the conventional `echo "$path" | md5sum` scheme, so it stays
# compatible with sessions created that way.
session_hash() {
  local out
  if command -v md5sum >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5sum)"
  elif command -v md5 >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5 -q)"
  else
    out="$(printf '%s\n' "$1" | shasum)"
  fi
  out="${out%% *}"
  printf '%s' "${out:0:8}"
}

# claude_dbg <msg> — append to the debug log while @claude_debug is set;
# CLAUDE_DEBUG_LOG overrides the default /tmp path.
claude_dbg() {
  [ -n "$(get_tmux_option @claude_debug '')" ] || return 0
  printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" \
    >> "${CLAUDE_DEBUG_LOG:-/tmp/claude-session-manager.log}" 2>/dev/null
}

# view helpers — popup-only panel attach via swap-pane -d
# Pane liveness: display-message exits 0 even when the target pane does not
# resolve (the error only reaches stderr), so scan the pane list instead.
claude_pane_alive() {
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$1"
}

claude_attach_pane() {
  local pane="$1" session="$2" apid="${3:-}"
  claude_pane_alive "$pane" || return 1
  # Already open in another popup view: a second swap would tangle the chains.
  case "$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)" in
    __claude_view_*)
      claude_dbg "ctrl-o on $pane skipped: already open in a view"
      tmux display-message "claude: this pane is already open in a popup view" 2>/dev/null
      return 0
      ;;
  esac
  local cols lines
  cols=$(tmux display-message -p '#{client_width}' 2>/dev/null || echo 80)
  lines=$(tmux display-message -p '#{client_height}' 2>/dev/null || echo 24)
  case "$cols$lines" in *[!0-9]*) cols=80; lines=24;; esac
  [ "$lines" -gt 2 ] && lines=$((lines-1))
  local view="__claude_view_$$_$(date +%s)"
  local ph
  ph=$(tmux new-session -d -s "$view" -x "$cols" -y "$lines" \
    sh -c 'printf "\n  \033[2m%s\033[0m\n  \033[2m%s\033[0m\n" "pane $1 is open in popup" "关闭弹窗后自动归位" ; while :; do sleep 3600; done' placeholder "$pane" \
    \; display-message -p -t "=$view:" '#{pane_id}' 2>/dev/null) || return 1
  [ -n "$ph" ] || { tmux kill-session -t "=$view" 2>/dev/null; return 1; }
  tmux swap-pane -d -s "$pane" -t "$ph" 2>/dev/null || { tmux kill-session -t "=$view" 2>/dev/null; return 1; }
  claude_dbg "view $view opened: pane $pane <-> tombstone $ph (from session '$session')"

  # A dedicated key table gives the view its own shortcuts; every unbound
  # key still reaches the pane. The tmux prefix is unavailable inside the
  # view — C-q is the way out.
  tmux set-option -t "$view" key-table csview
  tmux bind-key -T csview C-q detach-client
  # C-M-x kills the agent pid, not #{pane_pid} (only the pane shell).
  if [ -n "$apid" ]; then
    tmux bind-key -T csview C-M-x run-shell "if kill $apid 2>/dev/null; then tmux set-option -t '#{pane_id}' -p -u @pane_agent; tmux detach-client -t '#{client_name}' 2>/dev/null || tmux display-popup -C 2>/dev/null; else tmux display-message 'claude: kill failed'; fi"
  else
    tmux bind-key -T csview C-M-x run-shell "tmux display-message 'claude: no agent to kill'"
  fi
  # Mirror the configured list key into csview (root bindings are invisible
  # here); the popup to close lives on the parent client, not this one.
  local list_key="$(get_tmux_option @claude_list_key 'C-M-s')"
  tmux bind-key -T csview "$list_key" run-shell "tmux display-popup -C -c \"\$(tmux show-options -gqv @claude_parent)\" 2>/dev/null || tmux display-popup -C 2>/dev/null"

  # The trap also restores when the popup dies with the picker (tmux calls
  # need no tty); restored/signalled keep the two paths from double-running
  # and skip the fallback switch after a signal.
  local restored=0 signalled=0
  _ca_restore() {
    [ "$restored" -eq 1 ] && return 0
    restored=1
    if ! tmux swap-pane -d -s "$pane" -t "$ph" 2>/dev/null; then
      if tmux break-pane -d -s "$pane" -t "$session:" 2>/dev/null; then
        # tombstone closed while viewing: back as a new window
        tmux display-message "claude: popup-view pane restored as a new window" 2>/dev/null
        claude_dbg "restore: tombstone gone, $pane broken out as a new window"
      elif ! claude_pane_alive "$pane"; then
        # the agent exited (or was killed with C-M-x) while viewing:
        # nothing to return, just drop the tombstone
        tmux kill-pane -t "$ph" 2>/dev/null
        claude_dbg "restore: pane gone, tombstone $ph removed"
      else
        claude_dbg "restore: could not return $pane (session '$session' gone?)"
      fi
    fi
    tmux kill-session -t "=$view" 2>/dev/null
  }
  trap '_ca_restore; signalled=1' HUP INT TERM
  local sock="${TMUX%%,*}" rc=0
  if [ -S "$sock" ]; then TMUX= tmux -S "$sock" attach -t "=$view" 2>/dev/null; rc=$?
  else tmux attach -t "=$view" 2>/dev/null; rc=$?; fi
  trap - HUP INT TERM
  _ca_restore
  [ "$signalled" -eq 1 ] && return 0
  # the agent exiting while viewed (or killed with C-M-x) is a clean
  # outcome, not a failure — don't trigger the switch fallback
  claude_pane_alive "$pane" || rc=0
  return $rc
}
