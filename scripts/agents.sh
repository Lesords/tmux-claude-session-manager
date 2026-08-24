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
# guaranteed collision-free there. Two things still split fields: tabs in
# @pane_prompt (sidebar strips | and \n but not \t) and "|" in a window or
# session name (user-renamed, nobody sanitizes those). A repair pass folds
# the stray fragments back into field 6 by anchoring on the fixed leading 5
# and trailing 6 columns. Rows handed to fzf are rebuilt with tabs.
stream=$(
  {
    ps -Ao pid=,tty=,comm= 2>/dev/null | awk '$3 ~ /^(claude|opencode|codex)/ { print "P\t" $1 "\t" $2 }'
    tmux list-panes -a -F '#{pane_id}|#{@pane_agent}|#{@pane_status}|#{@pane_cwd}|#{@pane_prompt}|#{@pane_started_at}|#{session_name}|#{window_name}|#{pane_tty}|#{@pane_wait_reason}|#{@pane_notification_run_id}' 2>/dev/null | tr '|' '\t' | sed $'s/^/T\t/'
  } | awk -F'\t' -v OFS='\t' '
       $1 == "P" { if (NF > 3) { c = $3; for (i = 4; i <= NF; i++) c = c " " $i; $3 = c } print; next }
       $1 == "T" {
         if (NF > 12) {
           head = $6;  for (i = 7; i <= NF - 6; i++) head = head " " $i
           tail = $(NF - 5);  for (i = NF - 4; i <= NF; i++) tail = tail "\t" $i
           $0 = $1 FS $2 FS $3 FS $4 FS $5 FS head FS tail
         }
         print }'
)

# Adaptive column widths: project basename (floor 7), agent name (floor 6),
# window name. Title is a fixed 30 (+2 quotes). Widths are DISPLAY widths —
# CJK/fullwidth chars occupy 2 terminal cells, so plain length() would pad
# short and skew every column to the right.
tw=30
read -r pw nw aw < <(printf '%s\n' "$stream" | awk -F'\t' '
  function dwidth(s,   i, n, w, c) {          # terminal cells a string occupies
    w = 0; n = length(s)
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      w += (c ~ /[　-〿ぁ-ヿ一-鿿㐀-䶿가-힣豈-﫻！-｠]/) ? 2 : 1
    }
    return w
  }
  $1 == "T" && $3 != "" { n = split($5, seg, "/"); if ((l = dwidth(seg[n])) > w) w = l
                          if ((l = dwidth($3)) > a) a = l }
  $1 == "T" { if ((l = dwidth($9)) > n_) n_ = l }
  END { print (w<7?7:w), (n_<1?1:n_), (a<6?6:a) }')

# Fit to the popup width: tput on /dev/tty gives the REAL width (popups are
# not tmux clients, #{client_width} would report the outer one). When tight,
# WINDOW shrinks first (floor 8); unknown width (9999) skips the squeezing.
cw="$(tput cols 2>/dev/null </dev/tty || tmux display-message -p '#{client_width}' 2>/dev/null || echo 9999)"
win_w=$nw; [ "$win_w" -gt 20 ] && win_w=20
[ "$win_w" -lt 6 ] && win_w=6    # never narrower than the WINDOW label itself
if [ "$cw" -lt 9999 ]; then
  max_win=$((cw - pw - aw - 45))    # STAT + TITLE + AGE + gaps take the rest
  [ "$win_w" -gt "$max_win" ] && win_w=$max_win
  [ "$win_w" -lt 8 ] && win_w=8
fi

