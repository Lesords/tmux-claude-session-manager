#!/usr/bin/env bash
# Emit one picker row per running Claude that lives in a tmux pane.
#
# Claude self-reports its status: each session writes its own state to disk and a
# supervisor daemon aggregates it, which `claude agents --json` publishes. So this
# needs no Claude Code hooks, and no `pane_current_command` scan — on macOS a pane
# reports its parent shell there, never the `claude` child running inside it.
#
# Identity is the Claude process, not the tmux session. Joining pid -> tty -> pane
# is what lets several Claudes in one project (same cwd, same session, different
# windows) each get a row of their own.
#
#   Row: rank \t pane_id \t pid \t kind \t age_min \t status \t agent \t
#        window \t project \t title \t age_disp
#   Fields 1-5 are hidden via fzf's --with-nth=6..11 — the visible fields
#   stay consecutive so every column gap is one space (a hidden field between
#   two shown ones leaves a double gap). age_disp ("45s"/"5m"/"2h") ends the
#   line.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

agents="$(claude agents --json 2>/dev/null)" || exit 0
rows="$(printf '%s' "$agents" |
  jq -r '.[] | select(.kind == "interactive") | [.pid, .status, .sessionId, .cwd, .name] | @tsv' 2>/dev/null)"
[ -n "$rows" ] || exit 0

# Resolved out here because only `stat`, outside awk, can read an mtime.
mtimes="$(printf '%s\n' "$rows" | cut -f3 | while IFS= read -r sid; do
  printf 'M\t%s\t%s\n' "$sid" "$(claude_transcript_mtime "$sid")"
done)"

# Three tagged streams into one awk: pid->tty, tty->pane, session->last-activity.
# Total cost is 3 subprocesses regardless of how many sessions or panes exist.
stream=$(
  ps -Ao pid=,tty= 2>/dev/null | awk '{ print "P\t" $1 "\t" $2 }'
  tmux list-panes -a -F $'T\t#{pane_tty}\t#{pane_id}\t#{session_name}\t#{window_name}' 2>/dev/null
  printf '%s\n' "$mtimes"
  printf '%s\n' "$rows" | sed $'s/^/A\t/'
)

