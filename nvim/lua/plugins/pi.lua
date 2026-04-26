return {
	name = "pi-local-nvim-bridge",
	dir = vim.fn.stdpath("config"),
	lazy = false,
	config = function()
		local uv = vim.uv or vim.loop

		local M = {}

		M.config = {
			socket_path = nil,
			sockets_dir = "/tmp/pi-nvim-sockets",
			latest_socket = "/tmp/pi-nvim-latest.sock",
			request_timeout_ms = 5000,
			keymaps = true,
		}

		local function notify(message, level)
			vim.notify(message, level or vim.log.levels.INFO, { title = "pi" })
		end

		local function fs_stat(path)
			if not path or path == "" then
				return nil
			end
			return uv.fs_stat(path)
		end

		local function read_json(path)
			local ok, lines = pcall(vim.fn.readfile, path)
			if not ok or not lines or not lines[1] then
				return nil
			end

			local parsed_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
			if parsed_ok then
				return decoded
			end
			return nil
		end

		local function relative_file(bufnr)
			local absolute = vim.api.nvim_buf_get_name(bufnr or 0)
			if absolute == "" then
				return nil
			end

			local relative = vim.fn.fnamemodify(absolute, ":.")
			return relative ~= "" and relative or absolute
		end

		local function line_reference(file, start_line, end_line)
			if not file or file == "" then
				return nil
			end

			if end_line and end_line ~= start_line then
				return string.format("%s:L%d-L%d", file, start_line, end_line)
			end

			return string.format("%s:L%d", file, start_line)
		end

		local function longest_backtick_run(text)
			local longest = 0
			for run in tostring(text or ""):gmatch("`+") do
				longest = math.max(longest, #run)
			end
			return longest
		end

		local function fenced_code(ft, text)
			local lang = ft and ft ~= "" and ft or ""
			local fence = string.rep("`", math.max(3, longest_backtick_run(text) + 1))
			return string.format("%s%s\n%s\n%s", fence, lang, text, fence)
		end

		local function delivery_label(delivery)
			if delivery == "steer" then
				return "steered"
			end
			if delivery == "followUp" then
				return "queued as follow-up"
			end
			return "sent"
		end

		local function socket_from_info_path(info_path)
			return info_path:gsub("%.info$", "")
		end

		local function short_time(iso)
			if type(iso) ~= "string" then
				return ""
			end
			local h, m = iso:match("%d+%-%d+%-%d+T(%d+):(%d+):%d+")
			if h and m then
				return string.format("%s:%s", h, m)
			end
			return iso
		end

		function M.get_sessions()
			local pattern = M.config.sockets_dir .. "/*.info"
			local ok, files = pcall(vim.fn.glob, pattern, false, true)
			if not ok or not files then
				return {}
			end

			local sessions = {}
			for _, info_path in ipairs(files) do
				local info = read_json(info_path)
				local socket = socket_from_info_path(info_path)
				local stat = fs_stat(socket)
				if info and stat then
					table.insert(sessions, {
						cwd = info.cwd or "?",
						pid = info.pid or "?",
						started_at = info.startedAt,
						socket = socket,
						mtime = stat.mtime and stat.mtime.sec or 0,
					})
				end
			end

			table.sort(sessions, function(a, b)
				return (a.mtime or 0) > (b.mtime or 0)
			end)

			return sessions
		end

		--- Resolve the Pi bridge socket.
		--- Priority: explicit config path > matching cwd manifest > newest manifest > latest symlink.
		--- @param opts { quiet: boolean }|nil
		--- @return string|nil
		function M.get_socket_path(opts)
			opts = opts or {}

			if M.config.socket_path and M.config.socket_path ~= "" then
				if fs_stat(M.config.socket_path) then
					return M.config.socket_path
				end
				if not opts.quiet then
					notify("Configured Pi socket does not exist: " .. M.config.socket_path, vim.log.levels.WARN)
				end
				return nil
			end

			local cwd = uv.cwd() or vim.fn.getcwd()
			local sessions = M.get_sessions()

			for _, session in ipairs(sessions) do
				if session.cwd == cwd then
					return session.socket
				end
			end

			if sessions[1] then
				return sessions[1].socket
			end

			if fs_stat(M.config.latest_socket) then
				return M.config.latest_socket
			end

			return nil
		end

		--- Send a raw JSON message to the Pi socket.
		--- @param msg table
		--- @param cb fun(err: string|nil, response: table|nil)|nil
		function M.send_raw(msg, cb)
			local socket_path = M.get_socket_path({ quiet = true })
			if not socket_path then
				local err = "No Pi session found. Is Pi running with the pi-nvim extension loaded?"
				notify(err, vim.log.levels.ERROR)
				if cb then
					cb(err, nil)
				end
				return
			end

			local client = uv.new_pipe(false)
			if not client then
				local err = "Failed to create Unix pipe"
				notify(err, vim.log.levels.ERROR)
				if cb then
					cb(err, nil)
				end
				return
			end

			local timer = uv.new_timer()
			local done = false

			local function close_handles()
				if timer and not timer:is_closing() then
					timer:stop()
					timer:close()
				end
				if client and not client:is_closing() then
					pcall(function()
						client:read_stop()
					end)
					client:close()
				end
			end

			local function finish(err, response)
				if done then
					return
				end
				done = true
				close_handles()
				if cb then
					vim.schedule(function()
						cb(err, response)
					end)
				end
			end

			if timer then
				timer:start(M.config.request_timeout_ms, 0, function()
					finish("Timed out waiting for Pi response", nil)
				end)
			end

			client:connect(socket_path, function(connect_err)
				if connect_err then
					finish("Failed to connect to Pi: " .. connect_err, nil)
					return
				end

				client:write(vim.json.encode(msg) .. "\n")

				local buffer = ""
				client:read_start(function(read_err, data)
					if read_err then
						finish(read_err, nil)
						return
					end

					if not data then
						finish("Pi closed the socket before sending a response", nil)
						return
					end

					buffer = buffer .. data
					local newline = buffer:find("\n", 1, true)
					if newline then
						local line = buffer:sub(1, newline - 1)
						local ok, response = pcall(vim.json.decode, line)
						if ok and response then
							finish(nil, response)
						else
							finish("Invalid response from Pi", nil)
						end
					end
				end)
			end)
		end

		local function handle_prompt_response(err, response)
			if err then
				notify(err, vim.log.levels.ERROR)
				return
			end

			if response and response.ok then
				notify("Pi " .. delivery_label(response.delivery), vim.log.levels.INFO)
			else
				notify("Pi error: " .. (response and response.error or "unknown"), vim.log.levels.ERROR)
			end
		end

		function M.list_sessions()
			local sessions = M.get_sessions()
			if #sessions == 0 then
				notify("No Pi sessions found", vim.log.levels.INFO)
				return
			end

			local current = M.get_socket_path({ quiet = true })
			vim.ui.select(sessions, {
				prompt = "Pi sessions:",
				format_item = function(session)
					local marker = current == session.socket and "●" or "○"
					local started = short_time(session.started_at)
					local time_suffix = started ~= "" and (" started " .. started) or ""
					return string.format("%s %s [pid %s%s]", marker, session.cwd, session.pid, time_suffix)
				end,
			}, function(session)
				if not session then
					return
				end

				M.config.socket_path = session.socket
				notify(string.format("Connected to Pi at %s [pid %s]", session.cwd, session.pid), vim.log.levels.INFO)
			end)
		end

		function M.send_prompt(message)
			if not message or vim.fn.trim(message) == "" then
				notify("Nothing to send", vim.log.levels.WARN)
				return
			end

			M.send_raw({ type = "prompt", message = message }, handle_prompt_response)
		end

		local function active_visual_mode()
			local mode = vim.api.nvim_get_mode().mode
			if mode == "v" or mode == "V" or mode == "\22" then
				return mode
			end
			return nil
		end

		local function pos_before_or_equal(a, b)
			if a[2] ~= b[2] then
				return a[2] < b[2]
			end
			return a[3] <= b[3]
		end

		function M.capture_selection()
			local mode = active_visual_mode()
			local start_pos
			local end_pos
			local selection_type

			if mode then
				-- While a visual-mode mapping is running, '< and '> may still refer to
				-- the previous selection. Use the live visual anchor/current cursor.
				start_pos = vim.fn.getpos("v")
				end_pos = vim.fn.getpos(".")
				selection_type = mode
			else
				start_pos = vim.fn.getpos("'<")
				end_pos = vim.fn.getpos("'>")
				selection_type = vim.fn.visualmode()
				if selection_type == "" then
					selection_type = "v"
				end
			end

			if start_pos[2] == 0 and end_pos[2] == 0 then
				return nil
			end

			if not pos_before_or_equal(start_pos, end_pos) then
				start_pos, end_pos = end_pos, start_pos
			end

			local ok, lines = pcall(vim.fn.getregion, start_pos, end_pos, { type = selection_type })
			if not ok or not lines or #lines == 0 then
				return nil
			end

			local text = table.concat(lines, "\n")
			if text == "" then
				return nil
			end

			return {
				text = text,
				file = relative_file(0),
				start_line = start_pos[2],
				end_line = end_pos[2],
				ft = vim.bo.filetype,
			}
		end

		local function this_target(selection, file, line)
			if selection then
				local ref = line_reference(selection.file, selection.start_line, selection.end_line)
				if not ref then
					return nil
				end
				return string.format("%s\n\n%s", fenced_code(selection.ft, selection.text), ref)
			end

			return line_reference(file, line)
		end

		local function expand_this_target(prompt_text, selection, file, line)
			if not prompt_text:find("@this", 1, true) then
				return prompt_text, nil
			end

			local target = this_target(selection, file, line)
			if not target then
				return nil, "@this requires a file-backed buffer"
			end

			-- Keep the sentence readable while appending the heavy context safely.
			-- Example: "why does @this fail?" -> "why does this fail?"
			local readable_prompt = prompt_text:gsub("@this", "this")
			readable_prompt = readable_prompt:gsub("[ \t]+\n", "\n"):gsub("\n[ \t]+", "\n"):gsub("[ \t][ \t]+", " ")
			readable_prompt = vim.fn.trim(readable_prompt)

			if readable_prompt == "" then
				return string.format("Context:\n%s", target), nil
			end

			return string.format("%s\n\nContext:\n%s", readable_prompt, target), nil
		end

		function M.ask(opts)
			opts = opts or {}
			local selection = opts.selection
			local source_buf = vim.api.nvim_get_current_buf()
			local source_file = relative_file(source_buf)
			local source_line = vim.api.nvim_win_get_cursor(0)[1]

			local width = math.min(72, math.floor(vim.o.columns * 0.55))
			local max_input_height = 6
			local top_row = math.floor((vim.o.lines - (max_input_height + 2)) / 2)
			local col = math.floor((vim.o.columns - width - 2) / 2)

			local accent_hl = vim.api.nvim_get_hl(0, { name = "Function", link = false })
			local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
			vim.api.nvim_set_hl(0, "PiNvimBorder", { fg = accent_hl.fg, bg = normal_hl.bg })
			vim.api.nvim_set_hl(0, "PiNvimTitle", { fg = accent_hl.fg, bg = normal_hl.bg })

			local input_buf = vim.api.nvim_create_buf(false, true)
			vim.bo[input_buf].buftype = "nofile"
			vim.bo[input_buf].filetype = "pi-nvim-prompt"
			vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

			local previous_completeopt = vim.o.completeopt
			vim.o.completeopt = "menuone,noinsert,noselect"

			local input_win = vim.api.nvim_open_win(input_buf, true, {
				relative = "editor",
				width = width,
				height = 1,
				row = top_row,
				col = col,
				style = "minimal",
				border = "rounded",
				title = " pi prompt ",
				title_pos = "center",
				zindex = 50,
				noautocmd = true,
			})
			vim.wo[input_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"
			vim.wo[input_win].wrap = true

			local function resize_input()
				if not vim.api.nvim_win_is_valid(input_win) then
					return
				end

				local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
				local visual_rows = 0
				for _, line in ipairs(lines) do
					visual_rows = visual_rows + math.max(1, math.ceil(math.max(1, #line) / width))
				end

				local new_height = math.max(1, math.min(max_input_height, visual_rows))
				vim.api.nvim_win_set_height(input_win, new_height)
				local cursor_line = vim.api.nvim_win_get_cursor(input_win)[1]
				vim.api.nvim_win_call(input_win, function()
					vim.fn.winrestview({ topline = math.max(1, cursor_line - new_height + 1) })
				end)
			end

			local selection_ns = nil
			if selection and vim.api.nvim_buf_is_valid(source_buf) then
				selection_ns = vim.api.nvim_create_namespace("pi_nvim_selection")
				for lnum = selection.start_line, selection.end_line do
					vim.api.nvim_buf_add_highlight(source_buf, selection_ns, "Visual", lnum - 1, 0, -1)
				end
			end

			local closed = false
			local function close()
				if closed then
					return
				end
				closed = true
				vim.o.completeopt = previous_completeopt
				pcall(vim.cmd, "noautocmd stopinsert")
				if selection_ns and vim.api.nvim_buf_is_valid(source_buf) then
					vim.api.nvim_buf_clear_namespace(source_buf, selection_ns, 0, -1)
				end
				pcall(vim.api.nvim_win_close, input_win, true)
				pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
			end

			local function send()
				local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
				local prompt_text = vim.fn.trim(table.concat(lines, "\n"))
				local message, expand_error = expand_this_target(prompt_text, selection, source_file, source_line)
				close()

				if expand_error then
					notify(expand_error, vim.log.levels.WARN)
					return
				end

				M.send_prompt(message)
			end

			local function feedkeys(keys)
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
			end

			local function target_completion_items()
				return {
					{
						word = "@this",
						abbr = "@this",
						menu = selection and "current visual selection" or "current line",
						info = selection and "Selected text, then cwd-relative file and line range" or "Cwd-relative file and current line",
					},
				}
			end

			local function complete_target()
				if closed or not vim.api.nvim_win_is_valid(input_win) or not vim.api.nvim_buf_is_valid(input_buf) then
					return
				end

				vim.api.nvim_win_call(input_win, function()
					vim.api.nvim_put({ "@" }, "c", true, true)
					resize_input()
					local start_col = math.max(1, vim.fn.col(".") - 1)
					pcall(vim.fn.complete, start_col, target_completion_items())
				end)
			end

			local function confirm_completion_or_send()
				if vim.fn.pumvisible() == 1 then
					local complete_info = vim.fn.complete_info({ "selected" })
					feedkeys(complete_info.selected == -1 and "<C-n><C-y>" or "<C-y>")
					return
				end
				send()
			end

			local function cancel_completion_or_close()
				if vim.fn.pumvisible() == 1 then
					feedkeys("<C-e>")
					return
				end
				close()
			end

			local key_opts = { buffer = input_buf, noremap = true, silent = true }
			vim.keymap.set("i", "<CR>", confirm_completion_or_send, key_opts)
			vim.keymap.set("i", "@", complete_target, key_opts)
			vim.keymap.set("i", "<Esc>", cancel_completion_or_close, key_opts)
			vim.keymap.set("n", "<Esc>", close, key_opts)
			vim.keymap.set({ "i", "n" }, "<C-c>", close, key_opts)

			vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
				buffer = input_buf,
				callback = resize_input,
			})
			vim.api.nvim_create_autocmd("BufLeave", {
				buffer = input_buf,
				callback = function()
					vim.schedule(close)
				end,
			})

			vim.cmd("noautocmd startinsert!")
		end

		function M.send_all()
			local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
			local content = table.concat(lines, "\n")
			if vim.fn.trim(content) == "" then
				notify("Current buffer is empty", vim.log.levels.WARN)
				return
			end

			local file = relative_file(0) or "(unnamed buffer)"
			local message = string.format("Buffer: %s\n\n%s", file, fenced_code(vim.bo.filetype, content))
			M.send_prompt(message)
		end

		function M.setup(opts)
			M.config = vim.tbl_deep_extend("force", M.config, opts or {})

			vim.api.nvim_create_user_command("Pi", function(args)
				local selection = nil
				if args.range == 2 then
					selection = M.capture_selection()
				end
				M.ask({ selection = selection })
			end, { range = true, desc = "Ask Pi (@this = current line/selection)" })

			vim.api.nvim_create_user_command("PiSendAll", function()
				M.send_all()
			end, { desc = "Send current buffer to Pi" })

			vim.api.nvim_create_user_command("PiSessions", function()
				M.list_sessions()
			end, { desc = "Pick a Pi session" })

			if M.config.keymaps then
				vim.keymap.set("n", "<leader>aa", function()
					M.ask()
				end, { desc = "Ask Pi (@this = current line)" })
				vim.keymap.set("x", "<leader>aa", function()
					M.ask({ selection = M.capture_selection() })
				end, { desc = "Ask Pi (@this = selection)" })
				vim.keymap.set("n", "<leader>ab", function()
					M.send_all()
				end, { desc = "Send all to Pi" })
				vim.keymap.set("n", "<leader>ap", function()
					M.list_sessions()
				end, { desc = "Pick Pi session" })
			end
		end

		package.loaded["pi"] = M
		package.loaded["pi_nvim"] = M
		package.loaded["pi-nvim"] = M

		M.setup()
	end,
}
