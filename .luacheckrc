-- luacheck configuration for the awesomewm widget.
std = "lua54"
max_line_length = 140

-- awesomewm callbacks routinely take args they don't use (signal payloads, widget self).
unused_args = false

-- Globals injected by the awesomewm runtime / its libraries. Declared as read-only so
-- linting init.lua does not flag them as undefined.
read_globals = {
  "awesome", "client", "screen", "mouse", "root", "tag", "drawin",
  "awful", "gears", "wibox", "beautiful", "naughty", "menubar", "lgi",
  "dpi",
}

-- Busted's spec DSL globals.
files["spec/"] = {
  std = "+busted",
}

exclude_files = {
  "node_modules/",
}
