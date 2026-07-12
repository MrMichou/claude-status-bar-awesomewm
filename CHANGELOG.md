# Changelog

All notable changes to Claude Status Bar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Quota-threshold notification.** Optional desktop notification when a rate-limit window (session or weekly) crosses `quota_warn_percent`: "Claude usage: session window at 84% — resets 14:32". Fires once per window, deduped on the window's reset time, and re-arms automatically at reset. Off by default (`notify_quota`); toggle in the settings menu. Enabling it (even without the bar gauge) opts into the quota polling. (#69)
- **Usage-quota gauge** (inspired by [CodexBar](https://github.com/steipete/CodexBar)). The bar can show Claude's rate-limit utilization with a reset countdown (`⌛34% · 1h12`, `⚠` past a warn threshold), with per-window detail (session / week / Opus) in the left-click popup. A new `hooks/usage.js` polls Anthropic's OAuth usage endpoint with the local Claude Code token (sent only to the hardcoded `api.anthropic.com`, never logged) and atomically writes `quota.json`; `update.js` keeps it fresh while sessions are active, so nothing polls at idle — the countdown stays valid from absolute reset times. Off by default (`show_quota`); toggle in the settings menu; `quota_warn_percent` (default 80) tunable via `widget.json`. (#68)

## [0.6.1] - 2026-07-12

### Fixed
- **Linux: late-registered session markers are reapable too.** Markers created by `update.js` (sessions predating the hook install, or a stray event racing `SessionEnd`) were written empty, so the #63 reaper could never clean them. The `/proc` ancestry walk moved to a shared `hooks/pid.js`, and `update.js` now records the `claude` PID like `lifecycle.js` does — only on the rare marker-absent path, so the per-event cost is one `existsSync`. (#65)
- **Linux: stale session markers are reaped, so the session count no longer drifts upward.** Sessions that died without `SessionEnd` (killed terminal, crash, reboot) leaked their `sessions.d/` marker forever, inflating the widget's session count. `SessionStart` now records the session's `claude` PID in the marker (found by walking the hook's `/proc` ancestry) and reaps any marker whose recorded PID is dead or recycled (`/proc/<pid>/comm` must still be `claude`). Markers without a PID are kept — worst case is the old behavior. Also fixes `update.js` blanking the marker on every event, which would have erased the PID. (#63)

## [0.6.0] - 2026-07-04

### Added
- **Animation frames ship as sprite-strips.** The ~280 per-frame PNGs are packed into one horizontal strip per animation set (`frames/<set>.png`) plus a `frames/sprites.json` manifest, sliced back into cairo surfaces at load time — the repo drops from ~280 loose PNGs to 9 strips + a manifest, with pixel-identical rendering and unchanged runtime (frames are still pre-decoded once; animation is a pointer swap). New `tools/pack-frames.py` regenerates the strips, auto-discovering the sets under `frames/`. (#13)

### Fixed
- **Graceful degradation for missing/broken frame assets.** A missing or corrupt sprite-strip, or a malformed `sprites.json` entry, now falls back to the resting icon instead of rendering an invisible/blank widget or crashing Awesome's config at load. (#44, #45)

### Changed
- **`tools/pack-frames.py` is non-destructive and self-maintaining:** it refuses to overwrite `sprites.json` with an empty manifest when no source frames are present, merges into the existing manifest, discovers animation sets by walking `frames/`, and sorts frames numerically. The manifest stores only the frame count — the cell size is derived from the strip — and the widget's slice/tint path was unified onto a single `tint_surface` implementation with the strip surface freed after slicing. (#43, #46, #47, #48, #49, #50)

## [0.5.0] - 2026-06-30

### Added
- **Left-click press bounce.** Left-clicking the widget now gives tactile feedback: the icon dips on press and springs back with a slight overshoot on release. Implemented as a single `press_scale` multiplier that every icon-sizing path honours (imagebox `forced_*` for the crab/web/clawd styles, font size for the `code` style), so it works across all styles and the 0.4s poll never clobbers mid-bounce.

### Fixed
- **Startup crash when a session was already awaiting permission.** The poll timer's `call_now` fired the initial render synchronously at load — before `read_window_id`/`focus_window` were defined further down — so an at-startup `permission` state crashed building the notification's Yes/No actions (`attempt to call a nil value (upvalue 'read_window_id')`). The first poll is now triggered explicitly at the end of the module, once those functions exist.

## [0.4.0] - 2026-06-28

### Added
- **`clawd` sleeping idle emote.** When nothing is running (no open session), the dynamic `clawd` style now plays a **sleeping** crab — nightcap on, tucked in bed, breathing gently — in place of the static rest crab. Artwork from [xixicc186/clawd-emotes-skill](https://github.com/xixicc186/clawd-emotes-skill).
- **Completion / permission sounds.** Optional audible feedback wires up the bundled `completion.mp3` (now installed to `~/.claude/statusbar/` by the hooks): a sound on turn-done and a distinct one on permission requests, played via array-based `awful.spawn` (`{ sound_player, file }`, no shell). Off by default (`play_sounds`); a custom `sound_cmd` still takes precedence for back-compat. New "Play sounds" toggle in the settings menu. (#18)
- **Aggregated multi-session badge.** When more than one session is open, the bar can append a compact `N · M working` badge to the label (full breakdown stays in the click-to-open menu). Counts are gathered on the existing throttled session scan, so idle cost is unchanged. Off by default (`show_aggregate`); toggle in the settings menu. (#20)
- **Long-turn notification.** Optionally fire a one-shot "Still working — Nm elapsed" notification when a turn runs past a configurable threshold, so you can check whether Claude is stuck after tabbing away. Fires once per turn and re-arms on the next. Off by default (`notify_long_turn` / `long_turn_seconds`); toggle in the settings menu. (#19)
- **Keybindings to focus / cycle session windows.** New `cycle_sessions()` and `focus_session_by_id(id)` functions on the widget jump straight to a session's terminal without the mouse, reusing the same window-focus logic as the clickable menu rows. (#22)
- **Per-turn token / cost readout.** When a turn finishes, the bar can show its token count + estimated cost (e.g. `1.2k tok · $0.04`) as a turn summary. The hook layer derives it from the transcript tail (no extra reads on the widget's poll path) using a per-model price table; the widget just renders it in the `done` state. Off by default (`show_tokens`); toggle in the settings menu. (#21)
- **Per-session token / cost in the sessions popup.** Each session row in the left-click menu now shows that session's token count + estimated cost on its own line beneath the state, reusing the per-session data already written by the hook layer. The shared `fmt_tok_cost()` formatter backs both this and the inline bar badge. Always shown when a session has token data — independent of the `show_tokens` bar toggle, since the popup is an on-demand detail view.

### Changed
- **All widget settings configurable via `widget.json`.** `load_settings()` is now driven by a typed whitelist, so every `cfg` key — colors, `icon_size`, sound, intervals, `hide_when_idle`, etc. — can be overridden in `~/.claude/statusbar/widget.json` without editing `init.lua` (which is lost on every widget update). `save_settings()` merges: it preserves every hand-edited key and rewrites only the ones the right-click menu manages, so a hand-edited color isn't wiped by a checkbox toggle. `service_url` stays deliberately non-configurable (SSRF guard). (#17)
- **Idle is now nearly free (poll loop).** The widget polled `state.json` every `poll_seconds` (0.4s) by re-reading + JSON-decoding the file, re-enumerating `sessions.d/`, and re-rendering — even when nothing changed, which at idle is most of the time. The read/decode is now gated on the file's modification time (a `stat` instead of a parse), the session-directory scan is throttled, and the widget only re-renders when the displayed state could actually differ. Behavior is unchanged. (#6)
- **`clawd` emotes load on demand.** The dynamic style decoded all six per-state loops at startup (~285 frames, ≈12 MB of cairo surfaces resident) even though the larger emotes are rarely shown. Each loop is now decoded the first time its state appears and cached, dropping idle memory to a few MB. The unused `walk` loop is no longer loaded at all. (#7)
- **Less redundant label work.** The elapsed-timer label is only rewritten when the displayed text actually changes (once a second), rather than on every 0.4s poll. (#8)

## [0.3.0] - 2026-06-25

First release of the **awesomewm/Linux port** — a wibar widget that mirrors the macOS Claude Status Bar app, driven entirely by Claude Code hooks. Original idea, design, and artwork by [@mickces](https://github.com/m1ckc3s/claude-status-bar).

### Added
- **awesomewm/Linux port.** A `claude_status` wibar widget reading `~/.claude/statusbar/state.json` (written by the project's Node hooks): an animated icon, a tool label + elapsed turn timer while Claude works, an "awaiting permission" dot, and an active-sessions menu. Idle, it rests on the tinted Claude logo. Shipped with `install.js` / `uninstall.js` / `update.js` lifecycle hooks and a plugin marketplace manifest.
- **Animation styles.** `web` (Claude spark), `crab` (a static pixel-art Clawd crab), `code` (Claude Code's terminal glyph spinner), and `clawd` — a **dynamic state-driven style** whose loop tracks what Claude is doing (thinking / typing). Crab is the default; color follows an Orange/System setting.
- **`clawd` permission and done emotes.** The dynamic style now plays dedicated **listening** (awaiting-permission) and **birthday** (turn-done) emotes on top of its thinking/typing loops.
- **Optional desktop crab pet** (opt-in). A pixel-art Clawd crab that lives on the desktop and plays per-step walking animations; toggled from the right-click settings menu.
- **Right-click settings menu** to pick the animation style, toggle the elapsed timer, completion sound, and notifications — choices persisted to `~/.claude/statusbar/widget.json`.
- **"Claude down" service-status indicator.** The widget polls the public [Anthropic Statuspage](https://status.claude.com) and, when an incident is live (`status.indicator` is `minor`/`major`/`critical`), shows a **red dot + "Claude down"** with the incident description over whatever the local session state is, reverting the moment it clears. A `naughty` notification fires when the outage starts and when it recovers (toggle it from the settings menu, "Notify on Claude outage"). The check shells out to `curl` asynchronously every `service_poll_seconds` (60s default) so the event loop never blocks; without `curl` it's silently disabled. Configurable via `check_service` / `service_url` / `service_poll_seconds` / `notify_service` in `cfg`.
- **Yes/No buttons on the permission notification.** When Claude asks to approve a tool, the `naughty` popup offers **Yes** and **No** buttons — clicking one focuses that session's terminal and presses the matching key (`Return` to approve, `Escape` to deny), so you can answer without leaving what you're doing. Needs `xdotool` and a captured window id (the same one the jump-to-window feature uses); without either, the popup still appears, just without the buttons. Toggle it from the settings menu ("Yes/No buttons on permission"); the keys are configurable via `permission_yes_key` / `permission_no_key`.
- **Click a session in the menu to jump to its window.** The `SessionStart` hook records the X11 window where `claude` was launched (via `_NET_ACTIVE_WINDOW`), and rows with a known window show a `↗` hint and become clickable — clicking switches to that window's tag, unminimizes, raises and focuses it. Window matching is by exact X11 window id, so it works with terminals like terminator that share one process across multiple windows.
- **Stuck-state recovery** so a session that dies mid-turn no longer leaves the icon spinning forever.
- **Test suites and CI.** JS hook tests (vitest) and a Lua spec suite (busted), plus luacheck linting, all run in GitHub Actions.

## [0.2.0] - 2026-06-25

### Added
- **Awaiting-permission dot now works in the Claude desktop app**, not just the terminal CLI. Previously the yellow "awaiting permission" dot only appeared in the CLI, because the only signal we had (the `Notification` hook) never fires for permission prompts in the desktop app. The app now also listens to Claude Code's `PermissionRequest` hook, which fires the moment an approval dialog is shown in both the CLI and the desktop app, so the dot lights up the instant Claude is waiting on you to approve a tool.

## [0.1.0] - 2026-06-22

### Added
- **Crab Walking** animation style: a pixel-art Clawd crab that scuttles in the menu bar while Claude works. Pick it under Animation. It's always its orange pixel-art self (the Claude and Claude Code styles still follow the Orange/System color setting).
- Optional **completion sound**: a soft chime when a turn longer than a minute finishes. Off by default, toggle it under Options.
- **Version and update check** in the menu: shows your current version, plus a one-click "Update available" that opens the latest release when there's a newer one. The check is a once-a-day read of GitHub's public release tag; no data is collected and nothing is sent to the developer.
- Menu **section headers** (Options / Animation / Color) for easier navigation.

## [0.0.5] - 2026-06-22

### Fixed
- The app no longer quits while a session that was already running before you installed it is actively working. Such a session never fired its one-time `SessionStart` hook, so it wasn't being tracked, even though its other hooks fire normally. The status hooks now register the session on any activity, so any actively-working session keeps the icon alive. (Thanks to the bug report that pinned this down.)

## [0.0.4] - 2026-06-22

### Fixed
- The app now actually runs on macOS 12 (Monterey) and later, as the README states. Earlier builds were compiled without a pinned deployment target, so the binary inherited the build machine's OS (macOS 26) and refused to launch on anything older, despite the stated 12.0 requirement. The build now targets macOS 12.0 explicitly.

## [0.0.3] - 2026-06-22

### Changed
- Reworked how the icon appears on desktop-app launch. The app is now started by the existing session hook (which fires when the Claude desktop app opens, when `claude` runs in a terminal, or when a conversation is opened) and quits itself when Claude is closed and no session is active. This keeps the "icon appears when the desktop app opens" behavior from 0.0.2 with no background helper.

### Removed
- The background watcher (a `launchd` LaunchAgent running a shell script) introduced in 0.0.2. It showed up as a "bash" item under Login Items and Extensions, which was confusing. There is no longer any login item or background item. Upgrading from 0.0.2 removes the old LaunchAgent automatically.

### Fixed
- The menu bar icon now reliably disappears when you quit the Claude desktop app, detected directly rather than relying on the session-end hook (which is unreliable during app shutdown).
- Upgrades now self-heal: the app re-runs its installer when the version changes, so updating from an older version refreshes the hooks and removes the old background watcher without any manual step. Previously the installer only ran on a first-ever install.

## [0.0.2] - 2026-06-21

### Added
- Desktop app watcher: the menu bar icon now appears the moment the Claude desktop app opens, before you start a conversation, and disappears shortly after you quit it. Previously the icon only showed once a session began. Implemented as a lightweight `launchd` LaunchAgent that tracks the Claude desktop process (installed via `install.js`, removed via `uninstall.js`).

### Changed
- Ending a Claude Code session no longer hides the icon while the Claude desktop app is still open.

### Fixed
- Uninstall now removes all of the app's own hooks, including the `SessionStart` / `SessionEnd` lifecycle hooks that a previous version left behind. It only ever touches this app's hooks, never any others.

### Notes
- The desktop watcher is part of the DMG / standalone install path. The Claude Code plugin install path keeps the session-only behavior.

## [0.0.1] - 2026-06-21

### Added
- Initial release: macOS menu bar status indicator for Claude Code, driven entirely by Claude Code hooks.
- Animated Claude spark, elapsed turn timer, and an "awaiting permission" dot.
- Two animation styles (Claude, Claude Code) and two color modes (Orange, System), persisted in preferences.
- Refcounted session lifecycle: launches when Claude Code opens, quits when the last session ends.
- Signed and notarized DMG so it opens without a Gatekeeper warning.
- Claude Code plugin marketplace manifest for the plugin install path.

[0.3.0]: https://github.com/MrMichou/claude-status-bar-awesomewm/releases/tag/v0.3.0
[0.2.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.2.0
[0.1.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.1.0
[0.0.5]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.5
[0.0.4]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.4
[0.0.3]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.3
[0.0.2]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.2
[0.0.1]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.1
