# lang-autoswitch.nvim

[![test](https://github.com/universal-abstraction/lang-autoswitch.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/universal-abstraction/lang-autoswitch.nvim/actions/workflows/test.yml)

A Neovim plugin for Hyprland and Sway that switches the keyboard layout to
your default one (e.g. English) in Normal mode and back to the layout you were
typing in when you enter Insert mode or leave Neovim.

## How it works

- On startup, on `FocusGained` and on `InsertLeave`, the default layout is
  set. The layout that was active before is remembered.
- On `InsertEnter`, `FocusLost` and exit, the remembered layout is restored,
  but only if the plugin switched away from it and the current layout is still
  the default one. If you changed the layout yourself in between, it is left
  alone.
- Several Neovim instances share a lock file, so that the instance losing
  focus restores its layout before the one gaining focus switches to the
  default (see `focus_lock` below).

## Requirements

- Neovim 0.10+ (uses `vim.system`)
- Hyprland with `hyprctl` in `PATH`, or Sway with `swaymsg` in `PATH`

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "universal-abstraction/lang-autoswitch.nvim",
  main = "lang_autoswitch",
  opts = {},
}
```

Hyprland with an explicit keyboard and layout list:

```lua
{
  "universal-abstraction/lang-autoswitch.nvim",
  main = "lang_autoswitch",
  opts = {
    backend = "hyprland",
    backend_config = {
      default_layout = "us",
      device = "at-translated-set-2-keyboard",
      layouts = { "us", "ru" },
    },
  },
}
```

Sway (the backend config can also be given inline):

```lua
require("lang_autoswitch").setup({
  backend = {
    name = "sway",
    default_layout = "English (US)",
    device = "1:1:AT_Translated_Set_2_keyboard",
    layouts = { "English (US)", "Russian" },
  },
})
```

Run `:LangAutoswitchSelfCheck` to check that the backend sees your keyboard
and its current layout.

## Options

| Option | Default | Description |
| --- | --- | --- |
| `backend` | `"hyprland"` | `"hyprland"`, `"sway"`, an inline config `{ name = ..., ... }`, or a backend object. |
| `backend_config` | `nil` | Backend options, see below. |
| `set_on_vimenter` | `true` | Set the default layout on startup. |
| `set_on_focus_gained` | `true` | Set the default layout on `FocusGained`. |
| `set_on_insertleave` | `true` | Set the default layout on `InsertLeave`. |
| `restore_on_insert` | `true` | Restore the previous layout on `InsertEnter`. If `false`, the default layout is set instead. |
| `restore_on_focus_lost` | `true` | Restore the previous layout on `FocusLost`. |
| `restore_only_if_default` | `true` | Restore only if the current layout is still the default one. |
| `log_level` | `"warn"` | `"trace"`, `"debug"`, `"info"`, `"warn"`, `"error"` or a `vim.log.levels` value. |
| `cache_ttl_ms` | `1000` | Passed to the backend as its cache lifetime for keyboard queries. |
| `debounce_ms` | `75` | Ignore repeated switches of the same kind within this window. |
| `focus_lock` | `true` | Serialise focus transitions between Neovim instances. |
| `focus_lock_path` | `stdpath("state")/lang-autoswitch.lock` | Lock directory. |
| `focus_lock_ttl_ms` | `2500` | Age after which another instance may take the lock over. |
| `focus_lock_poll_ms` | `50` | Retry interval while waiting for the lock. |

### Backend config

Hyprland:
- `default_layout` (string): layout for Normal mode. Default: `"us"`.
- `device` (string|nil): keyboard name from `hyprctl devices -j`. Default: the
  keyboard marked as main.
- `layouts` (table|nil): layout codes in the order configured in Hyprland,
  e.g. `{ "us", "ru" }`. Default: read from the keyboard.

Sway:
- `default_layout` (string, required): layout name as Sway reports it, e.g.
  `"English (US)"`.
- `device` (string|nil): keyboard identifier from `swaymsg -t get_inputs`.
  Default: the first keyboard.
- `layouts` (table|nil): layout names in the configured order. Default: read
  from the keyboard.

### About `focus_lock`

When you switch between two Neovim windows, one gets `FocusLost` and the
other `FocusGained` at almost the same time. The lock makes the second one
wait until the first has restored its layout. An instance holds the lock while
it has focus; if a lock is older than `focus_lock_ttl_ms`, the next instance
takes it over instead of waiting, so a missing `FocusLost` event can't block
it. The previous owner then skips its restore. Because a long-held lock is
usually older than the TTL, the ordering is best-effort rather than
guaranteed.

## Notes

- Focus events in a terminal need terminal support; inside tmux, also enable
  `set -g focus-events on`.
- Layout switching is asynchronous and doesn't block the editor.

## Development

```bash
make test    # unit tests with a fake backend, no compositor needed
make check   # self-check against the running Hyprland or Sway session
```

## Help

`:h lang-autoswitch`

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](LICENSE).
