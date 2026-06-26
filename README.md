## Claude Status Bar — awesomewm

[![CI](https://github.com/MrMichou/claude-status-bar-awesomewm/actions/workflows/ci.yml/badge.svg)](https://github.com/MrMichou/claude-status-bar-awesomewm/actions/workflows/ci.yml)

A tiny [awesomewm](https://awesomewm.org/) wibar widget that shows **Claude Code's
live status** on Linux: an animated icon while Claude is thinking or running a tool,
an amber dot when it's awaiting your permission, the elapsed time of the current
turn, and a click-to-open menu listing every active session.

_Built so you can tab away during a long "thinking" stretch and still see, at a
glance, whether Claude is working, waiting on you, or done._

> Linux/awesomewm port of the macOS **Claude Status Bar** by **[@mickces](https://x.com/mickces)** ([m1ckc3s/claude-status-bar](https://github.com/m1ckc3s/claude-status-bar)). This fork is Linux-focused: the macOS app itself isn't included, only the animation frames it originated (bundled as PNGs under `linux/awesomewm/claude_status/frames/`). All credit for the original idea, design, and artwork goes to the author — see the [original repo](https://github.com/m1ckc3s/claude-status-bar) for the macOS app.

## What it shows

- **Thinking / working** — the icon animates, with a live `1m 1s` timer.
- **Running a tool** — a short label (`Editing`, `Reading`, `Running command`, …).
- **Awaiting permission** — a paused amber dot (no timer).
- **Claude service down** — a red dot + "Claude down" with the incident description
  when the [Anthropic Statuspage](https://status.claude.com) reports an outage.
- **Idle / done** — rests on a static icon.
- **Active-sessions menu** — click the widget (or bind a key) for a popup listing
  each running Claude Code session: project, current state, and elapsed time.

### Animation styles

Set `cfg.style` at the top of `linux/awesomewm/claude_status/init.lua`:

- **`crab`** (default) — a pixel-art Clawd crab that scuttles while Claude works.
- **`clawd`** — pixel-crab emotes with a **different animation per state**: a *thinking*
  loop while Claude thinks, a *typing* loop while it runs tools, a *listening* crab while
  awaiting permission, a *birthday* celebration when a turn finishes, and a *sleeping* crab
  (nightcap, in bed) when nothing is running — i.e. no open session. Emote artwork from
  [xixicc186/clawd-emotes-skill](https://github.com/xixicc186/clawd-emotes-skill).
- **`web`** — the Claude "morph" spark.
- **`code`** — the terminal glyph spinner `✻ ✽ ✶ ✳ ✢`.

## Requirements

- awesomewm **4.3+** with `lgi` (cairo bindings, normally bundled) — developed on
  `awesome v4.3-1700-gcd36f9023` (git-master, ≈4.4-dev, Lua 5.4.8, API level 4)
  against my [awesomewm config](https://github.com/MrMichou/MyAwesomeWM_config)
- [Claude Code](https://claude.com/claude-code) (CLI or Desktop)
- Node.js (used by the hook scripts)

## Install

Full instructions in **[docs/linux-awesomewm.md](docs/linux-awesomewm.md)**. In short:

1. Install the hooks (Claude Code plugin, or wire them manually) so a real session
   writes `~/.claude/statusbar/state.json`.
2. Copy/symlink `linux/awesomewm/claude_status/` into `~/.config/awesome/ui/bar/widgets/`.
3. `require("ui.bar.widgets.claude_status")` and drop it in your wibar; reload Awesome.

## How it works

Stateless and hook-driven. Claude Code hooks write the current status to
`~/.claude/statusbar/state.json` (and per-session state to `sessions-state/`); the
widget polls those files every 0.4s and renders the icon, label, timer, and sessions
menu. Interrupt (Esc) and permission-deny fire no hook, so — like the macOS app —
the widget reads the transcript tail for the `interrupted by user` marker (with a
15-minute safety net) to avoid getting stuck animating.

The hook layer (`hooks/update.js`, `hooks/lifecycle.js`) is cross-platform; the
macOS-only app-launch is guarded behind `process.platform === "darwin"`.

## Development

Two test suites, run in CI on every push and PR (`.github/workflows/ci.yml`):

- **JS hooks** — [Vitest](https://vitest.dev) exercises the real hook scripts in a
  subprocess with a throwaway `$HOME`, so nothing touches your `~/.claude`. Covers the
  event→state mapping, session tracking, and the `settings.json` merge/strip logic.

  ```sh
  npm install
  npm test
  ```

- **Lua widget** — [busted](https://lunarmodules.github.io/busted/) specs for the pure
  `json.lua` decoder, plus [luacheck](https://github.com/lunarmodules/luacheck) linting
  of the widget.

  ```sh
  luarocks install busted luacheck
  busted
  luacheck linux/ spec/
  ```

## Trademark / not affiliated

This is an unofficial, open-source side project. **It is not affiliated with,
endorsed by, or sponsored by Anthropic.** "Claude" and the Claude spark logo are
trademarks of Anthropic, used here nominatively. MIT licensed — that covers the
source code only and conveys no rights to Anthropic's trademarks or brand.

## License

MIT. Original macOS project © its author ([@mickces](https://x.com/mickces)).
