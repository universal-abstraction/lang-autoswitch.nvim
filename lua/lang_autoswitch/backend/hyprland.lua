local uv = vim.uv or vim.loop

local M = {
  name = "hyprland",
}

local state = {
  cache = { kbs = nil, at = 0 },
}

local function now_ms()
  if uv and uv.now then
    return uv.now()
  end
  return math.floor(os.time() * 1000)
end

local function run(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then
    return nil, result.stderr
  end
  return result.stdout, nil
end

function M.get_keyboards(opts)
  local ttl = tonumber(opts.cache_ttl_ms) or 0
  if ttl > 0 and state.cache.kbs then
    local age = now_ms() - (state.cache.at or 0)
    if age <= ttl then
      return state.cache.kbs
    end
  end

  local out = run({ "hyprctl", "devices", "-j" })
  if not out or out == "" then
    return nil
  end
  local ok, data = pcall(vim.json.decode, out)
  if not ok or type(data) ~= "table" then
    return nil
  end
  state.cache = { kbs = data.keyboards, at = now_ms() }
  return data.keyboards
end

function M.pick_keyboard(kbs, device)
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

function M.get_layouts(kb, opts)
  if opts.layouts and #opts.layouts > 0 then
    return opts.layouts
  end
  return split_layouts(kb.layout)
end

function M.get_active(kb, _opts)
  return {
    keymap = kb.active_keymap,
    index = kb.active_keymap_index,
  }
end

function M.set_layout(kb, opts, index)
  local device = opts.device or kb.name
  local _, err = run({ "hyprctl", "switchxkblayout", device, tostring(index) })
  if err then
    return false, err
  end
  return true, nil
end

function M.is_available()
  if vim.fn.executable("hyprctl") ~= 1 then
    return false, "lang_autoswitch: hyprctl not found in PATH"
  end
  return true, nil
end

return M
