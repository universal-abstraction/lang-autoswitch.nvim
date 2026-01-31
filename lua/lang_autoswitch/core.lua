local uv = vim.uv or vim.loop

local Core = {}
Core.__index = Core

local function now_ms()
  if uv and uv.now then
    return uv.now()
  end
  return math.floor(os.time() * 1000)
end

local function epoch_ms()
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
    lock_owned = false,
    lock_blocked = false,
    lock_polling = false,
    pending_kind = nil,
    release_after_finish = false,
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
  if self.state.release_after_finish then
    self.state.release_after_finish = false
    self.state.pending_intent = nil
    self:_release_lock()
    return
  end
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

function Core:_lock_path()
  if self.opts.focus_lock_path and self.opts.focus_lock_path ~= "" then
    return self.opts.focus_lock_path
  end
  return vim.fn.stdpath("state") .. "/lang-autoswitch.lock"
end

function Core:_lock_ttl_ms()
  return tonumber(self.opts.focus_lock_ttl_ms) or 2500
end

function Core:_lock_poll_ms()
  return tonumber(self.opts.focus_lock_poll_ms) or 50
end

function Core:_lock_is_stale(path)
  local ttl = self:_lock_ttl_ms()
  if ttl <= 0 then
    return false
  end
  local stat = uv and uv.fs_stat and uv.fs_stat(path) or nil
  if stat and stat.mtime and stat.mtime.sec then
    local age = epoch_ms() - (stat.mtime.sec * 1000)
    return age > ttl
  end
  return false
end

function Core:_try_acquire_lock()
  if not self.opts.focus_lock then
    return true
  end
  if self.state.lock_owned then
    return true
  end
  local path = self:_lock_path()
  local stat = uv and uv.fs_stat and uv.fs_stat(path) or nil
  if stat then
    if not self:_lock_is_stale(path) then
      return false
    end
    pcall(uv.fs_rmdir, path)
  end
  local ok = uv and uv.fs_mkdir and uv.fs_mkdir(path, 448) or false
  if ok then
    self.state.lock_owned = true
    return true
  end
  return false
end

function Core:_release_lock()
  if not self.opts.focus_lock then
    return
  end
  if not self.state.lock_owned then
    return
  end
  local path = self:_lock_path()
  pcall(uv.fs_rmdir, path)
  self.state.lock_owned = false
  self.state.lock_blocked = false
end

function Core:_start_lock_poll()
  if self.state.lock_polling then
    return
  end
  self.state.lock_polling = true
  local function tick()
    if not self.state.lock_blocked then
      self.state.lock_polling = false
      return
    end
    if self:_try_acquire_lock() then
      self.state.lock_blocked = false
      self.state.lock_polling = false
      local kind = self.state.pending_kind
      self.state.pending_kind = nil
      if kind then
        self:_handle_action(kind)
      end
      return
    end
    vim.defer_fn(tick, self:_lock_poll_ms())
  end
  vim.defer_fn(tick, self:_lock_poll_ms())
end

function Core:_handle_action(kind)
  if kind == "set_default" then
    self:set_default()
    return
  end
  if kind == "restore_prev" then
    self:restore_prev()
    return
  end
end

function Core:focus_enter(kind)
  if not self.opts.focus_lock then
    self:_handle_action(kind)
    return
  end
  if self:_try_acquire_lock() then
    self.state.lock_blocked = false
    self.state.pending_kind = nil
    self:_handle_action(kind)
    return
  end
  self.state.lock_blocked = true
  self.state.pending_kind = kind
  self:_start_lock_poll()
end

function Core:focus_leave(kind)
  if not self.opts.focus_lock then
    if kind == "restore_prev" then
      self:restore_prev()
    end
    return
  end
  if not self.state.lock_owned then
    return
  end
  self.state.pending_intent = nil
  if kind == "restore_prev" then
    self.state.release_after_finish = true
    if not self:restore_prev() then
      self.state.release_after_finish = false
      self:_release_lock()
    end
    return
  end
  self:_release_lock()
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
  if self.opts.focus_lock and not self.state.lock_owned then
    if self.state.lock_blocked then
      self.state.pending_kind = "set_default"
    end
    return false
  end
  if self:should_debounce("set_default") then
    return false
  end
  if not self.opts.default_layout or self.opts.default_layout == "" then
    self.state.prev_layout = nil
    return false
  end
  self:_enqueue("set_default")
  return true
end

function Core:restore_prev()
  if self.opts.focus_lock and not self.state.lock_owned then
    if self.state.lock_blocked then
      self.state.pending_kind = "restore_prev"
    end
    return false
  end
  if self:should_debounce("restore_prev") then
    return false
  end
  self:_enqueue("restore_prev")
  return true
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
