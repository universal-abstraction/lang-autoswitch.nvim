# lang-autoswitch.nvim

Small Neovim plugin to auto-switch XKB layouts in Hyprland.

## Features
- Set a default layout on `InsertLeave` and `FocusGained`.
- Restore previous layout on `InsertEnter` and `FocusLost`.
- Optional device/layout overrides.

## Requirements
- Neovim 0.10+ (uses `vim.system`).
- Hyprland with `hyprctl` in PATH.

## Install (lazy.nvim)
```lua
{
  "your-user/lang-autoswitch.nvim",
  config = function()
    require("lang_autoswitch").setup({
      default_layout = "us",
      restore_on_insert = true,
      set_on_focus_gained = true,
      restore_on_focus_lost = true,
      device = "at-translated-set-2-keyboard",
      layouts = { "us", "ru" },
    })
  end,
}
```

## Options
- `default_layout` (string): layout to enforce in normal mode.
- `restore_on_insert` (bool): restore previous layout on insert.
- `set_on_focus_gained` (bool): enforce default on focus.
- `restore_on_focus_lost` (bool): restore on focus lost.
- `device` (string|nil): keyboard name from `hyprctl devices -j`.
- `layouts` (table|nil): explicit layouts list (e.g. `{ "us", "ru" }`).
- `keymap_map` (table|nil): map of `active_keymap` to layout code.

## Notes
- If focus events don’t fire in terminal, ensure `focus-events` are enabled in tmux.
