# lang-autoswitch.nvim

Small Neovim plugin to auto-switch XKB layouts via pluggable backends.

## Features
- Set a default layout on `InsertLeave` and `FocusGained`.
- Restore previous layout on `InsertEnter` and `FocusLost`.
- Optional device/layout overrides.
- Backend architecture (currently Hyprland only).

## Usage (Default Behavior)
- On startup (`VimEnter`), the default layout is enforced.
- While focused in Normal mode, the default layout is enforced.
- When entering Insert or losing focus, the previous layout is restored.

## Requirements
- Neovim 0.10+ (uses `vim.system`).
- Hyprland with `hyprctl` in PATH (only supported backend for now).

## Backends
- `hyprland` (current): uses `hyprctl devices -j` and `hyprctl switchxkblayout`.
- Other backends are planned but not yet implemented.

## Install (lazy.nvim)
```lua
{
  "your-user/lang-autoswitch.nvim",
  config = function()
    require("lang_autoswitch").setup()
  end,
}
```

Optional configuration:
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
- `default_layout` (string): layout to enforce in normal mode (default: `us`).
- `restore_on_insert` (bool): restore previous layout on insert.
- `set_on_focus_gained` (bool): enforce default on focus.
- `restore_on_focus_lost` (bool): restore on focus lost.
- `set_on_vimenter` (bool): enforce default on startup.
- `set_on_insertleave` (bool): enforce default on insert leave.
- `device` (string|nil): keyboard name from `hyprctl devices -j`.
- `layouts` (table|nil): explicit layouts list (e.g. `{ "us", "ru" }`).
- `keymap_map` (table|nil): map of `active_keymap` to layout code.
- `keymap_regex_map` (table|nil): list of `{ pattern = "English", layout = "us" }`.
- `cache_ttl_ms` (number): cache `hyprctl devices -j` for N ms (default 1000).
- `debounce_ms` (number): debounce layout switching in ms (default 75).

## Notes
- If focus events don’t fire in terminal, ensure `focus-events` are enabled in tmux.

## Help
- `:h lang-autoswitch` (run `:helptags doc` after installation).

## Dev / Self-check
- `make test` runs a headless self-check using `:LangAutoswitchSelfCheck`.

## Changelog
- See `CHANGELOG.md`.

## License
- MIT, see `LICENSE`.
