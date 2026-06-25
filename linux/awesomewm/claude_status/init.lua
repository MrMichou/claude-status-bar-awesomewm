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
  icon_size      = dpi(18),
  show_timer     = true,
  hide_when_idle = false,        -- false: show the resting logo at idle (like macOS)
  notify_permission = true,
  notify_done       = true,
  done_min_seconds  = 60,        -- only notify "done" for turns at least this long (0 = always)
  sound_cmd      = nil,          -- e.g. "paplay /usr/share/sounds/freedesktop/stereo/complete.oga"
  poll_seconds   = 0.4,
}
local FPS = { web = 9, crab = 12.5 }
-- "code" style: Claude Code's terminal glyph spinner, tweened with a scale pulse.
local CODE = { glyphs = { "✻", "✽", "✶", "✳", "✢" }, sub = 18, dip = 0.14, base_pt = 14, cycle = 3.8 }
--==============================================================================

-- Persisted settings (the right-click menu) override the cfg defaults above so
-- your picks survive an Awesome restart.
local settings_path = os.getenv("HOME") .. "/.claude/statusbar/widget.json"
local function load_settings()
  local f = io.open(settings_path, "r"); if not f then return end
  local raw = f:read("*a"); f:close()
  local t = json.decode(raw); if type(t) ~= "table" then return end
  if t.style then cfg.style = t.style end
  if t.show_timer ~= nil then cfg.show_timer = t.show_timer end
  if t.notify_permission ~= nil then cfg.notify_permission = t.notify_permission end
  if t.notify_done ~= nil then cfg.notify_done = t.notify_done end
end
local function save_settings()
  local f = io.open(settings_path, "w"); if not f then return end
  f:write(string.format([[{"style":%q,"show_timer":%s,"notify_permission":%s,"notify_done":%s}]],
    cfg.style, tostring(cfg.show_timer), tostring(cfg.notify_permission), tostring(cfg.notify_done)))
  f:close()
end
load_settings()

local state_path = os.getenv("HOME") .. "/.claude/statusbar/state.json"
local module_dir = (debug.getinfo(1, "S").source:match("^@(.*/)")) or "./"
local frames_dir = module_dir .. "frames/"

-- Paint `color` through an alpha-mask PNG -> a colored cairo surface (the macOS tint).
local function tint(path, color)
  local mask = gears.surface.load_uncached(path)
  if not mask then return nil end
  local w, h = mask:get_width(), mask:get_height()
  local out = cairo.ImageSurface.create(cairo.Format.ARGB32, w, h)
  local cr = cairo.Context(out)
  cr:set_source(gears.color(color))
  cr:mask_surface(mask, 0, 0)
  return out
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

