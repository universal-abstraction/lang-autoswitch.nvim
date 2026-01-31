local Core = require("lang_autoswitch.core")
local hyprland = require("lang_autoswitch.backend.hyprland")

local M = {}

local defaults = {
  default_layout = "us",
  restore_on_insert = true,
  set_on_focus_gained = true,
  restore_on_focus_lost = true,
  set_on_vimenter = true,
  set_on_insertleave = true,
  restore_only_if_default = true,
  device = nil,   -- optional keyboard name from `hyprctl devices -j`
  layouts = nil,  -- optional list like { "us", "ru" } if auto-detection fails
  keymap_map = nil, -- optional map of active_keymap -> layout code
  keymap_regex_map = nil, -- optional list of { pattern = "English", layout = "us" }
  cache_ttl_ms = 1000, -- cache `hyprctl devices -j` for this many ms
  debounce_ms = 75, -- debounce layout switching to reduce duplicate calls
  focus_lock = true, -- serialize focus transitions across instances
  focus_lock_path = nil, -- optional lock file path
  focus_lock_ttl_ms = 2500, -- consider lock stale after this many ms
  focus_lock_poll_ms = 50, -- retry interval while waiting for lock
}

local core

function M._self_check(user_opts)
  local opts = vim.tbl_deep_extend("force", {}, defaults, user_opts or {})
  local instance = Core.new(hyprland, opts)
  return instance:self_check()
end

function M.setup(user_opts)
  local opts = vim.tbl_deep_extend("force", {}, defaults, user_opts or {})
  if hyprland.is_available then
    local ok, msg = hyprland.is_available()
    if not ok then
      vim.notify(msg or "lang_autoswitch: backend unavailable", vim.log.levels.WARN)
      return
    end
  end

  core = Core.new(hyprland, opts)
  local group = vim.api.nvim_create_augroup("LangAutoswitch", { clear = true })

  if opts.set_on_focus_gained then
    vim.api.nvim_create_autocmd("FocusGained", {
      group = group,
      callback = function()
        local mode = vim.api.nvim_get_mode().mode
        if mode:find("i") then
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
