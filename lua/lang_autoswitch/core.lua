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
    intent_seq = 0,
    latest_intent_id = 0,
    active_intent_id = nil,
    in_flight = false,
    pending_intent = nil,
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

function Core:_current_from_keyboards(kbs)
  local kb = self.backend.pick_keyboard(kbs, self.opts.device)
  if not kb then
    return nil, nil, nil, "No keyboard found in backend output"
  end
  local layouts = self.backend.get_layouts(kb, self.opts)
  if not layouts then
    return nil, nil, nil, "No layouts available"
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
  return current, kb, layouts, nil
end

function Core:_get_current_layout_async(intent_id, cb, allow_stale)
  self.backend.get_keyboards(self.opts, true, function(kbs, err)
    if intent_id and not allow_stale and intent_id ~= self.state.latest_intent_id then
      cb(nil, nil, nil, "stale")
      return
    end
    if not kbs then
      cb(nil, nil, nil, err or "No keyboards found in backend output")
      return
    end
    local current, kb, layouts, cerr = self:_current_from_keyboards(kbs)
    if not current then
      cb(nil, nil, nil, cerr or "No layouts available")
      return
    end
    cb(current, kb, layouts, nil)
  end)
end

function Core:_set_layout_with_kb_async(intent_id, kb, layouts, target, cb)
  local idx
  for i, code in ipairs(layouts) do
    if code == target then
      idx = i - 1
      break
    end
  end
  if idx == nil then
    cb(false, "Target layout not in layout list")
    return
  end
  self.backend.set_layout(kb, self.opts, idx, function(ok, err)
    if intent_id and intent_id ~= self.state.latest_intent_id then
      cb(false, "stale")
      return
    end
    cb(ok, err)
  end)
end

function Core:_next_intent(kind)
  self.state.intent_seq = self.state.intent_seq + 1
  local intent = { id = self.state.intent_seq, kind = kind }
  self.state.latest_intent_id = intent.id
  return intent
end

function Core:_finish_intent(intent_id)
  if intent_id ~= self.state.active_intent_id then
    return
  end
  self.state.in_flight = false
  self.state.active_intent_id = nil
  local next_intent = self.state.pending_intent
  self.state.pending_intent = nil
  if next_intent then
    self:_start_intent(next_intent)
  end
end

function Core:_start_intent(intent)
  self.state.in_flight = true
  self.state.active_intent_id = intent.id
  self:_run_intent(intent)
end

function Core:_enqueue(kind)
  local intent = self:_next_intent(kind)
  if self.state.in_flight then
    self.state.pending_intent = intent
    return
  end
  self:_start_intent(intent)
end

function Core:_run_intent(intent)
  if intent.kind ~= "set_default" and intent.kind ~= "restore_prev" then
    self:_finish_intent(intent.id)
    return
  end
  self:_get_current_layout_async(intent.id, function(current, kb, layouts, err)
    if intent.id ~= self.state.latest_intent_id then
      self:_finish_intent(intent.id)
      return
    end
    if not current then
      self:_finish_intent(intent.id)
      return
    end
    self.state.last_known_layout = current
    if intent.kind == "set_default" then
      if not self.opts.default_layout or self.opts.default_layout == "" then
        self.state.prev_layout = nil
        self:_finish_intent(intent.id)
        return
      end
      if current == self.opts.default_layout then
        self.state.prev_layout = nil
        self:_finish_intent(intent.id)
        return
      end
      self.state.prev_layout = current
      self:_set_layout_with_kb_async(intent.id, kb, layouts, self.opts.default_layout, function(ok, serr)
        if intent.id ~= self.state.latest_intent_id then
          self:_finish_intent(intent.id)
          return
        end
        if ok then
          self.state.last_known_layout = self.opts.default_layout
          self.state.last_set_layout = self.opts.default_layout
          self.state.last_set_at = now_ms()
        elseif serr then
          vim.notify(("lang_autoswitch: failed to set default layout: %s"):format(serr), vim.log.levels.WARN)
        end
        self:_finish_intent(intent.id)
      end)
      return
    end

    if self.opts.restore_only_if_default and self.opts.default_layout and self.opts.default_layout ~= "" then
      if current ~= self.opts.default_layout then
        self.state.prev_layout = nil
        self:_finish_intent(intent.id)
        return
      end
    end
    local prev = self.state.prev_layout
    if not prev or prev == self.opts.default_layout then
      self.state.prev_layout = nil
      self:_finish_intent(intent.id)
      return
    end
    self:_set_layout_with_kb_async(intent.id, kb, layouts, prev, function(ok, serr)
      if intent.id ~= self.state.latest_intent_id then
        self:_finish_intent(intent.id)
        return
      end
      self.state.prev_layout = nil
      if ok then
        self.state.last_known_layout = prev
        self.state.last_set_layout = prev
        self.state.last_set_at = now_ms()
      elseif serr then
        vim.notify(("lang_autoswitch: failed to restore layout: %s"):format(serr), vim.log.levels.WARN)
      end
      self:_finish_intent(intent.id)
    end)
  end)
end

function Core:get_current_layout()
  local done = false
  local current, kb, err
  self:_get_current_layout_async(nil, function(cur, cur_kb, _layouts, cur_err)
    current = cur
    kb = cur_kb
    err = cur_err
    done = true
  end, true)
  vim.wait(2000, function()
    return done
  end, 10)
  if not done then
    return nil, nil, "Timeout while fetching layout"
  end
  if current then
    self.state.last_known_layout = current
  end
  return current, kb, err
end

function Core:set_default()
  if self:should_debounce("set_default") then
    return
  end
  if not self.opts.default_layout or self.opts.default_layout == "" then
    self.state.prev_layout = nil
    return
  end
  self:_enqueue("set_default")
end

function Core:restore_prev()
  if self:should_debounce("restore_prev") then
    return
  end
  self:_enqueue("restore_prev")
end

function Core:self_check()
  local done = false
  local ok, msg = false, "lang_autoswitch: self-check timed out"
  if self.backend.is_available then
    local avail, avail_msg = self.backend.is_available()
    if not avail then
      return false, avail_msg or "lang_autoswitch: backend unavailable"
    end
  end
  self.backend.get_keyboards(self.opts, true, function(kbs, err)
    if not kbs or #kbs == 0 then
      ok = false
      msg = "lang_autoswitch: no keyboards found in backend output"
      done = true
      return
    end
    local current, kb, _layouts, cerr = self:_current_from_keyboards(kbs)
    if not current then
      ok = false
      msg = ("lang_autoswitch: failed to detect current layout: %s"):format(cerr or "unknown error")
      done = true
      return
    end
    local name = kb and kb.name or "unknown"
    ok = true
    msg = ("lang_autoswitch: OK (device: %s, layout: %s)"):format(name, current)
    done = true
  end)
  vim.wait(2000, function()
    return done
  end, 10)
  return ok, msg
end

return Core
