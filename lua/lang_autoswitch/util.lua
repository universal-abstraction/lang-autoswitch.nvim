local uv = vim.uv or vim.loop

local M = {}

-- Monotonic clock in milliseconds.
function M.now_ms()
  if uv and uv.now then
    return uv.now()
  end
  return math.floor(os.time() * 1000)
end

-- Run a command asynchronously and call cb(stdout, nil) on success or
-- cb(nil, err) on failure.
--
-- vim.system invokes on_exit from a libuv callback ("fast" context), where
-- vim.notify and much of the Nvim API fail with E5560. The callback is
-- therefore scheduled onto the main loop.
function M.run_async(cmd, cb)
  local ok, err = pcall(vim.system, cmd, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      local msg = result.stderr
      if not msg or msg == "" then
        msg = ("%s exited with code %d"):format(cmd[1], result.code)
      end
      cb(nil, msg)
      return
    end
    cb(result.stdout, nil)
  end))
  if not ok then
    vim.schedule(function()
      cb(nil, tostring(err))
    end)
  end
end

return M
