local uv = vim.uv or vim.loop

local Core = {}
Core.__index = Core

local function now_ms()
  if uv and uv.now then
    return uv.now()
  end
  return math.floor(os.time() * 1000)
end

local function infer_layout_from_keymap(active_keymap, map, regex_map)
  if type(active_keymap) ~= "string" then
    return nil
  end
  if map then
    local mapped = map[active_keymap]
    if mapped then
      return mapped
    end
  end
  if type(regex_map) == "table" then
    for _, item in ipairs(regex_map) do
      if type(item) == "table" and type(item.pattern) == "string" and type(item.layout) == "string" then
        if active_keymap:match(item.pattern) then
          return item.layout
        end
      end
    end
  end
  local lower = active_keymap:lower()
  if lower:find("english", 1, true) then
    return "us"
  end
  if lower:find("russian", 1, true) or lower:find("рус", 1, true) then
    return "ru"
  end
  return nil
end

local function find_layout_index(layouts, active_keymap, active_idx, keymap_map, keymap_regex_map)
  if type(active_idx) == "number" then
    return active_idx
  end
  local inferred = infer_layout_from_keymap(active_keymap, keymap_map, keymap_regex_map)
  if inferred then
    for i, code in ipairs(layouts) do
      if code == inferred then
        return i - 1
      end
    end
  end
  if type(active_keymap) == "string" then
    local needle = active_keymap:lower()
    for i, code in ipairs(layouts) do
      if needle:find(code:lower(), 1, true) then
        return i - 1
      end
    end
  end
  return 0
end

function Core.new(backend, opts)
  local self = setmetatable({}, Core)
  self.backend = backend
  self.opts = opts
  self.state = {
    prev_layout = nil,
    last_action_at = {},
    last_known_layout = nil,
    last_set_layout = nil,
    last_set_at = nil,
  }
  return self
end

function Core:should_debounce(key)
  local window = tonumber(self.opts.debounce_ms) or 0
  if window <= 0 then
    return false
  end
  local now = now_ms()
  local last = self.state.last_action_at[key]
  if last and (now - last) < window then
    return true
  end
  self.state.last_action_at[key] = now
  return false
end

function Core:get_current_layout()
  local kbs = self.backend.get_keyboards(self.opts)
  local kb = self.backend.pick_keyboard(kbs, self.opts.device)
  if not kb then
    return nil, nil, "No keyboard found in backend output"
  end
  local layouts = self.backend.get_layouts(kb, self.opts)
  if not layouts then
    return nil, nil, "No layouts available"
  end
  local active = self.backend.get_active(kb, self.opts)
  local idx = find_layout_index(
    layouts,
    active and active.keymap,
    active and active.index,
    self.opts.keymap_map,
    self.opts.keymap_regex_map
  )
  local current = layouts[idx + 1]
  self.state.last_known_layout = current
  return current, kb, nil
end

function Core:set_layout(target)
  local kbs = self.backend.get_keyboards(self.opts)
  local kb = self.backend.pick_keyboard(kbs, self.opts.device)
  if not kb then
    return false, "No keyboard found in backend output"
  end
  local layouts = self.backend.get_layouts(kb, self.opts)
  if not layouts then
    return false, "No layouts available"
  end
  local idx
  for i, code in ipairs(layouts) do
    if code == target then
      idx = i - 1
      break
    end
  end
  if idx == nil then
    return false, "Target layout not in layout list"
  end
  local ok, err = self.backend.set_layout(kb, self.opts, idx)
  if ok then
    self.state.last_known_layout = target
    self.state.last_set_layout = target
    self.state.last_set_at = now_ms()
  end
  return ok, err
end

function Core:set_default()
  if self:should_debounce("set_default") then
    return
  end
  if self.state.last_known_layout == self.opts.default_layout then
    return
  end
  local current = self:get_current_layout()
  if not current then
    return
  end
  if current ~= self.opts.default_layout then
    self.state.prev_layout = current
    local ok, err = self:set_layout(self.opts.default_layout)
    if not ok and err then
      vim.notify(("lang_autoswitch: failed to set default layout: %s"):format(err), vim.log.levels.WARN)
    end
  end
end

function Core:restore_prev()
  if self:should_debounce("restore_prev") then
    return
  end
  if self.state.prev_layout and self.state.prev_layout ~= self.opts.default_layout then
    local ok, err = self:set_layout(self.state.prev_layout)
    if not ok and err then
      vim.notify(("lang_autoswitch: failed to restore layout: %s"):format(err), vim.log.levels.WARN)
    end
  end
end

function Core:self_check()
  if self.backend.is_available then
    local ok, msg = self.backend.is_available()
    if not ok then
      return false, msg or "lang_autoswitch: backend unavailable"
    end
  end
  local kbs = self.backend.get_keyboards(self.opts)
  if not kbs or #kbs == 0 then
    return false, "lang_autoswitch: no keyboards found in backend output"
  end
  local current, kb, err = self:get_current_layout()
  if not current then
    return false, ("lang_autoswitch: failed to detect current layout: %s"):format(err or "unknown error")
  end
  local name = kb and kb.name or "unknown"
  return true, ("lang_autoswitch: OK (device: %s, layout: %s)"):format(name, current)
end

return Core