# Column widths adapt to the data: pw/tw/nw = longest project basename (floor
# 7) / agent name (cap 50) / window name. Nothing pads past its longest value,
# so no column shows a wide gap of trailing spaces.
read -r pw tw nw < <(printf '%s\n' "$stream" | awk -F'\t' '
  $1 == "A" { n = split($5, seg, "/"); if (length(seg[n]) > w) w = length(seg[n])
              if (length($6) > t) t = length($6) }
  $1 == "T" { if (length($5) > n_) n_ = length($5) }
  END { print (w<7?7:w), (t>50?50:t<1?1:t), (n_<1?1:n_) }')

# Fit to the popup width: tput on /dev/tty gives the REAL width (popups are
# not tmux clients, #{client_width} would report the outer one). WINDOW gets
# its natural width (cap 20), TITLE the rest (cap 50); when tight, WINDOW
# shrinks first (floor 8). Unknown width (9999) just skips the squeezing.
cw="$(tput cols 2>/dev/null </dev/tty || tmux display-message -p '#{client_width}' 2>/dev/null || echo 9999)"
free=$((cw - 22 - pw))                       # fixed cols + joins: dot+STAT/AGENT/AGE/quotes
win_w=$nw; [ "$win_w" -gt 20 ] && win_w=20
tmax=$((free - win_w)); [ "$tmax" -gt 50 ] && tmax=50
if [ "$tmax" -lt 10 ]; then
  win_w=$((free - 10)); [ "$win_w" -lt 8 ] && win_w=8; [ "$win_w" -gt "$nw" ] && win_w=$nw
  tmax=$((free - win_w)); [ "$tmax" -lt 1 ] && tmax=1
fi
[ "$tw" -gt "$tmax" ] && tw=$tmax

sorted=$(printf '%s\n' "$stream" | awk -F'\t' -v now="$(date +%s)" -v home="$HOME" -v pw="$pw" -v tw="$tw" -v winn="$win_w" -v me="$(tmux display-message -p '#{session_name}' 2>/dev/null)" \
  -v prefix="$(get_tmux_option @claude_session_prefix 'claude-')" \
  -v pp="$(get_tmux_option @claude_popup_prefix 'floax-')" '
  $1 == "P" { tty_of[$2] = $3; next }
  $1 == "T" { sub(/^\/dev\//, "", $2); pane[$2] = $3; sess[$2] = $4; wname[$2] = $5; next }
  $1 == "M" { seen_at[$2] = $3; next }
  $1 == "A" {
    tty = tty_of[$2]
    if (tty == "" || !(tty in pane)) next   # this Claude is not running inside tmux

    # Status: colored dot + white label. The dot carries the traffic-light
    # color (red = needs you, green = done, yellow = working, grey = ?); the
    # label stays white for readability on any background.
    if      ($3 == "waiting") { icon = "\033[1;31m●\033[0m \033[37mWAIT\033[0m"; rank = 0 }
    else if ($3 == "idle")    { icon = "\033[32m●\033[0m \033[37mIDLE\033[0m"; rank = 1 }
    else if ($3 == "busy")    { icon = "\033[33m●\033[0m \033[37mBUSY\033[0m"; rank = 3 }
    else                      { icon = "\033[90m●\033[0m \033[37m?\033[0m  "; rank = 2 }

    age = "-" ; disp = "-"                                   # sort minutes / display
    if (seen_at[$4] != "") {
      s = now - seen_at[$4]
      age = int(s / 60)
      disp = (s < 60) ? s "s" : (s < 3600) ? int(s/60) "m" : int(s/3600) "h"
    }
    # dedicated: plugin/floax-launched session, resumed in-place by the
    # picker. pp guard: index(x,"")==1 matches all.
    kind = ((index(sess[tty], prefix) == 1) || (pp != "" && index(sess[tty], pp) == 1)) ? "dedicated" : "loose"

    ag = "\033[38;5;173mclaude\033[0m"   # AGENT: product name; only claude here

    path = $5
    if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

    # TITLE: cut and padded to tw (escapes outside the padding) so AGE aligns.
    t = $6
    if (length(t) > tw) t = substr(t, 1, tw - 1) "~"
    t = "\033[2m\"" sprintf("%-" tw "s", t) "\"\033[0m"

    # Visible fields 6..11; field 5 (sort minutes) hidden. WINDOW cut to
    # winn, PROJECT never cut. Same-session windows are bold white (bold,
    # not bright — 97 degrades to plain 37 on palettes without bright
    # colors), cross-session ones dim grey.
    win = (wname[tty] != "") ? wname[tty] : "-"
    if (length(win) > winn) win = substr(win, 1, winn - 1) "~"
    wc = (sess[tty] == me) ? "1;37" : "90"
    proj = pseg[split(path, pseg, "/")]
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t\033[" wc "m%-" winn "s\033[0m\t\033[37m%-" pw "s\033[0m\t%s\t\033[2m%3s\033[0m\n",
      rank, pane[tty], $2, kind, age, icon, ag, win, proj, t, disp
  }
' | sort -t$'\t' -k1,1n -k5,5n)
# rank asc (what needs you floats up), then age asc so whatever just went idle
# sits at the top of its group. -k5,5n reads the leading number of the hidden
# age field ("5m" -> 5; "-" -> 0).

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' '' '' '' '' '' '  STAT' 'AGENT ' "$(printf '%-*s' "$win_w" WINDOW)" "$(printf '%-*s' "$pw" PROJECT)" "$(printf '%-*s' "$((tw + 2))" TITLE)" 'AGE'
[ -n "$sorted" ] && printf '%s\n' "$sorted"
