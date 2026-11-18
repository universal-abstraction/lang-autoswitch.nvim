# Changelog

## Unreleased

### Added
- Sway backend and configurable backend selection.
- `log_level` option for verbose debug output.
- Headless tests with a fake backend (`make test`) and CI on Neovim 0.10
  and stable. The environment self-check moved to `make check`.

### Changed
- Backend-specific options moved into `backend_config` (inline backend config
  is also supported). Top-level `default_layout`, `device` and `layouts` still
  work but are deprecated.
- `default_layout` is backend-specific: Hyprland defaults to `"us"`, Sway
  requires it to be set.
- Keymap mapping helpers removed.
- The global `cache_ttl_ms` is passed to the backend unless the backend config
  sets its own.

### Fixed
- Backend callbacks run on the main loop. They used to run in a fast libuv
  callback, where `vim.notify` fails with E5560, so a failed layout switch
  raised an error instead of showing a warning.
- An unknown backend name is reported instead of silently using Hyprland.
- A backend object passed as `backend` is used as is instead of being rebuilt
  without its config.
- An instance whose focus lock was taken over no longer restores its layout
  over the new owner's switch or removes the new owner's lock.
- Error messages name the missing layout and the available ones.
