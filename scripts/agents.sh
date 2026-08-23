#!/usr/bin/env bash
# Emit one picker row per agent pane, reading the state that tmux-agent-sidebar's
# hooks write into tmux pane options (@pane_agent, @pane_status, ...).
#
# Data flow: agent hooks -> pane options -> ONE list-panes call here. Panes
# without @pane_agent are not agent panes. Sidebar stores no pid, so ctrl-x's
# kill target is recovered by joining one ps scan on the pane tty.
#
#   Row: rank \t pane_id \t pid \t kind \t age_min \t status \t agent \t
#        window \t project \t title \t age_disp
#   Fields 1-5 are hidden via fzf's --with-nth=6..11; picker.sh previews {2}
#   (pane) and kills {3} (pid), so those positions are load-bearing.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# Intermediate stream is |-separated: sidebar's own writer strips "|" from
# every @pane_* value it stores (sanitize_tmux_value), so the separator is
# guaranteed collision-free there. A repair pass afterwards folds any stray
# tab-split fragments (prompt text) back into their field by anchoring on the
# fixed leading/trailing columns. Rows handed to fzf are rebuilt with tabs.
stream=$(
  {
    ps -Ao pid=,tty=,comm= 2>/dev/null | awk '$3 ~ /^(claude|opencode|codex)/ { print "P\t" $1 "\t" $2 }'
    tmux list-panes -a -F '#{pane_id}|#{@pane_agent}|#{@pane_status}|#{@pane_cwd}|#{@pane_prompt}|#{@pane_started_at}|#{session_name}|#{window_name}|#{pane_tty}' 2>/dev/null | tr '|' '\t' | sed $'s/^/T\t/'
  } | awk -F'\t' -v OFS='\t' '$1 == "P" { if (NF > 3) { c = $3; for (i = 4; i <= NF; i++) c = c " " $i; $3 = c } print; next }
       $1 == "T" { if (NF > 10) { m = $6; for (i = 7; i <= NF - 4; i++) m = m " "; $6 = m; NF = 10 } print }'
)

# Adaptive column widths: project basename (floor 7), agent name (floor 6),
# window name. Title is a fixed 30 (+2 quotes).
tw=30
read -r pw nw aw < <(printf '%s\n' "$stream" | awk -F'\t' '
  $1 == "T" && $3 != "" { n = split($5, seg, "/"); if (length(seg[n]) > w) w = length(seg[n])
                          if (length($3) > a) a = length($3) }
  $1 == "T" { if (length($9) > n_) n_ = length($9) }
  END { print (w<7?7:w), (n_<1?1:n_), (a<6?6:a) }')

# Fit to the popup width: tput on /dev/tty gives the REAL width (popups are
# not tmux clients, #{client_width} would report the outer one). When tight,
# WINDOW shrinks first (floor 8); unknown width (9999) skips the squeezing.
cw="$(tput cols 2>/dev/null </dev/tty || tmux display-message -p '#{client_width}' 2>/dev/null || echo 9999)"
win_w=$nw; [ "$win_w" -gt 20 ] && win_w=20
if [ "$cw" -lt 9999 ]; then
  max_win=$((cw - pw - aw - 45))    # STAT + TITLE + AGE + gaps take the rest
  [ "$win_w" -gt "$max_win" ] && win_w=$max_win
  [ "$win_w" -lt 8 ] && win_w=8
fi

sorted=$(printf '%s\n' "$stream" | awk -F'\t' \
  -v now="$(date +%s)" -v home="$HOME" -v pw="$pw" -v tw="$tw" -v winn="$win_w" -v aw="$aw" \
  -v prefix="$(get_tmux_option @claude_session_prefix 'claude-')" \
  -v pp="$(get_tmux_option @claude_popup_prefix 'floax-')" '
  $1 == "P" { if (!($3 in pid_of)) pid_of[$3] = $2; next }        # tty -> pid
  $1 == "T" {
    if ($3 == "") next                        # not an agent pane
    tty = $10; sub(/^\/dev\//, "", tty)

    # Status: colored dot + white label (red = needs you, green = idle,
    # yellow = working, grey = detached background run).
    if      ($4 == "waiting")    { icon = "\033[1;31m●\033[0m \033[37mWAIT\033[0m"; rank = 0 }
    else if ($4 == "idle")       { icon = "\033[32m●\033[0m \033[37mIDLE\033[0m"; rank = 1 }
    else if ($4 == "running")    { icon = "\033[33m●\033[0m \033[37mBUSY\033[0m"; rank = 3 }
    else if ($4 == "background") { icon = "\033[90m●\033[0m \033[37mBG\033[0m  "; rank = 2 }
    else                         { icon = "\033[90m●\033[0m \033[37m?\033[0m  "; rank = 2 }

    # Age since the agent turn started ("45s"/"5m"/"2h"); sort minutes in field 5.
    age = "-" ; disp = "-" ; mins = 99999
    if ($7 ~ /^[0-9]+$/ && $7 > 0) {
      s = now - $7; if (s < 0) s = 0
      mins = int(s / 60)
      disp = (s < 60) ? s "s" : (s < 3600) ? int(s/60) "m" : int(s/3600) "h"
    }

    # dedicated: plugin/floax-launched session, resumed in-place by the picker;
    # anything else is focused where it lives.
    kind = ((index($8, prefix) == 1) ||
            (pp != "" && index($8, pp) == 1)) ? "dedicated" : "loose"

    win = ($9 != "") ? $9 : "-"
    if (length(win) > winn) win = substr(win, 1, winn - 1) "~"

    ag = "\033[38;5;173m" sprintf("%-" aw "s", $3) "\033[0m"

    path = $5
    if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)
    proj = pseg[split(path, pseg, "/")]

    t = $6; gsub(/[\t\n\r]/, " ", t)
    if (t == "") t = "-"
    if (length(t) > tw) t = substr(t, 1, tw - 3) "..."
    t = "\033[2m\"" sprintf("%-" tw "s", t) "\"\033[0m"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t\033[37m%-" winn "s\033[0m\t\033[37m%-" pw "s\033[0m\t%s\t\033[2m%3s\033[0m\n",
      rank, $2, pid_of[tty], kind, mins, icon, ag, win, proj, t, disp
  }
' | sort -t$'\t' -k1,1n -k5,5n)
# rank asc (what needs you floats up), then least-recently-started first within
# each rank group ("-"/unknown sinks last at 99999).

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' '' '' '' '' '' '  STAT' \
  "$(printf '%-*s' "$aw" AGENT)" "$(printf '%-*s' "$win_w" WINDOW)" \
  "$(printf '%-*s' "$pw" PROJECT)" "$(printf '%-*s' $((tw + 2)) TITLE)" 'AGE'
[ -n "$sorted" ] && printf '%s\n' "$sorted"
