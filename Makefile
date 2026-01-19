test:
	@nvim --headless -u NONE --cmd "set rtp+=$(PWD)" \
		+"lua local m=require('lang_autoswitch'); local ok,msg=m._self_check(); if not ok then vim.api.nvim_err_writeln(msg); vim.cmd('cquit') else print(msg) end" \
		+q
