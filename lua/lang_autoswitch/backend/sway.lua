local uv = vim.uv or vim.loop

local Backend = {}
Backend.__index = Backend

local function now_ms()
  if uv and uv.now then
    return uv.now()
  end
  return math.floor(os.time() * 1000)
end

local function run_async(cmd, cb)
  vim.system(cmd, { text = true }, function(result)
    if result.code ~= 0 then
      cb(nil, result.stderr)
      return
    end
    cb(result.stdout, nil)
  end)
end

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

  run_async({ "swaymsg", "-t", "get_inputs" }, function(out, err)
    if not out or out == "" then
      cb(nil, err or "Empty backend output")
      return
    end
    local ok, data = pcall(vim.json.decode, out)
    if not ok or type(data) ~= "table" then
      cb(nil, "Failed to decode backend output")
      return
    end
    local kbs = {}
    for _, dev in ipairs(data) do
      if dev.type == "keyboard" then
        table.insert(kbs, dev)
      end
    end
    self.state.cache = { kbs = kbs, at = now_ms() }
    cb(kbs, nil)
  end)
end

function Backend:pick_keyboard(kbs)
  if type(kbs) ~= "table" then
    return nil
  end
  local device = self.cfg.device
  if device then
    for _, kb in ipairs(kbs) do
      if kb.identifier == device or kb.name == device then
        return kb
      end
    end
  end
  return kbs[1]
end

function Backend:get_layouts(kb)
  if self.cfg.layouts and #self.cfg.layouts > 0 then
    return self.cfg.layouts
  end
  if type(kb.xkb_layout_names) == "table" and #kb.xkb_layout_names > 0 then
    return kb.xkb_layout_names
  end
  return nil
end

function Backend:get_active(kb)
  return {
    keymap = kb.xkb_active_layout_name,
    index = tonumber(kb.xkb_active_layout_index),
  }
end

function Backend:get_default_layout()
  return self.cfg.default_layout
end

function Backend:set_layout(kb, index, cb)
  local device = self.cfg.device or kb.identifier or kb.name
  if not device then
    cb(false, "No device identifier available")
    return
  end
  run_async({ "swaymsg", "input", device, "xkb_switch_layout", tostring(index) }, function(_, err)
    if err then
      cb(false, err)
      return
    end
    cb(true, nil)
  end)
end

function Backend:is_available()
  if vim.fn.executable("swaymsg") ~= 1 then
    return false, "lang_autoswitch: swaymsg not found in PATH"
  end
  if not vim.env.SWAYSOCK or vim.env.SWAYSOCK == "" then
    return false, "lang_autoswitch: SWAYSOCK not set (is Sway running?)"
  end
  return true, nil
end

return Backend
