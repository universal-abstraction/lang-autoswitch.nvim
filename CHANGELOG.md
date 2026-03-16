# Changelog

## Unreleased
- Add Sway backend and configurable backend selection.
- Move backend-specific options into `backend_config` (with inline backend config support).
- Make `default_layout` backend-specific and remove keymap mapping helpers.
- Keep cache TTL global while passing it into backends by default.
- Add `log_level` for verbose debug output.
- Update docs/README for the new backend model.
