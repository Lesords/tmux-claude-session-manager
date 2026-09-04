# tmux-claude-session-manager

[![screenshot](./docs/screenshot.jpg)](https://youtu.be/NnTV6r4l5D0)

Run many [Claude Code](https://claude.com/claude-code) sessions across your
projects, each in its own tmux session — then **list them, see which are done
vs. still working, and jump to one** from a single popup.

If you launch Claude per-directory (one nested session per project), you quickly
end up with a dozen of them and no way to tell which are finished without opening
each one. This plugin gives you:

- 🔢 **A central picker** (`C-M-s`) listing every running Claude agent —
  several in one project, and any running loose in an ordinary pane.
- 🟢 **Live status** per agent — waiting / running / background / idle — read
  from the `@pane_*` options that tmux-agent-sidebar maintains, so you
  instantly see which need you.
- 👁️ **A live preview** of each agent's screen right in the picker.
- 🎯 **Smart jump** — selecting an agent switches your client to the window it
  was launched from, then resumes it in a popup over it.
- 🚀 **A launcher** (`prefix` + `y`) that opens/attaches a Claude session for the
  current directory.
- ❌ **Quick kill** (`ctrl-x`) of a finished agent from the picker.

Status needs no polling from this plugin: tmux-agent-sidebar's hooks keep each
agent's state in tmux pane options, and the picker reads them in one call.

## Prerequisites

- **tmux ≥ 3.2** (for `display-popup`)
- **[fzf](https://github.com/junegunn/fzf)** — the picker UI
- **[Claude Code](https://claude.com/claude-code)** — the sessions this plugin
  launches
- **GNU awk (gawk)** with a UTF-8 locale — the picker's column alignment
  counts CJK/fullwidth characters as 2 terminal cells; byte-oriented awks
  such as mawk miscount them
- bash; macOS or Linux

Agent status (`working` / `waiting` / `idle`) is read from the `@pane_*`
options maintained by tmux-agent-sidebar; without that plugin the picker
still works, but every agent shows an unknown status.

## Install (tpm)

Add to `~/.tmux.conf` (or `~/.config/tmux/tmux.conf`):

```tmux
set -g @plugin 'craftzdog/tmux-claude-session-manager'
```

Then hit `prefix` + <kbd>I</kbd> to install.

> **Keybinding note:** by default the plugin binds `prefix` + `y` (launch) and
> `C-M-s` (list, no prefix required). If your config binds those elsewhere, either change the
> options below, or make sure the plugin loads **after** your own bindings (put
> `run '~/.tmux/plugins/tpm/tpm'` _after_ them) so the one you want wins.

### Manual install

```sh
git clone https://github.com/craftzdog/tmux-claude-session-manager ~/clone/path
```

Add to `~/.tmux.conf`, then reload (`prefix` + <kbd>r</kbd> or `tmux source ~/.tmux.conf`):

```tmux
run-shell ~/clone/path/claude_session_manager.tmux
```

## Usage

| Key            | Action                                                                          |
| -------------- | ------------------------------------------------------------------------------- |
| `prefix` + `y` | Launch (or re-attach to) a Claude session for the current directory, in a popup |
| `C-M-s`        | Open the agent picker                                                           |

Inside the picker:

| Key                       | Action                                                |
| ------------------------- | ----------------------------------------------------- |
| `enter`                   | Jump to the agent (see [How it works](#how-it-works)) |
| `ctrl-x`                  | Kill the highlighted agent                            |
| `ctrl-r`                  | Refresh the preview now                               |
| `↑` / `↓`, type to filter | fzf navigation                                        |

`waiting` agents sort to the top; `idle` ones sink to the bottom.

The list styling follows tmux-scout: a colored status dot with `WAIT` (red —
needs your input) / `BUSY` (yellow — working) / `BG` (grey — detached
background run) / `IDLE` (green — parked at the prompt) / `?` (grey —
unknown), then AGENT (product name in brand color), WINDOW (tmux window
name), PROJECT (directory basename), TITLE (last prompt or response)
columns, and a relative age at the end of each row.

Every running Claude gets its own row — the picker identifies each by its process,
not by its tmux session. So several agents in one project all show up separately,
as does a Claude you started by hand in an ordinary pane.

## Options

Set any of these before the plugin loads (defaults shown):

```tmux
set -g @claude_launch_key     'y'        # prefix key: launch/open for current dir
set -g @claude_list_key       'C-M-s'    # no-prefix key: open the picker
set -g @claude_command        'claude'   # command run in new sessions
set -g @claude_args           ''         # extra args appended to the command
set -g @claude_session_prefix 'claude-'  # tmux session name prefix
set -g @claude_popup_width     '90%'     # popup width (launch & picker popups)
set -g @claude_popup_height    '90%'     # popup height (launch & picker popups)
set -g @claude_fzf_options    ''         # extra options passed to the fzf picker
set -g @claude_preview_refresh 0.5       # seconds between preview auto-refreshes; 0 = off
set -g @claude_debug          ''         # any non-empty value logs to /tmp/claude-session-manager.log
```

The picker popup border uses `#{@selected}` when a theme plugin defines it.

For example, to skip permission prompts in launched sessions:

```tmux
set -g @claude_args '--dangerously-skip-permissions'
```

### Customizing the fzf picker

`@claude_fzf_options` is passed straight to `fzf`, so you can add your own bindings.

Here is a vim keybinding example:

```tmux
set -g @claude_fzf_options "\
  --prompt 'nav> ' \
  --bind 'j:down' \
  --bind 'k:up' \
  --bind 'q:abort' \
  --bind 'x:execute-silent(kill {3})+reload(sleep 0.3; \$CLAUDE_PICKER --list)' \
  --bind 'i:unbind(j,k,q,i,a,x)+change-prompt(filter> )' \
  --bind 'a:unbind(j,k,q,i,a,x)+change-prompt(filter> )' \
  --bind 'esc:rebind(j,k,q,i,a,x)+change-prompt(nav> )'"
```

The picker opens in **nav** mode:

| Key       | Action                                                  |
| --------- | ------------------------------------------------------- |
| `j` / `k` | move down / up                                          |
| `i` / `a` | switch to **filter** mode — type to fuzzy-match         |
| `x`       | kill the highlighted agent (like the built-in `ctrl-x`) |
| `q`       | close the picker                                        |
| `enter`   | jump to the agent (both modes)                          |
| `esc`     | filter mode → back to nav                               |

Only the bound keys are special in nav mode; any other key still filters as you
type. `x` reloads the list through `$CLAUDE_PICKER`, a path the picker exports for
exactly this — write it as `\$CLAUDE_PICKER` inside the double-quoted value above
so tmux stores a literal `$` (in a single-quoted value, use a bare
`$CLAUDE_PICKER`).

## How it works

- The **launcher** creates a detached `claude-<hash-of-dir>` tmux session running
  `claude`, records the window it came from in `@claude_origin`, and attaches to
  it in a popup.
- The **`@pane_*` pane options** that tmux-agent-sidebar maintains are the
  source of truth for what is running and how it is doing: each agent's hooks
  write `@pane_agent`, `@pane_status`, `@pane_prompt`, … straight into tmux,
  and the picker reads them all in a single `list-panes` call.
- **`agents.sh`** identifies agent panes by `@pane_agent` rather than by
  scanning processes, so several agents in one project each get their own row.
  A single `ps` sweep joins pane tty → pid only to recover the `ctrl-x` kill
  target.
- The **age column** is the time since the agent's last event:
  `@pane_started_at` while mid-turn, falling back to the notification-run
  stamp on lifecycle events — whichever is newer. A pane with neither shows
  `-`.
- The **picker** renders those rows with a live `capture-pane` preview. On `enter`
  a **dedicated** agent (in a `claude-*` session) resumes in the popup over the
  window it was launched from, while a **loose** one (any other pane) is focused in
  place. `ctrl-x` kills the Claude process itself: a dedicated session dies with
  its last window, and a loose pane keeps the shell that hosted it.
- Pressing `C-M-s` **from inside a session popup** detaches that popup
  first (closing it), then reopens the picker full-size on the outer host client —
  so you never end up with a cramped popup-in-popup.

## License

[MIT](LICENSE) © Takuya Matsuyama
