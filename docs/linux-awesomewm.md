# Linux / awesomewm

A port of Claude Status Bar for Linux running the [awesomewm](https://awesomewm.org/)
window manager. Instead of a macOS menu bar app, it's a **wibar widget** that polls
the same `~/.claude/statusbar/state.json` the macOS app uses — so the entire hook
layer is shared and unchanged.

It shows the same things: an animated Claude spark + tool label + live `1m 1s`
timer while Claude works, an amber dot while awaiting permission, and a resting
logo when idle. Optional `naughty` notifications fire on permission requests and
turn completion.

On top of the macOS feature set it also watches the **Anthropic service status**
(the public [Statuspage](https://status.claude.com)): when an incident is live it
shows a **red dot + "Claude down"** with the incident description over whatever the
local session state is, and (optionally) notifies you when the outage starts and
when it clears.

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
- `xprop` (from `xorg-xprop`) — optional, only for click-to-jump-to-window; the menu
  works without it, sessions just won't be clickable
- `xdotool` — optional, only for the **Yes/No** buttons on the permission notification
  (it presses the key in the session's terminal); without it the popup still appears,
  just without the buttons
- `curl` — optional, only for the **Claude service down** indicator (it polls the
  Anthropic Statuspage); without it the service check is silently disabled and the rest
  of the widget works unchanged

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

### 2. Add the widget to your config

The animation frames ship as ready-to-use PNGs under
`linux/awesomewm/claude_status/frames/`, so there's nothing to generate. Copy (or
symlink) the widget folder into your Awesome config:

```bash
git clone https://github.com/MrMichou/claude-status-bar-awesomewm
cd claude-status-bar-awesomewm
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

### 3. Reload Awesome

`Mod + Ctrl + r` (or your reload binding). The widget appears and updates within
~0.4s of any Claude Code activity.

## Menus

- **Left click** — toggle the **active-sessions popup**: every running Claude Code
  session with its project name, current state (colored dot + label) and elapsed time.
  A session whose window is known shows a `↗` hint and is **clickable** — clicking it
  jumps to that terminal window (switches tag, unminimizes, raises and focuses it).
- **Right click** — the **settings menu**: pick the animation style (Crab / Clawd emotes /
  Spark / Claude Code glyphs), toggle the timer, and toggle the permission/done/outage
  notifications.
  Picks are persisted to `~/.claude/statusbar/widget.json` and override the `cfg`
  defaults, so they survive an Awesome restart. (Changing the style triggers a quick
  Awesome restart, since each style builds its icon differently.)

You can also bind keys — the widget exposes `toggle_sessions_menu()`,
`toggle_settings_menu()`, `cycle_sessions()` and `focus_session_by_id(id)`:

```lua
local claude = require("ui.bar.widgets.claude_status")

awful.key({ modkey }, "c", function()
  claude.toggle_sessions_menu()
end, { description = "Claude sessions menu", group = "launcher" })

-- Jump straight to the next Claude session's terminal (cycles in sorted-id order,
-- wrapping around) — no mouse, no menu. Only sessions with a captured window id
-- participate.
awful.key({ modkey }, "x", function()
  claude.cycle_sessions()
end, { description = "Cycle Claude sessions", group = "launcher" })
```

`focus_session_by_id("<session-id>")` jumps to one specific session if you'd rather
bind individual sessions; both reuse the same window-focus logic as the clickable
menu rows (switch tag, unminimize, raise, focus).

The list is built from the session markers in `~/.claude/statusbar/sessions.d/`,
enriched with per-session state written to `~/.claude/statusbar/sessions-state/`.
Both are maintained by the hooks (`update.js` writes, `lifecycle.js` cleans up on
`SessionEnd`). The clickable-window id lives in `~/.claude/statusbar/sessions-win/`,
captured by `lifecycle.js` at `SessionStart` from `_NET_ACTIVE_WINDOW` (via `xprop`) —
the terminal where `claude` was launched is the focused window at that moment. Sessions
started before this feature existed have no window id and simply aren't clickable until
their next start.

## Configuration

Every key below can be overridden in **`~/.claude/statusbar/widget.json`** — you no
longer need to edit `init.lua` (so your settings survive a widget update). The file is
a flat JSON object; only the keys you set are applied, the rest keep their defaults. A
malformed value (wrong type) is silently ignored.

```json
{
  "style": "clawd",
  "brand": "#d97757",
  "icon_size": 22,
  "show_timer": true,
  "hide_when_idle": false,
  "poll_seconds": 0.4,
  "done_min_seconds": 30,
  "sound_cmd": "paplay /usr/share/sounds/freedesktop/stereo/complete.oga"
}
```

The right-click settings menu writes back `style`, `show_timer` and the `notify_*`
flags; any other key you hand-edited (colors, sizes, intervals, sound) is **preserved**
on the next menu toggle, not wiped. `icon_size` is a raw pixel size in the file and is
DPI-scaled on load (matching the `dpi(18)` default). `service_url` is intentionally
**not** configurable via the file (it stays hardcoded to avoid an SSRF vector); change
it in `cfg` if you really need to.

| Key | Default | Description |
|---|---|---|
| `style` | `"crab"` | `"crab"` (pixel-art crab), `"clawd"` (pixel crab with a **different loop per state** — thinks, types while working, walks at rest), `"web"` (Claude spark), or `"code"` (terminal glyph spinner ✻✽✶✳✢) |
| `brand` | `"#d97757"` | Tint color for the spark / logo (alpha-mask frames) |
| `amber` | `"#f2bb2e"` | "Awaiting permission" dot color |
| `down` | `"#e5484d"` | "Claude service down" dot color |
| `icon_size` | `dpi(18)` | Icon height/width |
| `show_timer` | `true` | Show the `1m 1s` elapsed clock |
| `show_aggregate` | `false` | When >1 session is open, append a compact `N · M working` badge to the label (full breakdown stays in the click-to-open menu) |
| `hide_when_idle` | `false` | Hide the widget at idle (vs. resting logo) |
| `notify_permission` | `true` | `naughty` popup on permission requests |
| `notify_permission_actions` | `true` | Add **Yes**/**No** buttons to that popup (needs `xdotool` + a captured window id). Clicking focuses the session's terminal and presses the matching key. |
| `permission_yes_key` | `"Return"` | Key sent for **Yes** (Claude Code's default-highlighted option) |
| `permission_no_key` | `"Escape"` | Key sent for **No** ("tell Claude what to do differently") |
| `notify_done` | `true` | `naughty` popup when a turn finishes |
| `done_min_seconds` | `60` | Only notify "done" for turns at least this long (`0` = always) |
| `notify_long_turn` | `false` | One-shot "Still working — Nm elapsed" `naughty` popup when a turn runs long (fires once per turn, re-arms on the next) |
| `long_turn_seconds` | `300` | How long a live turn must run before the long-turn nudge fires |
| `sound_cmd` | `nil` | Shell command to play on completion, e.g. `"paplay /usr/share/sounds/freedesktop/stereo/complete.oga"` |
| `poll_seconds` | `0.4` | `state.json` poll interval |
| `check_service` | `true` | Poll the Anthropic Statuspage and show "Claude down" during an incident (needs `curl`) |
| `service_url` | `"https://status.claude.com/api/v2/status.json"` | Statuspage endpoint to poll |
| `service_poll_seconds` | `60` | Service-status poll interval (network, so far slower than `poll_seconds`) |
| `notify_service` | `true` | `naughty` popup when an outage starts and when it clears |

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

Separately, a second timer polls the Anthropic Statuspage every `service_poll_seconds`
by shelling out to `curl` asynchronously (`awful.spawn.easy_async`, so the event loop
never blocks). Any `status.indicator` other than `none` (`minor` / `major` / `critical`)
counts as an incident: the bar swaps to a red dot + "Claude down — <description>" over
the normal session state and reverts the moment the incident clears. Transitions in and
out of an incident fire a `naughty` notification when `notify_service` is on.

## Troubleshooting

- **Nothing shows / stuck on the resting logo:** confirm the hooks are installed
  and writing state: `cat ~/.claude/statusbar/state.json` during a Claude turn.
  Enable hook logging with `CLAUDE_STATUSBAR_DEBUG=1` and check
  `~/.claude/statusbar/hooks.log`.
- **A black square instead of the orange spark:** the frame PNGs are missing —
  check `linux/awesomewm/claude_status/frames/web/00.png` exists where you copied
  the widget folder.
- **`require` error on reload:** check the module path matches where you copied the
  folder, and that `lgi` is available (`echo 'return require("lgi") ~= nil' | awesome-client`).
- **"Claude down" never shows / always shows:** the service check needs `curl` and outbound
  network access. Verify the endpoint by hand: `curl -fsS https://status.claude.com/api/v2/status.json`.
  Set `check_service = false` in `cfg` to disable it entirely.
