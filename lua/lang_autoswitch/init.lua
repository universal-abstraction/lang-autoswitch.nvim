local Core = require("lang_autoswitch.core")

local M = {}

local defaults = {
  backend = "hyprland",
  backend_config = nil,
  default_layout = "us", -- deprecated (use backend_config.default_layout)
  restore_on_insert = true,
  set_on_focus_gained = true,
  restore_on_focus_lost = true,
  set_on_vimenter = true,
  set_on_insertleave = true,
  restore_only_if_default = true,
  device = nil,   -- deprecated (use backend_config.device)
  layouts = nil,  -- deprecated (use backend_config.layouts)
  keymap_map = nil, -- deprecated
  keymap_regex_map = nil, -- deprecated
  cache_ttl_ms = 1000, -- cache backend query output for this many ms
  debounce_ms = 75, -- debounce layout switching to reduce duplicate calls
  focus_lock = true, -- serialize focus transitions across instances
  focus_lock_path = nil, -- optional lock file path
  focus_lock_ttl_ms = 2500, -- consider lock stale after this many ms
  focus_lock_poll_ms = 50, -- retry interval while waiting for lock
}

local core
local backend

local function resolve_backend_module(name)
  if name == "sway" then
    return require("lang_autoswitch.backend.sway")
  end
  return require("lang_autoswitch.backend.hyprland")
end

local function normalize_backend(opts)
  if type(opts.backend) == "table" and opts.backend.get_keyboards and not opts.backend.new then
    if opts.backend.cfg or opts.backend.state then
      return opts.backend, opts
    end
  end

  local backend_name = opts.backend
  local backend_config = opts.backend_config or {}

  if type(opts.backend) == "table" and opts.backend.new and not opts.backend.name then
    local legacy = {
      default_layout = opts.default_layout,
      device = opts.device,
      layouts = opts.layouts,
    }
    backend_config = vim.tbl_deep_extend("force", {}, legacy, backend_config)
    if backend_config.cache_ttl_ms == nil then
      backend_config.cache_ttl_ms = opts.cache_ttl_ms
    end
    local instance = opts.backend.new and opts.backend.new(backend_config) or opts.backend
    return instance, opts
  end

  if type(opts.backend) == "table" then
    backend_name = opts.backend.name or backend_name
    backend_config = vim.tbl_deep_extend("force", {}, backend_config, opts.backend)
    backend_config.name = nil
  end

  local legacy = {
    default_layout = opts.default_layout,
    device = opts.device,
    layouts = opts.layouts,
  }
  backend_config = vim.tbl_deep_extend("force", {}, legacy, backend_config)
  if backend_config.cache_ttl_ms == nil then
    backend_config.cache_ttl_ms = opts.cache_ttl_ms
  end

  local backend_module = resolve_backend_module(backend_name)
  local instance = backend_module.new and backend_module.new(backend_config) or backend_module
  return instance, opts
end

function M._self_check(user_opts)
  local opts = vim.tbl_deep_extend("force", {}, defaults, user_opts or {})
  local active_backend = normalize_backend(opts)
  local instance = Core.new(active_backend, opts)
  return instance:self_check()
end

function M.setup(user_opts)
  local opts = vim.tbl_deep_extend("force", {}, defaults, user_opts or {})
  backend = normalize_backend(opts)
  if backend.is_available then
    local ok, msg = backend:is_available()
    if not ok then
      vim.notify(msg or "lang_autoswitch: backend unavailable", vim.log.levels.WARN)
      return
    end
  end

  core = Core.new(backend, opts)
  local group = vim.api.nvim_create_augroup("LangAutoswitch", { clear = true })

  if opts.set_on_focus_gained then
    vim.api.nvim_create_autocmd("FocusGained", {
      group = group,
      callback = function()
        local mode = vim.api.nvim_get_mode().mode
        if mode:find("i") then
          core:focus_enter("noop")
          return
        end
        core:focus_enter("set_default")
      end,
      desc = "Set default layout on focus gained",
    })
  end

  if opts.set_on_vimenter then
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      callback = function()
        local mode = vim.api.nvim_get_mode().mode
        if mode:find("i") then
          core:focus_enter("noop")
          return
        end
        core:focus_enter("set_default")
      end,
      desc = "Set default layout on startup",
    })
  end

  if opts.restore_on_focus_lost then
    vim.api.nvim_create_autocmd("FocusLost", {
      group = group,
      callback = function()
        core:focus_leave("restore_prev")
      end,
      desc = "Restore previous layout on focus lost",
    })
  end

  if opts.set_on_insertleave then
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = group,
      callback = function()
        core:set_default()
      end,
      desc = "Set default layout on InsertLeave",
    })
  end

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function()
      if opts.restore_on_insert then
        core:restore_prev()
      else
        core:set_default()
      end
    end,
    desc = "Restore previous layout on InsertEnter",
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      core:focus_leave("restore_prev")
    end,
    desc = "Restore and release lock on exit",
  })

  vim.api.nvim_create_user_command("LangAutoswitchSelfCheck", function()
    local ok, msg = core:self_check()
    local level = ok and vim.log.levels.INFO or vim.log.levels.WARN
    vim.notify(msg, level)
  end, { desc = "Run lang-autoswitch environment self-check" })
end

return M
