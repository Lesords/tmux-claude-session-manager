# tmux-claude-session-manager

[![screenshot](./docs/screenshot.jpg)](https://youtu.be/NnTV6r4l5D0)

Run many [Claude Code](https://claude.com/claude-code) sessions across your
projects — each in its own tmux pane — then **list them, see which are done
vs. still working, and jump to one** from a single popup.

If you run Claude per-project (one in each pane), you quickly end up with a
dozen of them and no way to tell which are finished without opening each one.
This plugin gives you:

- 🔢 **A central picker** (`prefix` + `u`) listing **every** Claude running in
  any tmux pane — whether started directly or via the launcher below. Other
  users' Claude and non-tmux processes are auto-excluded.
- 🟢 **Live status** per pane — `working` / `waiting` / `idle` — driven by
  Claude Code hooks, so you instantly see which need you.
- 👁️ **A live preview** of each pane's screen right in the picker.
- 🎯 **Smart jump** — selecting a pane switches your client to its window and
  focuses it.
- 🚀 **A launcher** (`prefix` + `y`) that opens/attaches a Claude session for the
  current directory in a popup (optional — panes launched this way are listed
  too).
- ❌ **Quick kill** (`ctrl-x`) of the highlighted pane's Claude process
  (SIGTERM; the pane itself is kept).

Status is optional: without the hooks the picker still lists, previews, jumps,
and kills — panes just show `?` instead of a color.

## Prerequisites

- **tmux ≥ 3.2** (for `display-popup`)
- **[fzf](https://github.com/junegunn/fzf)** — the picker UI
- **[Claude Code](https://claude.com/claude-code)** CLI (the `claude` command)
- bash; macOS or Linux

## Install (tpm)

Add to `~/.tmux.conf` (or `~/.config/tmux/tmux.conf`):

```tmux
set -g @plugin 'craftzdog/tmux-claude-session-manager'
```

Then hit `prefix` + <kbd>I</kbd> to install.

> **Keybinding note:** by default the plugin binds `prefix` + `y` (launch) and
> `prefix` + `u` (list). If your config binds those elsewhere, either change the
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
| `prefix` + `u` | Open the session picker                                                         |

Inside the picker:

| Key                       | Action                                                              |
| ------------------------- | ------------------------------------------------------------------- |
| `enter`                   | Jump to the pane (switches client to its window, focuses the pane)  |
| `ctrl-x`                  | Kill the highlighted pane's Claude process (SIGTERM; pane kept)     |
| `↑` / `↓`, type to filter | fzf navigation                                                      |

Panes needing your attention (`waiting`, `idle`) sort to the top.

## Status setup (optional, recommended)

Status comes from [Claude Code hooks](https://code.claude.com/docs/en/hooks)
that write each pane's state to a tiny per-pane file (named by `pane_id`, e.g.
`%4`, under `$XDG_RUNTIME_DIR/claude-pane-state-$UID/`). One file per pane keeps
multiple Claude instances in the same session independent, and the picker reads
them with zero tmux round-trips. Add the following to your Claude Code settings
(`~/.claude/settings.json`), merging into any existing `hooks` block. Adjust
the path if your plugins live elsewhere (e.g. `~/.tmux/plugins/...`):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.config/tmux/plugins/tmux-claude-session-manager/scripts/state.sh working"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.config/tmux/plugins/tmux-claude-session-manager/scripts/state.sh waiting"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.config/tmux/plugins/tmux-claude-session-manager/scripts/state.sh waiting"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.config/tmux/plugins/tmux-claude-session-manager/scripts/state.sh idle"
          }
        ]
      }
    ]
  }
}
```

The state machine:

| Event                            | State        | Meaning                   |
| -------------------------------- | ------------ | ------------------------- |
| `UserPromptSubmit`               | 🔴 `working` | Busy — leave it           |
| `Notification` (permission)      | 🟡 `waiting` | Needs permission          |
| `PreToolUse` (`AskUserQuestion`) | 🟡 `waiting` | Asking you a question     |
| `Stop`                           | 🟢 `idle`    | Turn finished — your move |

> Claude Code reloads `hooks` dynamically — no restart needed. Panes that are
> already running Claude start reporting status on their next event once the
> hooks are added.

## Options

Set any of these before the plugin loads (defaults shown):

```tmux
set -g @claude_launch_key     'y'        # prefix key: launch/open for current dir
set -g @claude_list_key       'u'        # prefix key: open the picker
set -g @claude_command        'claude'   # command run in new sessions
set -g @claude_args           ''         # extra args appended to the command
set -g @claude_session_prefix 'claude-'  # session name prefix (launcher only)
set -g @claude_popup_width     '90%'     # popup width
set -g @claude_popup_height    '90%'     # popup height
```

> `@claude_session_prefix` is used only by the **launcher** (it names the
> detached session it creates). The **picker** does not depend on it — it
> discovers Claude by process name (`comm == claude`) across all panes.

For example, to skip permission prompts in launched sessions:

```tmux
set -g @claude_args '--dangerously-skip-permissions'
```

## How it works

- The **picker** scans every tmux pane across all sessions. `ps` lists the
  whole process table once; an `awk` pass walks each `claude` process's
  parent-PID chain until it hits a tmux `pane_pid` — that pins which pane the
  Claude belongs to. Claude not running under this tmux server (other users,
  plain terminals) never matches, so it's auto-excluded.
- The **hooks** write `@claude_state` / timestamp to a per-pane **file** (named
  by `pane_id`) as Claude works, so several Claude instances in the same
  session keep independent states and the picker reads them with no tmux calls.
- The **launcher** (optional) creates a detached `claude-<hash-of-dir>` tmux
  session running `claude`, records the window it came from in `@claude_origin`,
  and attaches to it in a popup. Its single pane is discovered by the picker
  like any other.
- On **enter**, the picker moves your client to the chosen pane's window
  (`window_id` is global across sessions) and focuses the pane — the Claude is
  already running there, so nothing is re-attached or re-popped.
- Pressing `prefix` + `u` **from inside a launcher popup** detaches that popup
  first (closing it), then reopens the picker full-size on the outer host
  client — so you never end up with a cramped popup-in-popup.

## License

[MIT](LICENSE) © Takuya Matsuyama
