-- lua/lang_autoswitch/init.lua
--
-- Simple input layout manager for Hyprland XKB.
-- Switches to default layout on focus/InsertLeave and restores on InsertEnter/FocusLost.

local M = {}

local defaults = {
  default_layout = "us",
  restore_on_insert = true,
  set_on_focus_gained = true,
  restore_on_focus_lost = true,
  device = nil,   -- optional keyboard name from `hyprctl devices -j`
  layouts = nil,  -- optional list like { "us", "ru" } if auto-detection fails
  keymap_map = nil, -- optional map of active_keymap -> layout code
}

local state = {
  prev_layout = nil,
}

local function run(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then
    return nil, result.stderr
  end
  return result.stdout, nil
end

local function get_keyboards()
  local out = run({ "hyprctl", "devices", "-j" })
  if not out or out == "" then
    return nil
  end
  local ok, data = pcall(vim.json.decode, out)
  if not ok or type(data) ~= "table" then
    return nil
  end
  return data.keyboards
end

local function pick_keyboard(kbs, device)
  if type(kbs) ~= "table" then
    return nil
  end
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

local function get_layouts(kb, opts)
  if opts.layouts and #opts.layouts > 0 then
    return opts.layouts
  end
  return split_layouts(kb.layout)
end

local function infer_layout_from_keymap(active_keymap, map)
  if type(active_keymap) ~= "string" then
    return nil
  end
  if map then
    local mapped = map[active_keymap]
    if mapped then
      return mapped
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

local function find_layout_index(layouts, active_keymap, active_idx, keymap_map)
  if type(active_idx) == "number" then
    return active_idx
  end
  local inferred = infer_layout_from_keymap(active_keymap, keymap_map)
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

local function get_current_layout(opts)
  local kbs = get_keyboards()
  local kb = pick_keyboard(kbs, opts.device)
  if not kb then
    return nil, nil, "No keyboard found in hyprctl output"
  end
  local layouts = get_layouts(kb, opts)
  if not layouts then
    return nil, nil, "No layouts available"
  end
  local idx = find_layout_index(layouts, kb.active_keymap, kb.active_keymap_index, opts.keymap_map)
  return layouts[idx + 1], kb, nil
end

local function set_layout(opts, target)
  local kbs = get_keyboards()
  local kb = pick_keyboard(kbs, opts.device)
  if not kb then
    return false, "No keyboard found in hyprctl output"
  end
  local layouts = get_layouts(kb, opts)
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
  local device = opts.device or kb.name
  local _, err = run({ "hyprctl", "switchxkblayout", device, tostring(idx) })
  if err then
    return false, err
  end
  return true, nil
end

local function set_default(opts)
  local current = get_current_layout(opts)
  if not current then
    return
  end
  if current ~= opts.default_layout then
    state.prev_layout = current
    local ok, err = set_layout(opts, opts.default_layout)
    if not ok and err then
      vim.notify(("lang_autoswitch: failed to set default layout: %s"):format(err), vim.log.levels.WARN)
    end
  end
end

local function restore_prev(opts)
  if state.prev_layout and state.prev_layout ~= opts.default_layout then
    local ok, err = set_layout(opts, state.prev_layout)
    if not ok and err then
      vim.notify(("lang_autoswitch: failed to restore layout: %s"):format(err), vim.log.levels.WARN)
    end
  end
end

function M.setup(user_opts)
  local opts = vim.tbl_deep_extend("force", {}, defaults, user_opts or {})
  if vim.fn.executable("hyprctl") ~= 1 then
    vim.notify("lang_autoswitch: hyprctl not found in PATH", vim.log.levels.WARN)
    return
  end

  local group = vim.api.nvim_create_augroup("LangAutoswitch", { clear = true })

  if opts.set_on_focus_gained then
    vim.api.nvim_create_autocmd("FocusGained", {
      group = group,
      callback = function()
        local mode = vim.api.nvim_get_mode().mode
        if mode:find("i") then
          return
        end
        set_default(opts)
      end,
      desc = "Set default layout on focus gained",
    })
  end

  if opts.restore_on_focus_lost then
    vim.api.nvim_create_autocmd("FocusLost", {
      group = group,
      callback = function()
        restore_prev(opts)
      end,
      desc = "Restore previous layout on focus lost",
    })
  end

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function()
      set_default(opts)
    end,
    desc = "Set default layout on InsertLeave",
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function()
      if opts.restore_on_insert then
        restore_prev(opts)
      else
        set_default(opts)
      end
    end,
    desc = "Restore previous layout on InsertEnter",
  })
end

return M
