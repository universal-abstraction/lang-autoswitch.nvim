NVIM ?= nvim

.PHONY: test check

# Unit tests with a fake backend; no compositor needed.
test:
	@$(NVIM) -l tests/run.lua

# Check the real environment (needs a running Hyprland or Sway session).
check:
	@$(NVIM) --headless -u NONE --cmd "set rtp+=$(CURDIR)" \
		+"lua local m=require('lang_autoswitch'); local ok,msg=m._self_check(); if not ok then vim.api.nvim_err_writeln(msg); vim.cmd('cquit') else print(msg) end" \
		+q
