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

# view helpers — popup-only panel attach via swap-pane -d
claude_attach_pane() {
  local pane="$1" session="$2"
  tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1 || return 1
  local cols=$(tmux display-message -p '#{client_width}' 2>/dev/null || echo 80)
  local lines=$(tmux display-message -p '#{client_height}' 2>/dev/null || echo 24)
  case "$cols$lines" in *[!0-9]*) cols=80; lines=24;; esac
  [ "$lines" -gt 2 ] && lines=$((lines-1))
  local view="__claude_view_$$_$(date +%s)"
  local ph=$(tmux new-session -d -s "$view" -x "$cols" -y "$lines" \
    sh -c 'printf "\n  \033[2m%s\033[0m\n  \033[2m%s\033[0m\n" "pane $1 is open in popup" "关闭弹窗后自动归位" ; while :; do sleep 3600; done' placeholder "$pane" \
    \; display-message -p -t "=$view:" '#{pane_id}' 2>/dev/null) || return 1
  [ -n "$ph" ] || { tmux kill-session -t "=$view" 2>/dev/null; return 1; }
  tmux swap-pane -d -s "$pane" -t "$ph" 2>/dev/null || { tmux kill-session -t "=$view" 2>/dev/null; return 1; }
  local sock="${TMUX%%,*}" rc=0
  if [ -S "$sock" ]; then TMUX= tmux -S "$sock" attach -t "=$view" 2>/dev/null; rc=$?
  else tmux attach -t "=$view" 2>/dev/null; rc=$?; fi
  tmux swap-pane -d -s "$pane" -t "$ph" 2>/dev/null || tmux break-pane -d -s "$pane" -t "=$session:" 2>/dev/null || true
  tmux kill-session -t "=$view" 2>/dev/null
  return $rc
}
