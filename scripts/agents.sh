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
#   Row: rank \t pane_id \t pid \t kind \t status \t agent \t window \t
#        project \t title \t age_min \t age_disp
#   Fields 1-4 and 10 (sort minutes) are hidden via fzf's --with-nth=5..9,11;
#   age_disp (tmux-scout shortAge: "45s"/"5m"/"2h") shows at end of line.
#   CLAUDE_ORIGIN_PANE (exported by list.sh) marks the invoking pane with "*".
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

# Column widths adapt to the data: pw = longest project basename (floor 16),
# tw = longest agent name (cap 50) so TITLE padding keeps AGE aligned.
read -r pw tw < <(printf '%s\n' "$stream" | awk -F'\t' '
  $1 == "A" {
    n = split($5, seg, "/"); if (length(seg[n]) > w) w = length(seg[n])
    if (length($6) > t) t = length($6)
  }
  END {
    if (w < 16) w = 16
    if (t > 50) t = 50
    if (t < 1) t = 1
    print w, t
  }')

sorted=$(printf '%s\n' "$stream" | awk -F'\t' -v now="$(date +%s)" -v home="$HOME" -v pw="$pw" -v tw="$tw" -v cur="${CLAUDE_ORIGIN_PANE:-}" \
  -v prefix="$(get_tmux_option @claude_session_prefix 'claude-')" \
  -v pp="$(get_tmux_option @claude_popup_prefix 'floax-')" '
  $1 == "P" { tty_of[$2] = $3; next }
  $1 == "T" { sub(/^\/dev\//, "", $2); pane[$2] = $3; sess[$2] = $4; wname[$2] = $5; next }
  $1 == "M" { seen_at[$2] = $3; next }
  $1 == "A" {
    tty = tty_of[$2]
    if (tty == "" || !(tty in pane)) next   # this Claude is not running inside tmux

    # Status tags styled like tmux-scout list items: fixed-width colored
    # text (red = needs you, yellow = working, blue = idle, grey = unknown).
    if      ($3 == "waiting") { icon = "\033[31mW:WAIT\033[0m"; rank = 0 }  # red    - needs input
    else if ($3 == "idle")    { icon = "\033[34mIDLE  \033[0m"; rank = 1 }  # blue   - done, your turn
    else if ($3 == "busy")    { icon = "\033[33mBUSY  \033[0m"; rank = 3 }  # yellow - busy, leave it
    else                      { icon = "\033[90m?     \033[0m"; rank = 2 }  # grey   - unrecognised status

    age = "-" ; disp = "-"                                   # sort minutes / display
    if (seen_at[$4] != "") {
      s = now - seen_at[$4]
      age = int(s / 60)
      disp = (s < 60) ? s "s" : (s < 3600) ? int(s/60) "m" : int(s/3600) "h"
    }
    # dedicated: a claude-* session this plugin launched, or an external
    # popup-tool session (e.g. tmux-floax floax-*) -- the picker resumes
    # either in-place via attach-session. pp guard: index(x,"")==1 matches all.
    kind = ((index(sess[tty], prefix) == 1) || (pp != "" && index(sess[tty], pp) == 1)) ? "dedicated" : "loose"

    # AGENT: product name in brand color (the data source only lists claude).
    ag = "\033[38;5;173mclaude   \033[0m"

    # Yellow "*" marks the invoking pane; two spaces keep STATUS aligned.
    icon = ((cur != "" && pane[tty] == cur) ? "\033[33m*\033[0m " : "  ") icon

    path = $5
    if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

    # TITLE: claude-reported session name, cut to 50 and padded to tw (the
    # escapes sit outside the padded text) so the trailing AGE lines up.
    t = $6
    if (length(t) > 50) t = substr(t, 1, 49) "~"
    t = "\033[2m\"" sprintf("%-" tw "s", t) "\"\033[0m"

    # Visible fields (--with-nth=5,6,7,8,9,11): STATUS AGENT WINDOW PROJECT
    # TITLE AGE. WINDOW is cut to 20, PROJECT never cut (pw adapts); field 10
    # (sort minutes) stays hidden.
    win = (wname[tty] != "") ? wname[tty] : "-"
    if (length(win) > 20) win = substr(win, 1, 19) "~"
    np = split(path, pseg, "/")
    proj = pseg[np]
    printf "%s\t%s\t%s\t%s\t%s\t%s\t\033[36m%-20s\033[0m\t\033[37m%-" pw "s\033[0m\t%s\t%s\t\033[2m%4s\033[0m\n",
      rank, pane[tty], $2, kind, icon, ag, win, proj, t, age, disp
  }
' | sort -t$'\t' -k1,1n -k10,10n)
# rank asc (what needs you floats up), then age asc so whatever just went idle
# sits at the top of its group. -k10,10n reads the leading number of the hidden
# age field ("5m" -> 5; "-" -> 0).

# Header row, kept by fzf --header-lines=1; widths match the fields above
# (TITLE = tw+2 for the quotes, AGE right-aligned).
title_w=$((tw + 2))
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' '' '' '' '' '  STATUS' 'AGENT    ' 'WINDOW              ' "$(printf '%-*s' "$pw" PROJECT)" "$(printf '%-*s' "$title_w" TITLE)" '' ' AGE'
[ -n "$sorted" ] && printf '%s\n' "$sorted"
