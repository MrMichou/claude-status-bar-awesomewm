# Linux / awesomewm

A port of Claude Status Bar for Linux running the [awesomewm](https://awesomewm.org/)
window manager. Instead of a macOS menu bar app, it's a **wibar widget** that polls
the same `~/.claude/statusbar/state.json` the macOS app uses — so the entire hook
layer is shared and unchanged.

It shows the same things: an animated Claude spark + tool label + live `1m 1s`
timer while Claude works, an amber dot while awaiting permission, and a resting
logo when idle. Optional `naughty` notifications fire on permission requests and
turn completion.

<sub>Developed and tested on <code>awesome v4.3-1700-gcd36f9023</code> — a git-master
build (≈4.4-dev), compiled against Lua 5.4.8, API level 4. Should work on any
Awesome 4.3+ (it uses <code>awful.keyboard.append_global_keybindings</code>,
<code>awful.popup</code>, and <code>lgi.cairo</code>, all available since 4.3).</sub>

## Requirements

- awesomewm **4.3+** (tested on a git-master build; uses `awful.popup` and
  `append_global_keybindings`, both 4.3+) with `lgi` (the cairo bindings, normally
  bundled with Awesome)
- Node.js (the Claude Code hooks use it — same as macOS)
- Claude Code (CLI or Desktop)

## Install

### 1. Install the hooks

Install the project as a Claude Code plugin so the hooks write `state.json`:

```
/plugin marketplace add MrMichou/claude-status-bar-awesomewm
/plugin install claude-status-bar-awesomewm@claude-status-bar-awesomewm
```

> Use this fork's repo, **not** the upstream `m1ckc3s/claude-status-bar` — only this
> fork carries the cross-platform hook fixes (the Linux `lifecycle.js` guards).

The hooks (`hooks/update.js`, `hooks/lifecycle.js`) are cross-platform — on Linux
the macOS app-launch step is skipped (the widget is always running inside Awesome),
and session tracking under `~/.claude/statusbar/sessions.d/` still works.

### 2. Generate the icon frames

The animation frames are stored base64-encoded in the macOS Swift sources; extract
them to real PNGs once:

```bash
git clone https://github.com/MrMichou/claude-status-bar-awesomewm
cd claude-status-bar-awesomewm
node tools/extract-frames.js
```

This writes `linux/awesomewm/claude_status/frames/{web,crab}/*.png` and `logo.png`.

### 3. Add the widget to your config

Copy (or symlink) the widget folder into your Awesome config:

```bash
ln -s "$PWD/linux/awesomewm/claude_status" ~/.config/awesome/ui/bar/widgets/claude_status
# or: cp -r linux/awesomewm/claude_status ~/.config/awesome/ui/bar/widgets/
```

> The folder bundles its own `json.lua` decoder and locates its `frames/` relative
> to itself, so it works wherever you place it under the config dir.

Then `require` it and drop it into your wibar. In a typical `wibar:setup` (adjust
the module path to where you placed it):

```lua
local claude_status = require("ui.bar.widgets.claude_status")

-- ... inside your bar layout, e.g. the right-hand group:
{
    -- other widgets ...
    claude_status,
    layout = wibox.layout.fixed.horizontal,
}
```

### 4. Reload Awesome

`Mod + Ctrl + r` (or your reload binding). The widget appears and updates within
~0.4s of any Claude Code activity.

## Menus

- **Left click** — toggle the **active-sessions popup**: every running Claude Code
  session with its project name, current state (colored dot + label) and elapsed time.
- **Right click** — the **settings menu**: pick the animation style (Crab / Spark /
  Claude Code glyphs), toggle the timer, and toggle the permission/done notifications.
  Picks are persisted to `~/.claude/statusbar/widget.json` and override the `cfg`
  defaults, so they survive an Awesome restart. (Changing the style triggers a quick
  Awesome restart, since each style builds its icon differently.)

You can also bind keys — the widget exposes `toggle_sessions_menu()` and
`toggle_settings_menu()`:

```lua
awful.key({ modkey }, "c", function()
  require("ui.bar.widgets.claude_status").toggle_sessions_menu()
end, { description = "Claude sessions", group = "launcher" })
```

The list is built from the session markers in `~/.claude/statusbar/sessions.d/`,
enriched with per-session state written to `~/.claude/statusbar/sessions-state/`.
Both are maintained by the hooks (`update.js` writes, `lifecycle.js` cleans up on
`SessionEnd`).

## Configuration

Edit the `cfg` table at the top of `claude_status/init.lua`:

| Key | Default | Description |
|---|---|---|
| `style` | `"crab"` | `"crab"` (pixel-art crab), `"web"` (Claude spark), or `"code"` (terminal glyph spinner ✻✽✶✳✢) |
| `brand` | `"#d97757"` | Tint color for the spark / logo (alpha-mask frames) |
| `amber` | `"#f2bb2e"` | "Awaiting permission" dot color |
| `icon_size` | `dpi(18)` | Icon height/width |
| `show_timer` | `true` | Show the `1m 1s` elapsed clock |
| `hide_when_idle` | `false` | Hide the widget at idle (vs. resting logo) |
| `notify_permission` | `true` | `naughty` popup on permission requests |
| `notify_done` | `true` | `naughty` popup when a turn finishes |
| `done_min_seconds` | `60` | Only notify "done" for turns at least this long (`0` = always) |
| `sound_cmd` | `nil` | Shell command to play on completion, e.g. `"paplay /usr/share/sounds/freedesktop/stereo/complete.oga"` |
| `poll_seconds` | `0.4` | `state.json` poll interval |

## How it works

The Claude Code hooks write the current status to `~/.claude/statusbar/state.json`.
The widget polls that file every `poll_seconds`, drives a cairo-tinted PNG frame
animation while Claude is thinking / running a tool, swaps to an amber dot for
`permission`, shows the elapsed time, and fires `naughty` notifications on state
transitions. The `web`/`logo` PNGs are alpha masks tinted at load time (the same
approach as the macOS app); the `crab` frames are full color; the `code` style is
a pango-rendered glyph spinner (no images).

Interrupting a turn (Esc) or denying a permission fires **no** hook, so `state.json`
freezes on a live state. Like the macOS app, the widget recovers by detecting the
`interrupted by user` marker at the tail of the session transcript, with an absolute
15-minute age safety net — so it never stays stuck animating or on the amber dot.

## Troubleshooting

- **Nothing shows / stuck on the resting logo:** confirm the hooks are installed
  and writing state: `cat ~/.claude/statusbar/state.json` during a Claude turn.
  Enable hook logging with `CLAUDE_STATUSBAR_DEBUG=1` and check
  `~/.claude/statusbar/hooks.log`.
- **A black square instead of the orange spark:** the frames weren't extracted —
  re-run `node tools/extract-frames.js` and check `frames/web/00.png` exists.
- **`require` error on reload:** check the module path matches where you copied the
  folder, and that `lgi` is available (`echo 'return require("lgi") ~= nil' | awesome-client`).
