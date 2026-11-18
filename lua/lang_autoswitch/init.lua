local Core = require("lang_autoswitch.core")

local M = {}

local defaults = {
  backend = "hyprland",
  backend_config = nil,
  restore_on_insert = true,
  set_on_focus_gained = true,
  restore_on_focus_lost = true,
  set_on_vimenter = true,
  set_on_insertleave = true,
  restore_only_if_default = true,
  default_layout = nil, -- deprecated (use backend_config.default_layout)
  device = nil, -- deprecated (use backend_config.device)
  layouts = nil, -- deprecated (use backend_config.layouts)
  cache_ttl_ms = 1000, -- cache backend query output for this many ms
  log_level = "warn", -- trace|debug|info|warn|error or vim.log.levels.*
  debounce_ms = 75, -- debounce layout switching to reduce duplicate calls
  focus_lock = true, -- serialize focus transitions across instances
  focus_lock_path = nil, -- optional lock directory path
  focus_lock_ttl_ms = 2500, -- take over a lock older than this many ms
  focus_lock_poll_ms = 50, -- retry interval while waiting for lock
}

local core
local backend

local backend_modules = {
  hyprland = "lang_autoswitch.backend.hyprland",
  sway = "lang_autoswitch.backend.sway",
}

local function resolve_backend_module(name)
  local module = backend_modules[name]
  if not module then
    local names = vim.tbl_keys(backend_modules)
    table.sort(names)
    return nil, ("lang_autoswitch: unknown backend %q (available: %s)"):format(
      tostring(name),
      table.concat(names, ", ")
    )
  end
  return require(module)
end

-- `opts.backend` can be:
--   * a backend name: "hyprland" or "sway"
--   * an inline config: { name = "sway", default_layout = ..., ... }
--   * a backend module/class with a `new(cfg)` constructor
--   * a backend instance (returned by `new`), used as is
-- Returns the backend instance, or nil and an error message.
local function build_backend(opts)
  local b = opts.backend
  if type(b) == "table" and rawget(b, "cfg") ~= nil then
    return b
  end

  local cfg = vim.tbl_deep_extend("force", {}, {
    default_layout = opts.default_layout,
    device = opts.device,
    layouts = opts.layouts,
  }, opts.backend_config or {})

  local module, err
  if type(b) == "table" and type(b.new) == "function" then
    module = b
  elseif type(b) == "table" then
    module, err = resolve_backend_module(b.name or defaults.backend)
    local inline = vim.deepcopy(b)
    inline.name = nil
    cfg = vim.tbl_deep_extend("force", cfg, inline)
  else
    module, err = resolve_backend_module(b or defaults.backend)
  end
  if not module then
    return nil, err
  end

  if cfg.cache_ttl_ms == nil then
    cfg.cache_ttl_ms = opts.cache_ttl_ms
  end
  return module.new(cfg)
end

local function normalize_log_level(value)
  if type(value) == "number" then
    return value
  end
  if type(value) ~= "string" then
    return vim.log.levels.WARN
  end
  local key = value:upper()
  return vim.log.levels[key] or vim.log.levels.WARN
end

function M._self_check(user_opts)
  local opts = vim.tbl_deep_extend("force", {}, defaults, user_opts or {})
  opts.log_level = normalize_log_level(opts.log_level)
  local active_backend, err = build_backend(opts)
  if not active_backend then
    return false, err
  end
  local instance = Core.new(active_backend, opts)
  return instance:self_check()
end

function M.setup(user_opts)
  local opts = vim.tbl_deep_extend("force", {}, defaults, user_opts or {})
  opts.log_level = normalize_log_level(opts.log_level)
  local err
  backend, err = build_backend(opts)
  if not backend then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end
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

-- Exposed for tests.
M._build_backend = build_backend
M._get_core = function()
  return core
end

return M
