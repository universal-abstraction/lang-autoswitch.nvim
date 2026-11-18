-- Headless tests with a fake backend. No compositor needed.
-- Run with: nvim -l tests/run.lua   (or: make test)

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local uv = vim.uv or vim.loop
local Core = require("lang_autoswitch.core")
local util = require("lang_autoswitch.util")
local plugin = require("lang_autoswitch")

local failures = 0
local passed = 0

local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. "\n" .. tostring(err))
  end
end

local function eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(msg or "values differ", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

-- Fake backend. Callbacks are scheduled like the real backends' callbacks.
local Fake = {}
Fake.__index = Fake

function Fake.new(cfg)
  local self = setmetatable({}, Fake)
  self.cfg = cfg or {}
  self.layouts = { "us", "ru" }
  self.active = self.cfg.active or 1 -- 0-based index, starts on "ru"
  self.history = {}
  return self
end

function Fake:get_keyboards(_, cb)
  vim.schedule(function()
    cb({ { name = "kb", active_keymap_index = self.active } }, nil)
  end)
end

function Fake:pick_keyboard(kbs)
  return kbs[1]
end

function Fake:get_layouts()
  return self.layouts
end

function Fake:get_active(kb)
  return { index = kb.active_keymap_index }
end

function Fake:get_default_layout()
  return self.cfg.default_layout or "us"
end

function Fake:set_layout(_, index, cb)
  vim.schedule(function()
    self.active = index
    table.insert(self.history, self.layouts[index + 1])
    cb(true, nil)
  end)
end

function Fake:current()
  return self.layouts[self.active + 1]
end

local lock_dir = vim.fn.tempname()

local function new_core(backend, extra)
  local opts = vim.tbl_extend("force", {
    restore_only_if_default = true,
    log_level = vim.log.levels.ERROR,
    debounce_ms = 0,
    focus_lock = false,
    focus_lock_path = lock_dir,
    focus_lock_ttl_ms = 2500,
    focus_lock_poll_ms = 10,
  }, extra or {})
  return Core.new(backend, opts)
end

local function settle(core)
  vim.wait(1000, function()
    return not core.state.in_flight and not core.state.lock_polling
  end, 5)
end

test("run_async callback runs on the main loop", function()
  local done, api_ok, out, err = false, nil, nil, nil
  util.run_async({ "sh", "-c", "echo hi" }, function(o, e)
    out, err = o, e
    -- nvim_get_mode is not allowed in a fast (libuv) callback
    api_ok = pcall(vim.api.nvim_get_mode)
    done = true
  end)
  vim.wait(2000, function()
    return done
  end, 10)
  eq(done, true, "callback called")
  eq(api_ok, true, "API usable in callback")
  eq(out, "hi\n", "stdout")
  eq(err, nil, "no error")
end)

test("run_async reports a non-zero exit", function()
  local done, out, err = false, nil, nil
  util.run_async({ "sh", "-c", "exit 3" }, function(o, e)
    out, err = o, e
    done = true
  end)
  vim.wait(2000, function()
    return done
  end, 10)
  eq(out, nil, "no stdout")
  eq(err, "sh exited with code 3", "error message")
end)

test("run_async reports a missing executable", function()
  local done, err = false, nil
  util.run_async({ "lang-autoswitch-no-such-command" }, function(_, e)
    err = e
    done = true
  end)
  vim.wait(2000, function()
    return done
  end, 10)
  eq(done, true, "callback called")
  eq(type(err), "string", "error message")
end)

test("set_default switches and restore_prev switches back", function()
  local b = Fake.new()
  local core = new_core(b)
  core:set_default()
  settle(core)
  eq(b:current(), "us", "after set_default")
  eq(core.state.prev_layout, "ru", "previous layout remembered")
  core:restore_prev()
  settle(core)
  eq(b:current(), "ru", "after restore_prev")
  eq(b.history, { "us", "ru" }, "switch history")
end)

test("set_default does nothing when already on the default layout", function()
  local b = Fake.new({ active = 0 })
  local core = new_core(b)
  core:set_default()
  settle(core)
  core:restore_prev()
  settle(core)
  eq(b.history, {}, "no switches")
end)

test("restore is skipped when the layout changed in between", function()
  local b = Fake.new()
  local core = new_core(b)
  core:set_default()
  settle(core)
  b.active = 1 -- user switched to "ru" manually while in Normal mode
  core:restore_prev()
  settle(core)
  eq(b.history, { "us" }, "only the first switch")
end)

test("focus lock serialises two instances", function()
  local b = Fake.new()
  local a = new_core(b, { focus_lock = true })
  local c = new_core(b, { focus_lock = true })

  a:focus_enter("set_default")
  settle(a)
  eq(b:current(), "us", "A switched to default")

  c:focus_enter("set_default") -- blocked: A holds the lock
  eq(c.state.lock_blocked, true, "C waits for the lock")

  a:focus_leave("restore_prev") -- A restores, then releases
  settle(a)
  settle(c)
  eq(b.history, { "us", "ru", "us" }, "A restores before C switches")
  eq(a.state.lock_owned, false, "A released the lock")
  eq(c.state.lock_owned, true, "C holds the lock")

  c:focus_leave("restore_prev")
  settle(c)
  eq(uv.fs_stat(lock_dir), nil, "lock removed")
end)

test("a taken-over lock is neither restored nor removed", function()
  local b = Fake.new()
  local a = new_core(b, { focus_lock = true, focus_lock_ttl_ms = 1 })
  local c = new_core(b, { focus_lock = true, focus_lock_ttl_ms = 1 })

  a:focus_enter("set_default")
  settle(a)
  -- lock age has one-second resolution (directory mtime)
  vim.wait(1100, function()
    return false
  end)

  c:focus_enter("set_default") -- A's lock is stale: C takes it over
  settle(c)
  eq(c.state.lock_owned, true, "C took over the lock")

  a:focus_leave("restore_prev")
  settle(a)
  eq(b:current(), "us", "A did not restore over C")
  eq(a.state.lock_owned, false, "A no longer owns the lock")
  eq(uv.fs_stat(lock_dir) ~= nil, true, "C's lock still exists")

  c:focus_leave("restore_prev")
  settle(c)
end)

test("unknown backend name is an error", function()
  local backend, err = plugin._build_backend({ backend = "wayfire" })
  eq(backend, nil, "no backend")
  eq(err, 'lang_autoswitch: unknown backend "wayfire" (available: hyprland, sway)', "error message")
end)

test("inline backend config is merged into backend_config", function()
  local backend = plugin._build_backend({
    backend = { name = "sway", default_layout = "English (US)" },
    backend_config = { device = "kbd" },
    cache_ttl_ms = 500,
  })
  eq(backend.cfg.default_layout, "English (US)", "inline value")
  eq(backend.cfg.device, "kbd", "backend_config value")
  eq(backend.cfg.cache_ttl_ms, 500, "global cache ttl")
end)

test("backend instance is used as is", function()
  local instance = Fake.new({ default_layout = "ru" })
  eq(plugin._build_backend({ backend = instance }), instance, "same instance")
end)

test("hyprland backend defaults to the us layout", function()
  local backend = plugin._build_backend({ backend = "hyprland" })
  eq(backend:get_default_layout(), "us", "default layout")
end)

test("sway backend requires default_layout", function()
  local saved = vim.env.SWAYSOCK
  vim.env.SWAYSOCK = "/tmp/fake-sway.sock"
  local backend = plugin._build_backend({ backend = "sway" })
  local exe = vim.fn.executable
  vim.fn.executable = function()
    return 1
  end
  local ok, msg = backend:is_available()
  vim.fn.executable = exe
  vim.env.SWAYSOCK = saved
  eq(ok, false, "unavailable")
  eq(msg:find("default_layout", 1, true) ~= nil, true, "message mentions default_layout")
end)

print(("\n%d passed, %d failed"):format(passed, failures))
os.exit(failures == 0 and 0 or 1)