sorted=$(printf '%s\n' "$stream" | awk -F'\t' \
  -v now="$(date +%s)" -v home="$HOME" -v pw="$pw" -v tw="$tw" -v winn="$win_w" -v aw="$aw" \
  -v prefix="$(get_tmux_option @claude_session_prefix 'claude-')" \
  -v pp="$(get_tmux_option @claude_popup_prefix 'floax-')" '
  # Display-width helpers: CJK/fullwidth chars fill 2 terminal cells, so all
  # column math below runs on cells, not characters.
  function dwc(c) { return (c ~ /[　-〿ぁ-ヿ一-鿿㐀-䶿가-힣豈-﫻！-｠]/) ? 2 : 1 }
  function dwidth(s,   i, n, w) { w = 0; n = length(s)
    for (i = 1; i <= n; i++) w += dwc(substr(s, i, 1)); return w }
  function dpad(s, w,   k) { k = w - dwidth(s); while (k-- > 0) s = s " "; return s }
  function dcut(s, maxw, suf,   i, n, c, out, w, cw) {
    if (dwidth(s) <= maxw) return s
    out = ""; w = 0; n = length(s); maxw -= length(suf)
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1); cw = dwc(c)
      if (w + cw > maxw) break
      out = out c; w += cw
    }
    return out suf
  }
  $1 == "P" { if (!($3 in pid_of)) pid_of[$3] = $2; next }        # tty -> pid
  $1 == "T" {
    if ($3 == "") next                        # not an agent pane
    tty = $10; sub(/^\/dev\//, "", tty)

    # Status: colored dot + white label (red = needs you, yellow = working,
    # grey = detached background run, green = parked at the prompt).
    # Rank orders the list: waiting first (actionable), running next (live),
    # parked sessions sink.
    if      ($4 == "waiting")    { icon = "\033[1;31m●\033[0m \033[37mWAIT\033[0m"; rank = 0 }
    else if ($4 == "running")    { icon = "\033[33m●\033[0m \033[37mBUSY\033[0m"; rank = 1 }
    else if ($4 == "background") { icon = "\033[90m●\033[0m \033[37mBG\033[0m  "; rank = 2 }
    else if ($4 == "idle")       { icon = "\033[32m●\033[0m \033[37mIDLE\033[0m"; rank = 3 }
    else                         { icon = "\033[90m●\033[0m \033[37m?\033[0m  "; rank = 2 }

    # Age since the last agent event ("45s"/"5m"/"2h"); sort minutes in
    # field 5. started_at only exists mid-turn, so fall back to the
    # notification-run stamp (epoch ms, refreshed on lifecycle events) and
    # take whichever is newer.
    age = "-" ; disp = "-" ; mins = 99999
    ts = 0
    if ($7 ~ /^[0-9]+$/) ts = $7
    if ($12 ~ /^[0-9]+$/ && int($12 / 1000) > ts) ts = int($12 / 1000)
    if (ts > 0) {
      s = now - ts; if (s < 0) s = 0
      mins = int(s / 60)
      disp = (s < 60) ? s "s" : (s < 3600) ? int(s/60) "m" : int(s/3600) "h"
    }

    kind = ((index($8, prefix) == 1) ||
            (pp != "" && index($8, pp) == 1)) ? "dedicated" : "loose"

    win = dpad(dcut(($9 != "") ? $9 : "-", winn - 1, "~"), winn)

    ag = "\033[38;5;173m" dpad($3, aw) "\033[0m"

    path = $5
    if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)
    proj = dpad(pseg[split(path, pseg, "/")], pw)

    # Title: last prompt/response; fall back to the wait reason ("session_resumed")
    # for resumed sessions that never recorded one.
    t = $6; gsub(/[\t\n\r]/, " ", t)
    if (t == "") { t = $11; gsub(/[\t\n\r]/, " ", t) }
    if (t == "") t = "-"
    t = "\033[2m\"" dpad(dcut(t, tw - 3, "..."), tw) "\"\033[0m"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t\033[37m%s\033[0m\t\033[37m%s\033[0m\t%s\t\033[2m%s\033[0m\n",
      rank, $2, pid_of[tty], kind, mins, icon, ag, win, proj, t, dpad(disp, 4)
  }
' | sort -t$'\t' -k1,1n -k5,5n)
# rank asc (what needs you floats up), then least-recently-started first within
# each rank group ("-"/unknown sinks last at 99999).

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' '' '' '' '' '' '  STAT' \
  "$(printf '%-*s' "$aw" AGENT)" "$(printf '%-*s' "$win_w" WINDOW)" \
  "$(printf '%-*s' "$pw" PROJECT)" "$(printf '%-*s' $((tw + 2)) TITLE)" 'AGE '
[ -n "$sorted" ] && printf '%s\n' "$sorted"
