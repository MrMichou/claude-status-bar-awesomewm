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
  style          = "web",        -- "web" (Claude spark) or "crab"
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
--==============================================================================

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

local frames = load_frames()
local resting = tint(frames_dir .. "logo.png", cfg.brand) or (frames[1])
local dot = make_dot(cfg.amber, cfg.icon_size)
local fps = FPS[cfg.style] or 9

--==[ Widgets ]==---------------------------------------------------------------
local icon = wibox.widget {
  image = resting,
  resize = true,
  forced_height = cfg.icon_size,
  forced_width = cfg.icon_size,
  widget = wibox.widget.imagebox,
}
local label = wibox.widget {
  font = beautiful.font_name .. "Medium 10",
  widget = wibox.widget.textbox,
}
local root = wibox.widget {
  {
    {
      icon,
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

local anim_timer = gears.timer {
  timeout = 1 / fps,
  callback = function()
    if not animating or #frames == 0 then return end
    frame_i = frame_i % #frames + 1
    icon.image = frames[frame_i]
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

local function apply()
  local s = cur.state
  local animate = (s == "thinking" or s == "tool")

  if animate then
    if not animating then animating = true; anim_timer:again() end
    icon.image = frames[frame_i] or resting
    local base = (cur.label ~= "" and cur.label) or (s == "tool" and "Working…" or "Thinking…")
    set_label(base, cur.startedAt)
    root.visible = true
  else
    animating = false; anim_timer:stop()
    if s == "permission" then
      icon.image = dot
      set_label("Awaiting permission", 0)
      root.visible = true
    elseif s == "waiting" then
      icon.image = resting
      set_label(cur.label, 0)
      root.visible = true
    else -- done / idle / unknown
      icon.image = resting
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

local poll = gears.timer {
  timeout = cfg.poll_seconds,
  call_now = true,
  autostart = true,
  callback = function()
    local st = read_state()
    if not st then
      cur = { state = "idle", label = "", startedAt = 0 }
    else
      cur = {
        state = st.state or "idle",
        label = st.label or "",
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

local function session_row(info)
  local title = (info.project and info.project ~= "") and info.project or "session"
  local sub = info.label
  if sub == nil or sub == "" then sub = STATE_TEXT[info.state] or info.state or "" end
  if info.startedAt and info.startedAt > 0 then sub = sub .. "  ·  " .. fmt_elapsed(info.startedAt) end
  return wibox.widget {
    {
      {
        image = make_dot(state_color(info.state), dpi(12)),
        forced_width = dpi(12), forced_height = dpi(12),
        valign = "center",
        widget = wibox.widget.imagebox,
      },
      {
        {
          markup = "<b>" .. gears.string.xml_escape(title) .. "</b>",
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
      rows[#rows + 1] = session_row(read_session(id) or { state = "idle", project = "", label = "", startedAt = 0 })
    end
  end

  return wibox.widget {
    { rows, margins = dpi(12), widget = wibox.container.margin },
    bg = beautiful.bg_normal or "#1e1e2e",
    widget = wibox.container.background,
  }
end

local menu = awful.popup {
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

root:buttons(gears.table.join(
  awful.button({}, 1, toggle_menu),
  awful.button({}, 3, toggle_menu)
))

-- Also exposed so you can bind a key, e.g.:
--   awful.key({ modkey }, "c", function() require("ui.bar.widgets.claude_status").toggle_sessions_menu() end)
root.toggle_sessions_menu = toggle_menu

apply()

return root
