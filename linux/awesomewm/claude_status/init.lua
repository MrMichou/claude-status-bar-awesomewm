--------------------------------------------------------------------------------
-- claude_status — awesomewm wibar widget mirroring the macOS Claude Status Bar app.
--
-- Reads ~/.claude/statusbar/state.json (written by the project's Claude Code hooks)
-- and shows an animated spark + tool label + elapsed timer while Claude works, an
-- amber dot while awaiting permission, and a resting logo when idle.
--
-- Install: copy this folder to ~/.config/awesome/ui/bar/widgets/claude_status/
-- then `require("ui.bar.widgets.claude_status")` and drop it in your wibar.
--------------------------------------------------------------------------------

local gears = require("gears")
local wibox = require("wibox")
local beautiful = require("beautiful")
local naughty = require("naughty")
local awful = require("awful")
local lgi = require("lgi")
local cairo = lgi.cairo

local json = require("ui.bar.widgets.claude_status.json")

local dpi = beautiful.xresources.apply_dpi

--==[ Config ]==----------------------------------------------------------------
local cfg = {
  style          = "crab",       -- "web" (Claude spark), "crab", or "code" (glyph spinner)
  brand          = "#d97757",    -- Anthropic orange, used to tint the alpha-mask frames
  amber          = "#f2bb2e",    -- "awaiting permission" dot
  down           = "#e5484d",    -- "Claude service down" dot (Anthropic Statuspage incident)
  icon_size      = dpi(18),
  show_timer     = true,
  -- When several sessions run at once, append a compact "N · M working" badge to the
  -- label so multi-session activity shows on the bar (full breakdown stays in the menu).
  show_aggregate = false,
  -- Append the current turn's token count + estimated cost to the label (e.g. "1.2k tok · $0.04").
  -- The hook layer derives these from the transcript; the widget just renders them.
  show_tokens    = false,
  hide_when_idle = false,        -- false: show the resting logo at idle (like macOS)
  notify_permission = true,
  notify_done       = true,
  -- Yes/No buttons on the permission notification. Clicking one focuses the session's
  -- terminal and synthesizes the keypress (needs xdotool + a captured window id).
  notify_permission_actions = true,
  permission_yes_key = "Return", -- Claude Code's default-highlighted "Yes"
  permission_no_key  = "Escape", -- "No, and tell Claude what to do differently"
  done_min_seconds  = 60,        -- only notify "done" for turns at least this long (0 = always)
  -- One-shot "still working" nudge when a turn runs long (useful when you've tabbed away).
  -- Fires once per turn; re-arms on the next turn. Off by default.
  notify_long_turn  = false,
  long_turn_seconds = 300,
  sound_cmd      = nil,          -- custom shell command (advanced); if set, played on done + service
  -- Bundled audible feedback (array spawn, no shell): a player + per-event sound files.
  -- Off by default. done_sound defaults to the completion.mp3 installed by hooks/install.js;
  -- permission_sound is optional and falls back to done_sound when unset.
  play_sounds      = false,
  sound_player     = "paplay",
  done_sound       = os.getenv("HOME") .. "/.claude/statusbar/completion.mp3",
  permission_sound = nil,
  poll_seconds   = 0.4,
  -- Anthropic service health, polled from the public Statuspage. When an incident is live the
  -- widget shows a red dot + "Claude down" over the normal session state and (optionally) notifies.
  check_service  = true,
  service_url    = "https://status.claude.com/api/v2/status.json",
  service_poll_seconds = 60,     -- network is slow; poll far less often than the local state
  notify_service = true,
  -- Usage-quota gauge (#68): rate-limit utilization + reset countdown, read from
  -- ~/.claude/statusbar/quota.json (written by hooks/usage.js while sessions are active).
  -- The bar shows a compact five-hour badge; the left-click popup has the full detail.
  show_quota         = false,
  quota_warn_percent = 80,       -- ⚠ prefix on the badge / red popup row at or above this
  -- One-shot notification when a rate-limit window crosses quota_warn_percent (#69).
  -- Fires once per window and re-arms when the window resets. Off by default.
  notify_quota       = false,
}
local FPS = { web = 9, crab = 12.5, clawd = 14 }
-- "clawd" style: a pixel crab with a *different* loop per state (the emote set from
-- github.com/xixicc186/clawd-emotes-skill, exported to PNG frames). Unlike the single-loop
-- styles, the displayed animation switches with Claude's state — see current_frames().
-- Emotes from the same set also cover three states the other styles render statically: an
-- attentive "listening" crab while awaiting permission, a "birthday" celebration at done, and
-- a "sleeping" crab (nightcap, in bed) while idle — i.e. when no session is doing anything.
local CLAWD = {
  thinking   = "clawd/thinking",
  tool       = "clawd/typing",
  rest       = "clawd/walk",
  permission = "clawd/listening",
  done       = "clawd/birthday",
  sleeping   = "clawd/sleeping",
}
-- The thinking/typing emotes read small at the resting icon size, so clawd renders them a
-- little larger while Claude works (the rest crab keeps the normal size). dpi() applied below.
local CLAWD_WORK_SIZE = 40
-- The idle "sleeping" emote animates gently (breathing + a bobbing nightcap); it sits between
-- the resting icon and the bigger working emotes so it reads without dominating the bar.
local CLAWD_SLEEP_SIZE = 26
-- "code" style: Claude Code's terminal glyph spinner, tweened with a scale pulse.
local CODE = { glyphs = { "✻", "✽", "✶", "✳", "✢" }, sub = 18, dip = 0.14, base_pt = 14, cycle = 3.8 }
--==============================================================================

-- Persisted settings (~/.claude/statusbar/widget.json) override the cfg defaults
-- above so your picks survive an Awesome restart. Every key below can be set in the
-- file by hand; the right-click menu only writes the MENU_KEYS subset and preserves
-- the rest untouched (so a hand-edited color isn't wiped by a checkbox toggle).
-- service_url is deliberately absent (potential SSRF vector) — it stays hardcoded.
local SETTINGS_SCHEMA = {
  style = "string", brand = "string", amber = "string", down = "string",
  icon_size = "number", hide_when_idle = "boolean", show_timer = "boolean",
  show_aggregate = "boolean", show_tokens = "boolean",
  notify_permission = "boolean", notify_done = "boolean",
  notify_permission_actions = "boolean", notify_service = "boolean",
  permission_yes_key = "string", permission_no_key = "string",
  done_min_seconds = "number", sound_cmd = "string",
  play_sounds = "boolean", sound_player = "string",
  done_sound = "string", permission_sound = "string",
  notify_long_turn = "boolean", long_turn_seconds = "number",
  poll_seconds = "number", check_service = "boolean",
  service_poll_seconds = "number",
  show_quota = "boolean", quota_warn_percent = "number", notify_quota = "boolean",
}
-- Keys the right-click settings menu manages: save_settings() writes these from cfg
-- and round-trips every other key the user hand-edited into widget.json.
local MENU_KEYS = {
  "style", "show_timer", "show_aggregate", "show_tokens", "notify_permission", "notify_done",
  "notify_permission_actions", "notify_service", "notify_long_turn", "play_sounds",
  "show_quota", "notify_quota",
}
local settings_path = os.getenv("HOME") .. "/.claude/statusbar/widget.json"
local raw_settings = {} -- the decoded widget.json, kept verbatim for save round-tripping
local function load_settings()
  local f = io.open(settings_path, "r"); if not f then return end
  local raw = f:read("*a"); f:close()
  local t = json.decode(raw); if type(t) ~= "table" then return end
  raw_settings = t
  for k, ty in pairs(SETTINGS_SCHEMA) do
    local v = t[k]
    if type(v) == ty then -- a type mismatch silently rejects the malformed value
      -- icon_size in the file is a raw size; scale it like the dpi(18) default.
      if k == "icon_size" then cfg.icon_size = dpi(v) else cfg[k] = v end
    end
  end
end
local function save_settings()
  local out = {}
  for k, v in pairs(raw_settings) do out[k] = v end -- preserve hand-edited keys
  for _, k in ipairs(MENU_KEYS) do out[k] = cfg[k] end -- override the menu-driven ones
  local enc = json.encode(out)
  if not enc then return end
  raw_settings = out -- so the next save round-trips from what we just wrote
  local f = io.open(settings_path, "w"); if not f then return end
  f:write(enc); f:close()
end
load_settings()

local state_path = os.getenv("HOME") .. "/.claude/statusbar/state.json"
local quota_path = os.getenv("HOME") .. "/.claude/statusbar/quota.json"
local module_dir = (debug.getinfo(1, "S").source:match("^@(.*/)")) or "./"
local frames_dir = module_dir .. "frames/"

-- No hook ever writes a global "idle" state: state.json keeps its last value after a turn
-- ("done"/"permission"/…), so it can't tell us "no session is open". The session markers in
-- sessions.d/ can — the lifecycle hook drops one at SessionStart and removes it at SessionEnd.
-- An empty dir means nothing is running, which drives the idle (sleeping) emote below.
local sessions_marker_dir = os.getenv("HOME") .. "/.claude/statusbar/sessions.d/"
local function open_session_count()
  local n = 0
  pcall(function()
    local Gio = lgi.Gio
    local en = Gio.File.new_for_path(sessions_marker_dir)
      :enumerate_children("standard::name", Gio.FileQueryInfoFlags.NONE)
    if not en then return end
    while true do
      local info = en:next_file(); if not info then break end
      if not info:get_name():match("%.") then n = n + 1 end -- markers are bare ids (skip .tmp/.json)
    end
  end)
  return n
end

-- Aggregate for the optional bar badge: total open sessions + how many are actively
-- working (thinking/tool). Reads each session-state file, so it only runs on the throttled
-- SESSION_EVERY cadence (see the poll loop), never every poll. Returns total, working.
local sess_state_for_badge = os.getenv("HOME") .. "/.claude/statusbar/sessions-state/"
local function session_summary()
  local total, working = 0, 0
  pcall(function()
    local Gio = lgi.Gio
    local en = Gio.File.new_for_path(sessions_marker_dir)
      :enumerate_children("standard::name", Gio.FileQueryInfoFlags.NONE)
    if not en then return end
    while true do
      local info = en:next_file(); if not info then break end
      local name = info:get_name()
      if not name:match("%.") then
        total = total + 1
        local f = io.open(sess_state_for_badge .. name .. ".json", "r")
        if f then
          local raw = f:read("*a"); f:close()
          local t = json.decode(raw)
          if type(t) == "table" and (t.state == "thinking" or t.state == "tool") then
            working = working + 1
          end
        end
      end
    end
  end)
  return total, working
end

-- Paint `color` through an alpha-mask surface -> a colored cairo surface (the macOS tint).
local function tint_surface(mask, color)
  if not mask then return nil end
  local w, h = mask:get_width(), mask:get_height()
  local out = cairo.ImageSurface.create(cairo.Format.ARGB32, w, h)
  local cr = cairo.Context(out)
  cr:set_source(gears.color(color))
  cr:mask_surface(mask, 0, 0)
  return out
end

-- Same, from a PNG path (used for the static resting logo).
local function tint(path, color)
  return tint_surface(gears.surface.load_uncached(path), color)
end

local function make_dot(color, size)
  local out = cairo.ImageSurface.create(cairo.Format.ARGB32, size, size)
  local cr = cairo.Context(out)
  cr:set_source(gears.color(color))
  local r = size * 0.28
  cr:arc(size / 2, size / 2, r, 0, 2 * math.pi)
  cr:fill()
  return out
end

-- Sprite manifest: each animation set ships as one horizontal strip (tools/pack-frames.py)
-- so the repo holds a handful of PNGs instead of ~300 loose frames. Each set maps to its
-- frame count `n`; the cell size is derived from the strip itself in load_frame_dir below.
local sprites = (function()
  local f = io.open(frames_dir .. "sprites.json", "r")
  if not f then return {} end
  local raw = f:read("*a"); f:close()
  local t = json.decode(raw)
  return type(t) == "table" and t or {}
end)()

-- Slice a horizontal sprite-strip into per-frame surfaces. Each cell is copied out at the
-- origin; with tint_it the copied cell is recoloured through its own alpha via tint_surface
-- (the macOS spark), reusing the one tint implementation instead of open-coding the mask.
local function slice_strip(sheet, n, w, h, tint_it)
  local set = {}
  for i = 0, n - 1 do
    local cell = cairo.ImageSurface.create(cairo.Format.ARGB32, w, h)
    local cr = cairo.Context(cell)
    cr:set_source_surface(sheet, -i * w, 0) -- align the i-th cell to the origin
    cr:paint()
    set[#set + 1] = tint_it and tint_surface(cell, cfg.brand) or cell
  end
  return set
end

-- Load an animation set (`subdir` is its sprites.json key, e.g. "crab" or "clawd/thinking")
-- as a list of per-frame surfaces, slicing it out of the set's strip. `tint_it` recolours
-- each frame (the web spark). Returns {} for an unknown set, a malformed manifest entry, or
-- a missing/corrupt strip PNG, so callers fall back to the resting icon.
local function load_frame_dir(subdir, tint_it)
  local n = sprites[subdir]
  if type(n) ~= "number" or n < 1 then return {} end -- unknown set / malformed manifest
  n = math.floor(n)
  -- load_uncached_silently returns (surface, err); on a missing/corrupt file err is set and
  -- the surface is a 0x0 placeholder (load_uncached would swallow the error and hand us that
  -- placeholder, silently yielding blank frames), so key off err to degrade gracefully.
  local sheet, err = gears.surface.load_uncached_silently(frames_dir .. subdir .. ".png")
  if err or not sheet then return {} end
  -- Cell size is derived from the strip: h is the sheet height, w is one of n equal columns.
  local set = slice_strip(sheet, n, math.floor(sheet:get_width() / n), sheet:get_height(), tint_it)
  sheet:finish() -- release the strip's pixel buffer now instead of waiting for a GC cycle
  return set
end

local is_code = (cfg.style == "code")
local is_clawd = (cfg.style == "clawd")

-- For clawd we hold one loop per state; the other image styles use a single `frames` set.
-- The clawd loops are loaded lazily: decoding all six up front kept ~285 frames (≈12 MB of
-- cairo surfaces) resident even though listening/birthday/sleeping are rarely shown. clawd_set
-- decodes a loop on first use and memoises it, so an idle bar only pays for what it displays.
local clawd_cache = {}
local function clawd_set(key)
  local s = clawd_cache[key]
  if s == nil then
    s = load_frame_dir(CLAWD[key], false)
    clawd_cache[key] = s
  end
  return s
end

local frames
if is_code then
  frames = {}
elseif is_clawd then
  -- Only the thinking emote is needed eagerly: it backs `frames` and the resting fallback.
  frames = clawd_set("thinking")
else
  frames = load_frame_dir(cfg.style, cfg.style == "web")
end

-- Resting icon: the crab styles rest on a static frame (stay on-brand); the spark style
-- rests on the tinted Claude logo, like the macOS app.
-- The clawd style poses on the original pixel crab frames when idle; kept at module scope
-- so the idle "fidget" (a periodic walk-through) can replay them. nil for other styles.
local clawd_rest_frames = is_clawd and load_frame_dir("crab", false) or nil

local resting
if is_clawd then
  -- At rest the clawd style poses on the original pixel crab frame (never clipped), the way
  -- the macOS app rests on its logo; it only animates (thinking/typing) while Claude works.
  resting = (clawd_rest_frames and clawd_rest_frames[1]) or clawd_set("thinking")[1]
elseif cfg.style == "crab" then
  resting = frames[1]
else
  resting = tint(frames_dir .. "logo.png", cfg.brand) or frames[1]
end
local dot = make_dot(cfg.amber, cfg.icon_size)
local down_dot = make_dot(cfg.down, cfg.icon_size)
local code_count = #CODE.glyphs * CODE.sub
local fps = is_code and (code_count / CODE.cycle) or (FPS[cfg.style] or 9)

--==[ Widgets ]==---------------------------------------------------------------
-- The "code" style is text (a glyph), so its icon slot is a textbox; web/crab use an imagebox.
local icon
if is_code then
  icon = wibox.widget {
    align = "center", valign = "center",
    forced_width = cfg.icon_size, forced_height = cfg.icon_size,
    widget = wibox.widget.textbox,
  }
else
  icon = wibox.widget {
    image = resting,
    resize = true,
    forced_height = cfg.icon_size,
    forced_width = cfg.icon_size,
    widget = wibox.widget.imagebox,
  }
end
local label = wibox.widget {
  font = beautiful.font_name .. "Medium 10",
  widget = wibox.widget.textbox,
}
-- The crab styles sit a touch high in their slot; nudge them down so they line up better.
local icon_slot = (cfg.style == "crab" or is_clawd) and wibox.widget {
  icon,
  top = is_clawd and dpi(6) or dpi(4),
  widget = wibox.container.margin,
} or icon
local root = wibox.widget {
  {
    {
      icon_slot,
      label,
      spacing = dpi(6),
      layout = wibox.layout.fixed.horizontal,
    },
    margins = dpi(4),
    widget = wibox.container.margin,
  },
  widget = wibox.container.background,
}

--==[ State + animation ]==-----------------------------------------------------
local cur = { state = "idle", label = "", startedAt = 0 }
local frame_i = 1
local animating = false
local prev_state = nil
local turn_started = 0 -- remembered while >0 so we know the turn length at "done"
local active_set = nil -- the clawd loop currently on screen; restart frame_i when it changes
local fidgeting = false -- clawd only: an idle "fidget" walk is currently playing (owns the icon)
local press_scale = 1 -- left-click "press" bounce: a multiplier every icon-sizing path respects
local agg_total, agg_working = 0, 0 -- multi-session badge counts, refreshed on the SESSION_EVERY cadence

-- The frame set to animate for the current state. Static styles always return `frames`;
-- the clawd style swaps loops so the animation tracks what Claude is doing.
local function current_frames()
  if not is_clawd then return frames end
  if cur.state == "tool" then return clawd_set("tool") end
  if cur.state == "permission" then return clawd_set("permission") end
  if cur.state == "done" then return clawd_set("done") end
  if cur.state == "idle" then return clawd_set("sleeping") end -- nothing running: the crab sleeps
  return clawd_set("thinking") -- thinking (waiting doesn't animate; it rests on the crab)
end

-- Anthropic service health from the Statuspage; "none" (or "") means all systems operational.
local service = { indicator = "none", description = "" }
local function service_down() return service.indicator ~= "none" and service.indicator ~= "" end

local function fmt_elapsed(startedAt)
  local secs = math.max(0, os.time() - startedAt)
  local m, s = math.floor(secs / 60), secs % 60
  if m > 0 then return string.format("%dm %ds", m, s) end
  return string.format("%ds", s)
end

-- "code" style rendering: pick the glyph for this frame and pulse its size.
local function code_env(t)
  if t < 0.30 then local u = t / 0.30; return u * u * (3 - 2 * u)
  elseif t > 0.70 then local u = (1 - t) / 0.30; return u * u * (3 - 2 * u)
  else return 1 end
end
local function set_code_icon(frame, color)
  local i = math.floor(frame / CODE.sub) % #CODE.glyphs
  local lt = (frame % CODE.sub + 0.5) / CODE.sub
  local scale = CODE.dip + (1 - CODE.dip) * code_env(lt)
  icon.font = beautiful.font_name .. string.format("%.1f", math.max(1, CODE.base_pt * scale * press_scale))
  icon.markup = string.format("<span color='%s'>%s</span>", color, CODE.glyphs[i + 1])
end
local function code_static(glyph, color)
  icon.font = beautiful.font_name .. string.format("%.1f", CODE.base_pt * press_scale)
  icon.markup = string.format("<span color='%s'>%s</span>", color, glyph)
end

local anim_timer = gears.timer {
  timeout = 1 / fps,
  callback = function()
    if not animating then return end
    if is_code then
      frame_i = (frame_i + 1) % code_count
      set_code_icon(frame_i, cfg.brand)
    else
      local set = current_frames()
      if #set == 0 then return end
      frame_i = frame_i % #set + 1
      icon.image = set[frame_i]
    end
  end,
}

-- The poll re-runs apply() for a live timer every 0.4s, but the rendered text only changes
-- once a second. Cache the last text so we hit the textbox (markup reset + reflow) only when
-- the displayed string — seconds included — actually changes.
local last_label_text = nil
-- Compact multi-session suffix, e.g. "  3 · 2 working" (or "  3 sessions" when none are
-- actively working). Empty unless show_aggregate is on and more than one session is open.
local function agg_badge()
  if not cfg.show_aggregate or agg_total <= 1 then return "" end
  if agg_working > 0 then return string.format("  %d · %d working", agg_total, agg_working) end
  return string.format("  %d sessions", agg_total)
end
-- Compact per-turn token + estimated-cost suffix, e.g. "1.2k tok · $0.04" (the hook layer
-- writes cur.tokens / cur.cost from the transcript). Shown only at the *end* of a turn (the
-- "done" state), not as a live counter while Claude works — so it reads as a turn summary.
local function fmt_tokens(n)
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end
-- "1.2k tok · $0.04" for present values, "" otherwise. No state gating: the
-- caller decides when to show it (inline badge vs. per-session popup row).
local function fmt_tok_cost(tokens, cost)
  if not tokens or tokens <= 0 then return "" end
  local seg = fmt_tokens(tokens) .. " tok"
  if cost and cost > 0 then
    local c = (cost >= 0.1) and string.format("$%.2f", cost) or string.format("$%.3f", cost)
    seg = seg .. " · " .. c
  end
  return seg
end
local function tok_badge()
  if not cfg.show_tokens or cur.state ~= "done" then return "" end
  local seg = fmt_tok_cost(cur.tokens, cur.cost)
  return seg == "" and "" or ("  " .. seg)
end
-- Usage-quota gauge (#68). `quota` is the decoded quota.json (or nil), refreshed on the
-- throttled session-scan cadence in the poll below. hooks/usage.js keeps the file fresh
-- while sessions are active; when idle the countdown stays valid (absolute reset times).
local quota = nil
local function fmt_reset_in(resets_at)
  local secs = (tonumber(resets_at) or 0) - os.time()
  if secs <= 0 then return "now" end
  local h, m = math.floor(secs / 3600), math.floor(secs % 3600 / 60)
  if h > 24 then return string.format("%dd", math.floor(h / 24)) end
  if h > 0 then return string.format("%dh%02d", h, m) end
  return string.format("%dm", math.max(1, m))
end
-- Compact five-hour readout for the bar, e.g. "  ⌛34% · 1h12" ("⚠" past the warn
-- threshold on either window). Weekly detail lives in the popup, not here.
local function quota_badge()
  if not cfg.show_quota or not quota then return "" end
  local fh = quota.fiveHour
  if not fh or type(fh.pct) ~= "number" then return "" end
  local warn = fh.pct >= cfg.quota_warn_percent
    or (quota.sevenDay and (tonumber(quota.sevenDay.pct) or 0) >= cfg.quota_warn_percent)
  return string.format("  %s%d%% · %s", warn and "⚠" or "⌛", math.floor(fh.pct + 0.5),
    fmt_reset_in(fh.resetsAt))
end
local function set_label(base, startedAt)
  local text = base or ""
  if cfg.show_timer and startedAt and startedAt > 0 then
    text = text .. "  " .. fmt_elapsed(startedAt)
  end
  text = text .. agg_badge() .. tok_badge() .. quota_badge()
  text = text:gsub("^%s+", "") -- a badge with an empty base would otherwise lead with spaces
  if text == last_label_text then return end
  last_label_text = text
  label.markup = ""
  label:set_text(text)
end

-- Show a non-animated icon for the current style. kind = "permission" | "rest".
local function show_static(kind)
  if is_code then
    if kind == "permission" then code_static("●", cfg.amber) else code_static(CODE.glyphs[1], cfg.brand) end
  else
    if kind == "rest" and fidgeting then return end -- the idle fidget owns the icon mid-walk
    icon.image = (kind == "permission") and dot or resting
  end
end

local function apply()
  -- A live service incident takes over the bar regardless of the local session state.
  if cfg.check_service and service_down() then
    animating = false; anim_timer:stop()
    if is_code then code_static("●", cfg.down) else icon.image = down_dot end
    local desc = (service.description ~= "" and (" — " .. service.description)) or ""
    set_label("Claude down" .. desc, 0)
    root.visible = true
    return
  end

  local s = cur.state
  -- clawd swaps between its thinking/typing loops while Claude works, but (like the other
  -- styles) it rests on a static icon when idle — see current_frames() and `resting`.
  -- clawd additionally animates three states the other styles draw statically: a "listening"
  -- emote while awaiting permission, a "birthday" emote at done, and a "sleeping" emote at idle
  -- (when nothing is running, in place of the static rest crab — see current_frames()).
  local animate = (s == "thinking" or s == "tool")
  if is_clawd and (s == "permission" or s == "done" or s == "idle") then animate = true end

  if animate then
    local set = current_frames()
    if set ~= active_set then active_set = set; frame_i = 1 end -- restart on a loop switch
    if not animating then animating = true; anim_timer:again() end
    if is_clawd then
      -- the idle sleeping emote sits smaller than the working emotes; size the slot to match.
      local sz = (s == "idle") and CLAWD_SLEEP_SIZE or CLAWD_WORK_SIZE
      icon.forced_width = math.floor(dpi(sz) * press_scale); icon.forced_height = math.floor(dpi(sz) * press_scale)
      icon_slot.top = (s == "idle") and dpi(4) or dpi(2)
    end
    if is_code then set_code_icon(frame_i, cfg.brand) else icon.image = set[frame_i] or resting end
    -- permission/done/idle are clawd-only animated states; the rest derive a working label.
    if s == "permission" then
      set_label("Awaiting permission", 0)
      root.visible = true
    elseif s == "done" then
      set_label("", 0)
      root.visible = true
    elseif s == "idle" then
      set_label("", 0)
      root.visible = not cfg.hide_when_idle
    else
      local base = (cur.label ~= "" and cur.label) or (s == "tool" and "Working…" or "Thinking…")
      set_label(base, cur.startedAt)
      root.visible = true
    end
  else
    animating = false; anim_timer:stop()
    if is_clawd then
      icon.forced_width = math.floor(cfg.icon_size * press_scale); icon.forced_height = math.floor(cfg.icon_size * press_scale)
      icon_slot.top = dpi(6) -- rest crab sits low again
    end
    if s == "permission" then
      show_static("permission")
      set_label("Awaiting permission", 0)
      root.visible = true
    elseif s == "waiting" then
      show_static("rest")
      set_label(cur.label, 0)
      root.visible = true
    else -- done / idle / unknown
      show_static("rest")
      set_label("", 0)
      root.visible = not cfg.hide_when_idle
    end
  end
end

-- Idle "fidget" (clawd only): every so often the resting crab takes a short walk using the
-- original pixel-crab frames, then settles back onto its static pose. Adds a little life at
-- rest without animating non-stop. Only runs while genuinely idle (not working / permission /
-- service outage).
local CLAWD_FIDGET = { min = 9, max = 22, laps = 1 } -- seconds between walks; laps per walk
if is_clawd and clawd_rest_frames and #clawd_rest_frames > 0 then
  math.randomseed(os.time())
  local tick = 1 / (FPS.crab or 12.5)
  local fidget_i, fidget_laps, wait_ticks = 0, 0, 0
  local function reschedule()
    wait_ticks = math.floor(math.random(CLAWD_FIDGET.min, CLAWD_FIDGET.max) / tick)
  end
  local function at_rest()
    return not animating and not (cfg.check_service and service_down())
      and (cur.state == "idle" or cur.state == "done" or cur.state == "waiting")
  end
  reschedule()
  gears.timer {
    timeout = tick,
    autostart = true,
    callback = function()
      if not at_rest() then
        if fidgeting then fidgeting = false; fidget_laps = 0; icon.image = resting end
        return
      end
      if fidgeting then
        fidget_i = fidget_i + 1
        if fidget_i > #clawd_rest_frames then
          fidget_i = 1
          fidget_laps = fidget_laps + 1
          if fidget_laps >= CLAWD_FIDGET.laps then
            fidgeting = false; fidget_laps = 0
            icon.image = resting
            reschedule()
            return
          end
        end
        icon.image = clawd_rest_frames[fidget_i]
      else
        wait_ticks = wait_ticks - 1
        if wait_ticks <= 0 then fidgeting = true; fidget_i = 1; fidget_laps = 0 end
      end
    end,
  }
end

-- Defined in the sessions section further down; notify() (below) needs them to turn a
-- permission prompt's Yes/No click into a keypress in that session's terminal.
local read_window_id, focus_window

-- Detected once: the Yes/No buttons synthesize keys via xdotool, so without it we hide
-- them rather than show buttons that silently do nothing.
local has_xdotool = (function()
  local p = io.popen("command -v xdotool 2>/dev/null"); if not p then return false end
  local out = p:read("*a"); p:close(); return out ~= nil and out:match("%S") ~= nil
end)()

-- The service poll shells out to curl; without it we skip the check rather than fail silently.
local has_curl = (function()
  local p = io.popen("command -v curl 2>/dev/null"); if not p then return false end
  local out = p:read("*a"); p:close(); return out ~= nil and out:match("%S") ~= nil
end)()

-- Answer a session's permission prompt: focus its terminal, then synthesize `keysym`
-- (Claude Code reads a real key, so we let the WM settle focus before sending it).
-- Falls back to a blind window-targeted send if we couldn't focus via awesome.
local function answer_session(sessionId, keysym)
  local winid = (sessionId and sessionId ~= "") and read_window_id(sessionId) or nil
  if not winid then return false end
  if focus_window(winid) then
    gears.timer.start_new(0.12, function()
      awful.spawn({ "xdotool", "key", "--clearmodifiers", keysym })
      return false
    end)
  else
    awful.spawn({ "xdotool", "key", "--window", tostring(winid), "--clearmodifiers", keysym })
  end
  return true
end

-- Play a sound file with the configured player via array spawn (no shell parsing).
-- Gated on cfg.play_sounds; a nil/empty path is a no-op.
local function play_sound(path)
  if not cfg.play_sounds or not path or path == "" then return end
  awful.spawn({ cfg.sound_player, path })
end

local function notify(state)
  local project = cur.project and cur.project ~= "" and (" — " .. cur.project) or ""
  if state == "permission" and cfg.notify_permission then
    local args = {
      title = "Claude Code",
      message = "Awaiting permission" .. project,
      urgency = "normal",
      icon = resting,
    }
    -- Offer Yes/No only when we know which terminal to answer (window id captured at
    -- SessionStart). Clicking focuses that terminal and presses the matching key.
    local sid = cur.sessionId
    if cfg.notify_permission_actions and has_xdotool and sid and sid ~= "" and read_window_id(sid) then
      local yes = naughty.action { name = "Yes" }
      local no = naughty.action { name = "No" }
      yes:connect_signal("invoked", function() answer_session(sid, cfg.permission_yes_key) end)
      no:connect_signal("invoked", function() answer_session(sid, cfg.permission_no_key) end)
      args.actions = { yes, no }
    end
    naughty.notification(args)
    -- A distinct permission cue (falls back to the done sound when unset).
    play_sound(cfg.permission_sound or cfg.done_sound)
  elseif state == "done" and cfg.notify_done then
    local dur = (turn_started > 0) and (os.time() - turn_started) or 0
    if dur >= cfg.done_min_seconds then
      naughty.notification {
        title = "Claude Code",
        message = "Done" .. project,
        icon = resting,
      }
      -- sound_cmd (custom shell) still wins for back-compat; otherwise the bundled sound.
      if cfg.sound_cmd then awful.spawn.with_shell(cfg.sound_cmd) else play_sound(cfg.done_sound) end
    end
  end
end

-- Notify when the Anthropic service goes down ("down" + description) and recovers ("up").
local function notify_service(kind, description)
  if not cfg.notify_service then return end
  if kind == "down" then
    naughty.notification {
      title = "Claude Code",
      message = "Claude service issue — " .. (description or "incident in progress"),
      urgency = "critical",
      icon = resting,
    }
    if cfg.sound_cmd then awful.spawn.with_shell(cfg.sound_cmd) end
  elseif kind == "up" then
    naughty.notification {
      title = "Claude Code",
      message = "Claude service back to normal",
      urgency = "normal",
      icon = resting,
    }
  end
end

-- One-shot "this turn is taking a while" nudge. Fired by the poll loop once the live
-- turn passes cfg.long_turn_seconds; the loop dedupes on startedAt so it fires once
-- per turn and re-arms on the next one.
local function notify_long_turn()
  local project = cur.project and cur.project ~= "" and (" — " .. cur.project) or ""
  naughty.notification {
    title = "Claude Code",
    message = "Still working — " .. fmt_elapsed(cur.startedAt) .. " elapsed" .. project,
    urgency = "normal",
    icon = resting,
  }
end

-- Quota-threshold alert (#69): fired by the poll loop when a rate-limit window crosses
-- cfg.quota_warn_percent. Deduped per window on the window's reset time, so it fires
-- once per window and re-arms automatically when the window resets.
local quota_notified = {} -- window name -> resetsAt already notified for
local function check_quota_alerts()
  if not cfg.notify_quota or not quota then return end
  for name, w in pairs({ session = quota.fiveHour, week = quota.sevenDay }) do
    if w and type(w.pct) == "number" and w.pct >= cfg.quota_warn_percent
      and quota_notified[name] ~= w.resetsAt then
      quota_notified[name] = w.resetsAt
      naughty.notification {
        title = "Claude Code",
        message = string.format("Claude usage: %s window at %d%% — resets %s",
          name, math.floor(w.pct + 0.5),
          os.date(name == "session" and "%H:%M" or "%a %H:%M", tonumber(w.resetsAt) or 0)),
        urgency = "normal",
        icon = resting,
      }
    end
  end
end

local function read_state()
  local f = io.open(state_path, "r")
  if not f then return nil end
  local raw = f:read("*a"); f:close()
  if not raw or raw == "" then return nil end
  return json.decode(raw)
end

local function read_quota()
  local f = io.open(quota_path, "r")
  if not f then return nil end
  local raw = f:read("*a"); f:close()
  if not raw or raw == "" then return nil end
  local t = json.decode(raw)
  return type(t) == "table" and t or nil
end

-- state.json's modification time in microseconds, so the poll can skip re-reading +
-- decoding it while it hasn't changed (the idle case). nil = absent or stat failed; the
-- caller then falls back to an unconditional read, so a broken stat never hides the file.
local function file_mtime(path)
  local mt
  pcall(function()
    local Gio = lgi.Gio
    local info = Gio.File.new_for_path(path)
      :query_info("time::modified,time::modified-usec", Gio.FileQueryInfoFlags.NONE)
    if not info then return end
    mt = info:get_attribute_uint64("time::modified") * 1000000
       + info:get_attribute_uint32("time::modified-usec")
  end)
  return mt
end

-- Last non-empty line of a (possibly large) file, read by tailing ~8KB.
local function last_line(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:seek("set", size > 8192 and size - 8192 or 0)
  local data = f:read("*a"); f:close()
  if not data then return nil end
  local last
  for line in data:gmatch("[^\n]+") do if line:match("%S") then last = line end end
  return last
end

-- Interrupt (Esc) and permission-deny fire NO hook, so state.json freezes on a live
-- state. Recover the way the macOS app does: detect the transcript's "interrupted by
-- user" marker, with an absolute age safety net. Returns the effective state.
local function effective_state(st)
  local s = st.state or "idle"
  if s == "thinking" or s == "tool" or s == "permission" then
    local age = os.time() - (tonumber(st.ts) or 0)
    if age > 900 then return "idle" end
    local tr = st.transcript
    if tr and tr ~= "" then
      local l = last_line(tr)
      if l and l:find("interrupted by user", 1, true) then return "idle" end
    end
  end
  return s
end

-- Poll state. The expensive work is gated on state.json's mtime so an idle bar (the
-- dominant case) costs a stat() instead of a read + JSON-decode every tick, and we only
-- re-render when something that affects the widget actually changed.
-- Autostarts itself; we keep no reference to the timer.
local poll_mtime = nil   -- last seen state.json mtime (µs); nil = absent / stat failed
local poll_st = nil      -- last decoded state.json, reused while the mtime is unchanged
local applied_sig = nil  -- signature of the last apply()ed render state
local session_ticks = 0  -- countdown to the next sessions.d re-enumeration
local no_session = false -- cached "no session open" (drives the idle/sleeping crab)
local SESSION_EVERY = 5  -- re-enumerate sessions.d at most every N polls (~2s) at idle
local long_turn_notified = 0 -- startedAt we already nudged for (dedupe the long-turn notification)
local quota_mtime = nil  -- last seen quota.json mtime (µs), same gating as state.json
-- Kept in a local so we can fire the first poll *explicitly* at the end of the module — see
-- the emit_signal call below. (call_now would run it here, before read_window_id/focus_window
-- are defined further down, which crashes when a session is already awaiting permission.)
local poll_timer = gears.timer {
  timeout = cfg.poll_seconds,
  autostart = true,
  callback = function()
    -- nil mtime (absent file or a failed stat) forces an unconditional read, so the gate
    -- can only ever skip work, never hide a state.json we should have read.
    local mt = file_mtime(state_path)
    local changed = (mt == nil) or (mt ~= poll_mtime)
    if changed then
      poll_mtime = mt
      poll_st = read_state()
    end

    local st = poll_st
    if not st then
      cur = { state = "idle", label = "", startedAt = 0 }
    else
      local eff = effective_state(st)
      cur = {
        state = eff,
        label = (eff == "idle") and "" or (st.label or ""),
        startedAt = tonumber(st.startedAt) or 0,
        project = st.project or "",
        sessionId = st.sessionId or "",
        tokens = (eff == "idle") and 0 or (tonumber(st.tokens) or 0),
        cost = (eff == "idle") and 0 or (tonumber(st.cost) or 0),
      }
    end

    -- No session open at all → idle, so the crab sleeps (the stale state.json can't say
    -- this). Re-enumerating sessions.d every tick is wasteful at idle; refresh it on a
    -- fresh write (mtime change ⇒ a session is alive) or every SESSION_EVERY polls.
    if changed or session_ticks <= 0 then
      session_ticks = SESSION_EVERY
      if cfg.show_aggregate then
        -- session_summary() also gives us the open count, so we don't pay for both.
        agg_total, agg_working = session_summary()
        no_session = (agg_total == 0)
      else
        no_session = (open_session_count() == 0)
      end
      -- Quota gauge: piggyback on the throttled cadence; re-decode only on a fresh write.
      if cfg.show_quota or cfg.notify_quota then
        local qmt = file_mtime(quota_path)
        if qmt == nil or qmt ~= quota_mtime then
          quota_mtime = qmt
          quota = read_quota()
          check_quota_alerts()
        end
      end
    else
      session_ticks = session_ticks - 1
    end
    if no_session then
      cur = { state = "idle", label = "", startedAt = 0, project = "", sessionId = "" }
    end

    if cur.startedAt > 0 then turn_started = cur.startedAt end

    if cur.state ~= prev_state then
      notify(cur.state)
      if cur.state == "done" or cur.state == "idle" then turn_started = 0 end
      prev_state = cur.state
    end

    -- Re-render only when the result could differ: a new signature, or a live-timer state
    -- whose elapsed text keeps ticking while we sit in it.
    local live = (cur.state == "thinking" or cur.state == "tool")

    -- "Still working" nudge: once a live turn crosses the threshold, fire once and remember
    -- this turn's startedAt so a new turn (different startedAt) re-arms it on its own.
    if cfg.notify_long_turn and live and cur.startedAt > 0
      and long_turn_notified ~= cur.startedAt
      and (os.time() - cur.startedAt) > cfg.long_turn_seconds then
      long_turn_notified = cur.startedAt
      notify_long_turn()
    end

    local sig = cur.state .. "|" .. (cur.label or "") .. "|" .. tostring(cur.startedAt)
    if cfg.show_aggregate then sig = sig .. "|" .. agg_total .. "|" .. agg_working end
    if cfg.show_tokens then sig = sig .. "|" .. tostring(cur.tokens) .. "|" .. tostring(cur.cost) end
    -- The rendered badge string covers both the pct and the (minute-granular) countdown.
    if cfg.show_quota then sig = sig .. "|" .. quota_badge() end
    if live or sig ~= applied_sig then
      applied_sig = sig
      apply()
    end
  end,
}

-- Poll the Anthropic Statuspage (async via curl, so the event loop never blocks). On a
-- none<->incident transition we notify and refresh the widget; otherwise we just remember it.
-- Autostarts itself; we keep no reference to the timer.
gears.timer {
  timeout = cfg.service_poll_seconds,
  call_now = true,
  autostart = cfg.check_service and has_curl,
  callback = function()
    awful.spawn.easy_async(
      { "curl", "-fsS", "--max-time", "5", cfg.service_url },
      function(stdout)
        local ok, t = pcall(json.decode, stdout)
        if not ok or type(t) ~= "table" or type(t.status) ~= "table" then return end
        local was_down = service_down()
        service.indicator = t.status.indicator or "none"
        service.description = t.status.description or ""
        local now_down = service_down()
        if now_down ~= was_down then
          notify_service(now_down and "down" or "up", service.description)
          apply()
        end
      end)
  end,
}

--==[ Active-sessions popup menu ]==--------------------------------------------
local statusbar_dir = os.getenv("HOME") .. "/.claude/statusbar/"
local marker_dir = statusbar_dir .. "sessions.d/"
local sess_state_dir = statusbar_dir .. "sessions-state/"
local sess_win_dir = statusbar_dir .. "sessions-win/"
local Gio = lgi.Gio

-- List a directory's entries; Gio first (no subprocess), falling back to `ls`.
local function list_dir(path)
  local out = {}
  local ok = pcall(function()
    local en = Gio.File.new_for_path(path):enumerate_children("standard::name", Gio.FileQueryInfoFlags.NONE)
    if not en then return end
    while true do
      local info = en:next_file()
      if not info then break end
      out[#out + 1] = info:get_name()
    end
  end)
  if not ok then
    out = {}
    local p = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
    if p then for l in p:lines() do out[#out + 1] = l end p:close() end
  end
  return out
end

local function read_session(id)
  local f = io.open(sess_state_dir .. id .. ".json", "r")
  if not f then return nil end
  local raw = f:read("*a"); f:close()
  return json.decode(raw)
end

-- The X11 window hosting this session, captured by lifecycle.js at SessionStart.
-- (forward-declared above so notify() can answer permission prompts.)
function read_window_id(id)
  local f = io.open(sess_win_dir .. id, "r")
  if not f then return nil end
  local raw = f:read("*a"); f:close()
  return tonumber((raw or ""):match("%d+"))
end

-- Find the awesome client owning `winid` and jump to it (switch tag, unminimize, raise,
-- focus). Returns true on success. terminator shares one pid across windows, so we match
-- on the exact X11 window id, not the pid. (forward-declared above for notify().)
function focus_window(winid)
  if not winid then return false end
  for _, c in ipairs(client.get()) do
    if c.window == winid then
      c.minimized = false
      c:jump_to(false)
      return true
    end
  end
  return false
end

local function state_color(s)
  if s == "permission" then return cfg.amber
  elseif s == "thinking" or s == "tool" then return cfg.brand
  elseif s == "waiting" then return "#6c9bd1"
  else return "#8a8a8a" end
end

local STATE_TEXT = {
  thinking = "Thinking", tool = "Working", permission = "Awaiting permission",
  waiting = "Waiting", done = "Done", idle = "Idle",
}

-- Forward declaration so session_row's click handler can close the popup (the popup
-- itself is created further down).
local menu

local function session_row(info, winid)
  local title = (info.project and info.project ~= "") and info.project or "session"
  local sub = info.label
  if sub == nil or sub == "" then sub = STATE_TEXT[info.state] or info.state or "" end
  if info.startedAt and info.startedAt > 0 then sub = sub .. "  ·  " .. fmt_elapsed(info.startedAt) end
  -- Rows with a known window get a hint glyph and become clickable to jump to it.
  local hint = winid and " <span foreground='#666'>↗</span>" or ""
  local lines = {
    {
      markup = "<b>" .. gears.string.xml_escape(title) .. "</b>" .. hint,
      font = beautiful.font_name .. "Medium 10",
      widget = wibox.widget.textbox,
    },
    {
      markup = "<span foreground='#aaaaaa'>" .. gears.string.xml_escape(sub) .. "</span>",
      font = beautiful.font_name .. "9",
      widget = wibox.widget.textbox,
    },
    layout = wibox.layout.fixed.vertical,
  }
  -- token / cost on its own line beneath the state.
  local tc = fmt_tok_cost(info.tokens, info.cost)
  if tc ~= "" then
    table.insert(lines, {
      markup = "<span foreground='#888888'>" .. gears.string.xml_escape(tc) .. "</span>",
      font = beautiful.font_name .. "9",
      widget = wibox.widget.textbox,
    })
  end
  local row = wibox.widget {
    {
      {
        image = make_dot(state_color(info.state), dpi(12)),
        forced_width = dpi(12), forced_height = dpi(12),
        valign = "center",
        widget = wibox.widget.imagebox,
      },
      lines,
      spacing = dpi(10),
      layout = wibox.layout.fixed.horizontal,
    },
    margins = dpi(4),
    widget = wibox.container.margin,
  }
  if winid then
    local bg = wibox.container.background(row)
    bg:connect_signal("mouse::enter", function() bg.bg = "#ffffff15" end)
    bg:connect_signal("mouse::leave", function() bg.bg = nil end)
    bg:buttons(gears.table.join(awful.button({}, 1, function()
      if menu then menu.visible = false end
      focus_window(winid)
    end)))
    return bg
  end
  return row
end

local function build_menu_widget()
  local ids = {}
  for _, m in ipairs(list_dir(marker_dir)) do
    if not m:match("%.") then ids[#ids + 1] = m end -- markers are bare ids (skip .tmp/.json)
  end
  table.sort(ids)

  local rows = { layout = wibox.layout.fixed.vertical, spacing = dpi(6) }
  rows[#rows + 1] = wibox.widget {
    markup = "<b>Claude Code</b>  <span foreground='#888'>" .. #ids ..
      (#ids == 1 and " session" or " sessions") .. "</span>",
    font = beautiful.font_name .. "Bold 10",
    widget = wibox.widget.textbox,
  }
  if cfg.check_service and service_down() then
    local desc = (service.description ~= "" and (" — " .. service.description)) or ""
    rows[#rows + 1] = wibox.widget {
      markup = "<span foreground='" .. cfg.down .. "'>● Claude down" ..
        gears.string.xml_escape(desc) .. "</span>",
      font = beautiful.font_name .. "9",
      widget = wibox.widget.textbox,
    }
  end
  -- Account-wide usage quota (#68): full detail here, the bar badge stays compact.
  -- Windows past the warn threshold render in the incident color.
  if cfg.show_quota and quota then
    local segs = {}
    local function seg(name, w, datefmt)
      if not w or type(w.pct) ~= "number" then return end
      local color = (w.pct >= cfg.quota_warn_percent) and cfg.down or "#888888"
      segs[#segs + 1] = string.format("<span foreground='%s'>%s %d%% — resets %s</span>",
        color, name, math.floor(w.pct + 0.5),
        os.date(datefmt, tonumber(w.resetsAt) or 0))
    end
    seg("Session", quota.fiveHour, "%H:%M")
    seg("Week", quota.sevenDay, "%a %H:%M")
    seg("Opus", quota.sevenDayOpus, "%a %H:%M")
    if #segs > 0 then
      rows[#rows + 1] = wibox.widget {
        markup = table.concat(segs, "<span foreground='#888888'>   ·   </span>"),
        font = beautiful.font_name .. "9",
        widget = wibox.widget.textbox,
      }
    end
  end
  if #ids == 0 then
    rows[#rows + 1] = wibox.widget {
      markup = "<span foreground='#888'><i>No active sessions</i></span>",
      widget = wibox.widget.textbox,
    }
  else
    for _, id in ipairs(ids) do
      rows[#rows + 1] = session_row(
        read_session(id) or { state = "idle", project = "", label = "", startedAt = 0 },
        read_window_id(id))
    end
  end

  return wibox.widget {
    { rows, margins = dpi(12), widget = wibox.container.margin },
    bg = beautiful.bg_normal or "#1e1e2e",
    widget = wibox.container.background,
  }
end

menu = awful.popup {
  widget = wibox.widget.textbox(""),
  ontop = true,
  visible = false,
  border_width = dpi(1),
  border_color = beautiful.border_color or "#45475a",
  bg = beautiful.bg_normal or "#1e1e2e",
  maximum_width = dpi(380),
  shape = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, dpi(10)) end,
}

local function toggle_menu()
  if menu.visible then menu.visible = false; return end
  menu.widget = build_menu_widget()
  menu.visible = true
  local geo = mouse.current_widget_geometry
  if geo then
    awful.placement.next_to(menu, { preferred_positions = "bottom", preferred_anchors = "back", geometry = geo })
  else
    awful.placement.top_right(menu, { margins = { top = dpi(44), right = dpi(8) }, parent = mouse.screen })
  end
  awful.placement.no_offscreen(menu)
end

--==[ Settings menu (right-click) ]==-------------------------------------------
local function set_style(s)
  if s == cfg.style then return end
  cfg.style = s; save_settings()
  -- The icon widget is built per-style (imagebox vs textbox) and frames load once,
  -- so a clean restart is the simplest, race-free way to switch styles.
  awesome.restart()
end

local function bullet(on) return on and "● " or "○ " end
local function check(on) return on and "✓ " or "    " end

local function build_settings_menu()
  return awful.menu {
    items = {
      { "Animation style", {
        { bullet(cfg.style == "crab") .. "Crab walking",      function() set_style("crab") end },
        { bullet(cfg.style == "clawd") .. "Clawd emotes",     function() set_style("clawd") end },
        { bullet(cfg.style == "web") .. "Claude spark",       function() set_style("web") end },
        { bullet(cfg.style == "code") .. "Claude Code glyphs", function() set_style("code") end },
      } },
      { check(cfg.show_timer) .. "Show timer",
        function() cfg.show_timer = not cfg.show_timer; save_settings(); apply() end },
      { check(cfg.show_aggregate) .. "Show session badge",
        function() cfg.show_aggregate = not cfg.show_aggregate; save_settings(); apply() end },
      { check(cfg.show_tokens) .. "Show tokens / cost",
        function() cfg.show_tokens = not cfg.show_tokens; save_settings(); apply() end },
      { check(cfg.show_quota) .. "Show usage quota",
        function() cfg.show_quota = not cfg.show_quota; save_settings(); apply() end },
      { check(cfg.notify_permission) .. "Notify on permission",
        function() cfg.notify_permission = not cfg.notify_permission; save_settings() end },
      { check(cfg.notify_permission_actions) .. "Yes/No buttons on permission",
        function() cfg.notify_permission_actions = not cfg.notify_permission_actions; save_settings() end },
      { check(cfg.notify_done) .. "Notify on done",
        function() cfg.notify_done = not cfg.notify_done; save_settings() end },
      { check(cfg.notify_long_turn) .. "Notify on long turn",
        function() cfg.notify_long_turn = not cfg.notify_long_turn; save_settings() end },
      { check(cfg.notify_quota) .. "Notify on quota threshold",
        function() cfg.notify_quota = not cfg.notify_quota; save_settings() end },
      { check(cfg.play_sounds) .. "Play sounds",
        function() cfg.play_sounds = not cfg.play_sounds; save_settings() end },
      { check(cfg.notify_service) .. "Notify on Claude outage",
        function() cfg.notify_service = not cfg.notify_service; save_settings() end },
    },
  }
end

local settings_m
local function toggle_settings_menu()
  if settings_m then settings_m:hide(); settings_m = nil; return end
  settings_m = build_settings_menu()
  settings_m:show()
end

-- Left-click "press" bounce: dip the icon on press, spring it back (with a slight overshoot)
-- on release. press_scale is a plain multiplier the icon-sizing paths already honor, so we just
-- nudge it and re-render the icon at its current natural size — works across every style.
local PRESS_DIP = 0.86
local SPRING = { 0.86, 0.90, 0.96, 1.04, 1.07, 1.05, 1.0 } -- played one value per tick on release
local function render_icon_scale()
  if is_code then apply(); return end -- code sizes via font; apply() re-renders with press_scale
  local base = cfg.icon_size
  if is_clawd and animating then
    base = (cur.state == "idle") and dpi(CLAWD_SLEEP_SIZE) or dpi(CLAWD_WORK_SIZE)
  end
  local sz = math.floor(base * press_scale)
  icon.forced_width = sz; icon.forced_height = sz
end
local spring_i = 0
local spring_timer -- forward-declared so the callback can self-stop on the last frame
spring_timer = gears.timer {
  timeout = 0.02,
  callback = function()
    spring_i = spring_i + 1
    press_scale = SPRING[spring_i] or 1
    render_icon_scale()
    if spring_i >= #SPRING then press_scale = 1; render_icon_scale(); spring_timer:stop() end
  end,
}
local function bounce_press() spring_timer:stop(); press_scale = PRESS_DIP; render_icon_scale() end
local function bounce_release() spring_i = 0; spring_timer:again() end

-- Left click → active-sessions popup (+ press bounce); right click → settings menu.
root:buttons(gears.table.join(
  awful.button({}, 1, function() bounce_press(); toggle_menu() end, function() bounce_release() end),
  awful.button({}, 3, toggle_settings_menu)
))

-- Session windows that can be jumped to (have a captured window id), in sorted-id order.
local function session_windows()
  local list = {}
  for _, m in ipairs(list_dir(marker_dir)) do
    if not m:match("%.") then -- markers are bare ids (skip .tmp/.json)
      local w = read_window_id(m)
      if w then list[#list + 1] = { id = m, winid = w } end
    end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

-- Jump to a specific session's terminal by id. Returns true if it had a window we focused.
local cycle_last = nil -- last session we focused, so cycle can advance when focus left the set
local function focus_session_by_id(id)
  local w = id and read_window_id(id) or nil
  if w and focus_window(w) then cycle_last = id; return true end
  return false
end

-- Focus the next session window after the currently-focused one (or after the last one we
-- jumped to), wrapping around. Lets you tab through Claude terminals without the mouse.
local function cycle_sessions()
  local list = session_windows()
  if #list == 0 then return false end
  local cur_win = client.focus and client.focus.window
  local idx = 0 -- 0 ⇒ not currently on a session window; idx%#list+1 then starts at the first
  for i, s in ipairs(list) do
    if (cur_win and s.winid == cur_win) or (not cur_win and s.id == cycle_last) then idx = i; break end
  end
  return focus_session_by_id(list[idx % #list + 1].id)
end

-- Exposed so you can bind keys, e.g.:
--   awful.key({ modkey }, "z", function() require("ui.bar.widgets.claude_status").toggle_sessions_menu() end)
--   awful.key({ modkey }, "c", function() require("ui.bar.widgets.claude_status").cycle_sessions() end)
root.toggle_sessions_menu = toggle_menu
root.toggle_settings_menu = toggle_settings_menu
root.cycle_sessions = cycle_sessions
root.focus_session_by_id = focus_session_by_id

-- Initial render: run the poll once now (read_window_id/focus_window are defined by this point,
-- so an at-startup "permission" state can safely build its Yes/No actions). Replaces call_now.
poll_timer:emit_signal("timeout")

return root