-- Load + (for masks) tint the frame sets once.
local function load_frames()
  local set = {}
  local i = 0
  while true do
    local p = string.format("%s%s/%02d.png", frames_dir, cfg.style, i)
    local f = io.open(p, "r")
    if not f then break end
    f:close()
    set[#set + 1] = (cfg.style == "web") and tint(p, cfg.brand) or gears.surface.load_uncached(p)
    i = i + 1
  end
  return set
end

local is_code = (cfg.style == "code")
local frames = is_code and {} or load_frames()
-- Resting icon: the crab style rests on a static crab frame (stays on-brand); the
-- spark style rests on the tinted Claude logo, like the macOS app.
local resting = (cfg.style == "crab") and frames[1] or (tint(frames_dir .. "logo.png", cfg.brand) or frames[1])
local dot = make_dot(cfg.amber, cfg.icon_size)
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
-- The crab sits a touch high in its slot; nudge it down so it lines up better.
local icon_slot = (cfg.style == "crab") and wibox.widget {
  icon,
  top = dpi(4),
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
  icon.font = beautiful.font_name .. string.format("%.1f", math.max(1, CODE.base_pt * scale))
  icon.markup = string.format("<span color='%s'>%s</span>", color, CODE.glyphs[i + 1])
end
local function code_static(glyph, color)
  icon.font = beautiful.font_name .. string.format("%.1f", CODE.base_pt)
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
      if #frames == 0 then return end
      frame_i = frame_i % #frames + 1
      icon.image = frames[frame_i]
    end
  end,
}

local function set_label(base, startedAt)
  local text = base or ""
  if cfg.show_timer and startedAt and startedAt > 0 then
    text = text .. "  " .. fmt_elapsed(startedAt)
  end
  label.markup = ""
  label:set_text(text)
end

-- Show a non-animated icon for the current style. kind = "permission" | "rest".
local function show_static(kind)
  if is_code then
    if kind == "permission" then code_static("●", cfg.amber) else code_static(CODE.glyphs[1], cfg.brand) end
  else
    icon.image = (kind == "permission") and dot or resting
  end
end

local function apply()
  local s = cur.state
  local animate = (s == "thinking" or s == "tool")

  if animate then
    if not animating then animating = true; anim_timer:again() end
    if is_code then set_code_icon(frame_i, cfg.brand) else icon.image = frames[frame_i] or resting end
    local base = (cur.label ~= "" and cur.label) or (s == "tool" and "Working…" or "Thinking…")
    set_label(base, cur.startedAt)
    root.visible = true
  else
    animating = false; anim_timer:stop()
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

local function notify(state)
  local project = cur.project and cur.project ~= "" and (" — " .. cur.project) or ""
  if state == "permission" and cfg.notify_permission then
    naughty.notification {
      title = "Claude Code",
      message = "Awaiting permission" .. project,
      urgency = "normal",
      icon = resting,
    }
  elseif state == "done" and cfg.notify_done then
    local dur = (turn_started > 0) and (os.time() - turn_started) or 0
    if dur >= cfg.done_min_seconds then
      naughty.notification {
        title = "Claude Code",
        message = "Done" .. project,
        icon = resting,
      }
      if cfg.sound_cmd then awful.spawn.with_shell(cfg.sound_cmd) end
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

local poll = gears.timer {
  timeout = cfg.poll_seconds,
  call_now = true,
  autostart = true,
  callback = function()
    local st = read_state()
    if not st then
      cur = { state = "idle", label = "", startedAt = 0 }
    else
      local eff = effective_state(st)
      cur = {
        state = eff,
        label = (eff == "idle") and "" or (st.label or ""),
        startedAt = tonumber(st.startedAt) or 0,
        project = st.project or "",
      }
    end

    if cur.startedAt > 0 then turn_started = cur.startedAt end

    if cur.state ~= prev_state then
      notify(cur.state)
      if cur.state == "done" or cur.state == "idle" then turn_started = 0 end
      prev_state = cur.state
    end

    apply()
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
local function read_window_id(id)
  local f = io.open(sess_win_dir .. id, "r")
  if not f then return nil end
  local raw = f:read("*a"); f:close()
  return tonumber((raw or ""):match("%d+"))
end

-- Find the awesome client owning `winid` and jump to it (switch tag, unminimize, raise,
-- focus). Returns true on success. terminator shares one pid across windows, so we match
-- on the exact X11 window id, not the pid.
local function focus_window(winid)
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
  local row = wibox.widget {
    {
      {
        image = make_dot(state_color(info.state), dpi(12)),
        forced_width = dpi(12), forced_height = dpi(12),
        valign = "center",
        widget = wibox.widget.imagebox,
      },
      {
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
      },
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
        { bullet(cfg.style == "web") .. "Claude spark",       function() set_style("web") end },
        { bullet(cfg.style == "code") .. "Claude Code glyphs", function() set_style("code") end },
      } },
      { check(cfg.show_timer) .. "Show timer",
        function() cfg.show_timer = not cfg.show_timer; save_settings(); apply() end },
      { check(cfg.notify_permission) .. "Notify on permission",
        function() cfg.notify_permission = not cfg.notify_permission; save_settings() end },
      { check(cfg.notify_done) .. "Notify on done",
        function() cfg.notify_done = not cfg.notify_done; save_settings() end },
    },
  }
end

local settings_m
local function toggle_settings_menu()
  if settings_m then settings_m:hide(); settings_m = nil; return end
  settings_m = build_settings_menu()
  settings_m:show()
end

-- Left click → active-sessions popup; right click → settings menu.
root:buttons(gears.table.join(
  awful.button({}, 1, toggle_menu),
  awful.button({}, 3, toggle_settings_menu)
))

-- Exposed so you can bind keys, e.g.:
--   awful.key({ modkey }, "z", function() require("ui.bar.widgets.claude_status").toggle_sessions_menu() end)
root.toggle_sessions_menu = toggle_menu
root.toggle_settings_menu = toggle_settings_menu

apply()

return root
