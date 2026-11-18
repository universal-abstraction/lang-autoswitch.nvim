local util = require("lang_autoswitch.util")

local now_ms = util.now_ms
local run_async = util.run_async

local Backend = {}
Backend.__index = Backend

function Backend.new(cfg)
  local self = setmetatable({}, Backend)
  self.cfg = cfg or {}
  self.state = { cache = { kbs = nil, at = 0 } }
  return self
end

function Backend:get_keyboards(fresh, cb)
  local ttl = tonumber(self.cfg.cache_ttl_ms) or 0
  if not fresh and ttl > 0 and self.state.cache.kbs then
    local age = now_ms() - (self.state.cache.at or 0)
    if age <= ttl then
      cb(self.state.cache.kbs, nil)
      return
    end
  end

  run_async({ "hyprctl", "devices", "-j" }, function(out, err)
    if not out or out == "" then
      cb(nil, err or "Empty backend output")
      return
    end
    local ok, data = pcall(vim.json.decode, out)
    if not ok or type(data) ~= "table" then
      cb(nil, "Failed to decode backend output")
      return
    end
    self.state.cache = { kbs = data.keyboards, at = now_ms() }
    cb(data.keyboards, nil)
  end)
end

function Backend:pick_keyboard(kbs)
  if type(kbs) ~= "table" then
    return nil
  end
  local device = self.cfg.device
  local main_kb
  for _, kb in ipairs(kbs) do
    if kb.main then
      main_kb = kb
      break
    end
  end
  if device then
    for _, kb in ipairs(kbs) do
      if kb.name == device then
        return kb
      end
    end
  end
  return main_kb or kbs[1]
end

local function split_layouts(layout_str)
  if type(layout_str) ~= "string" or layout_str == "" then
    return nil
  end
  local layouts = {}
  for item in layout_str:gmatch("[^,%s]+") do
    table.insert(layouts, item)
  end
  return layouts[1] and layouts or nil
end

function Backend:get_layouts(kb)
  if self.cfg.layouts and #self.cfg.layouts > 0 then
    return self.cfg.layouts
  end
  return split_layouts(kb.layout)
end

function Backend:get_active(kb)
  return {
    keymap = kb.active_keymap,
    index = kb.active_keymap_index,
  }
end

function Backend:get_default_layout()
  return self.cfg.default_layout or "us"
end

function Backend:set_layout(kb, index, cb)
  local device = self.cfg.device or kb.name
  run_async({ "hyprctl", "switchxkblayout", device, tostring(index) }, function(_, err)
    if err then
      cb(false, err)
      return
    end
    cb(true, nil)
  end)
end

function Backend:is_available()
  if vim.fn.executable("hyprctl") ~= 1 then
    return false, "lang_autoswitch: hyprctl not found in PATH"
  end
  return true, nil
end

return Backend
