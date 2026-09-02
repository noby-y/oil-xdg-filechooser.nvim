--- The dialog itself: an oil buffer with a few extra keymaps.
---
--- Everything here is scoped to a portal session. In an ordinary Neovim none of
--- it is ever installed, so oil behaves exactly as configured.

local request_mod = require('oil-filechooser.request')

local M = {}

local ns = vim.api.nvim_create_namespace('oil-filechooser')

--- @type {request: OilFileChooserRequest, opts: table, marks: string[], marked: table<string, boolean>}|nil
local state = nil

--- @param path string
--- @return boolean
local function is_marked(path)
	return state ~= nil and state.marked[path] == true
end

-- NOTE: Filters

local glob_cache = {}

--- @param pattern string
--- @param name string
--- @return boolean
local function glob_matches(pattern, name)
	local regex = glob_cache[pattern]
	if regex == nil then
		local ok, compiled = pcall(vim.regex, vim.fn.glob2regpat(pattern))
		regex = ok and compiled or false
		glob_cache[pattern] = regex
	end
	if not regex then
		return false
	end
	-- Filters routinely spell only one case (`*.PNG` next to `*.png`), and no
	-- application means the lowercase file to be excluded.
	return regex:match_str(name) ~= nil or regex:match_str(name:lower()) ~= nil
end

--- Whether `path` satisfies at least one of the request's filters. Filters made
--- purely of mimetypes are treated as satisfied: matching them properly means
--- sniffing content, and refusing everything would be worse than allowing it.
--- @param path string
--- @return boolean
local function matches_filters(path)
	local filters = state.request.options.filters
	if type(filters) ~= 'table' or #filters == 0 then
		return true
	end

	local name = vim.fs.basename(path)
	local saw_glob = false
	for _, filter in ipairs(filters) do
		for _, glob in ipairs(filter.globs or {}) do
			if glob.kind == 0 and type(glob.pattern) == 'string' then
				saw_glob = true
				if glob_matches(glob.pattern, name) then
					return true
				end
			end
		end
	end
	return not saw_glob
end

--- @return string
local function filter_summary()
	local patterns = {}
	for _, filter in ipairs(state.request.options.filters or {}) do
		for _, glob in ipairs(filter.globs or {}) do
			if type(glob.pattern) == 'string' then
				table.insert(patterns, glob.pattern)
			end
		end
	end
	return table.concat(patterns, ' ')
end

-- NOTE: Answering

--- @param paths string[]
local function accept(paths)
	paths = vim.tbl_filter(function(path)
		return path and path ~= ''
	end, paths)
	if #paths == 0 then
		return
	end

	if state.opts.confirm_filter_mismatch and state.request.method == 'OpenFile' then
		local rejected = vim.tbl_filter(function(path)
			return not matches_filters(path)
		end, paths)
		if #rejected > 0 then
			local prompt = string.format(
				'%s matches none of the requested filters (%s).\nReturn it anyway?',
				table.concat(vim.tbl_map(vim.fs.basename, rejected), ', '),
				filter_summary()
			)
			if vim.fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then
				return
			end
		end
	end

	if state.opts.confirm_overwrite and state.request.method ~= 'OpenFile' then
		local existing = vim.tbl_filter(function(path)
			return vim.uv.fs_stat(path) ~= nil
		end, paths)
		if #existing > 0 then
			local prompt = string.format(
				'%s already %s.\nOverwrite?',
				table.concat(vim.tbl_map(vim.fs.basename, existing), ', '),
				#existing == 1 and 'exists' or 'exist'
			)
			if vim.fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then
				return
			end
		end
	end

	request_mod.respond(state.request, paths)
end

--- SaveFiles asks for a directory and supplies the names to create in it.
--- @param dir string
local function accept_save_files(dir)
	local names = state.request.options.files
	if type(names) ~= 'table' or #names == 0 then
		return accept({ dir })
	end
	accept(vim.tbl_map(function(name)
		return vim.fs.joinpath(dir, vim.fs.basename(name))
	end, names))
end

--- @param dir string
local function prompt_save_name(dir)
	vim.ui.input({
		prompt = 'Save as: ',
		default = state.request.options.current_name or '',
		completion = 'file',
	}, function(name)
		if name and name ~= '' then
			accept({ vim.fs.joinpath(dir, name) })
		end
	end)
end

-- -- Oil buffer helpers --------------------------------------------------------

--- @param bufnr integer
--- @param lnum integer
--- @return string|nil path, boolean is_dir
local function entry_at(bufnr, lnum)
	local oil = require('oil')
	local dir = oil.get_current_dir(bufnr)
	local entry = dir and oil.get_entry_on_line(bufnr, lnum)
	if not dir or not entry then
		return nil, false
	end
	local path = vim.fs.joinpath(dir, entry.name)
	local is_dir = entry.type == 'directory'
		or (entry.type == 'link' and vim.fn.isdirectory(path) == 1)
	return path, is_dir
end

--- @param bufnr integer
local function render_marks(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	if #state.marks == 0 then
		return
	end
	for lnum = 1, vim.api.nvim_buf_line_count(bufnr) do
		local path = entry_at(bufnr, lnum)
		if path and is_marked(path) then
			vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
				line_hl_group = 'OilFileChooserMark',
			})
		end
	end
end

--- @param bufnr integer
local function toggle_mark(bufnr)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local path, is_dir = entry_at(bufnr, lnum)
	-- Marking a directory would answer a request for files with a folder.
	if not path or is_dir then
		return
	end

	if is_marked(path) then
		state.marked[path] = nil
		state.marks = vim.tbl_filter(function(marked)
			return marked ~= path
		end, state.marks)
	else
		state.marked[path] = true
		table.insert(state.marks, path)
	end

	render_marks(bufnr)
	vim.cmd('redrawstatus')
	if lnum < vim.api.nvim_buf_line_count(bufnr) then
		vim.api.nvim_win_set_cursor(0, { lnum + 1, 0 })
	end
end

--- Regular files between two lines, directories skipped.
--- @param bufnr integer
--- @param first integer
--- @param last integer
--- @return string[]
local function files_in_range(bufnr, first, last)
	local files = {}
	for lnum = first, last do
		local path, is_dir = entry_at(bufnr, lnum)
		if path and not is_dir then
			table.insert(files, path)
		end
	end
	return files
end

-- NOTE: Winbar

local ACTIONS = {
	OpenFile = 'Open',
	SaveFile = 'Save',
	SaveFiles = 'Save into',
}

--- Rendered through the global winbar, so it follows the oil buffer around and
--- disappears the moment something else is on screen.
--- @return string
function M.winbar()
	if not state or vim.bo.filetype ~= 'oil' then
		return ''
	end

	local keys = state.opts.keymaps
	local request = state.request
	local parts = { '%#OilFileChooserTitle# ' .. (ACTIONS[request.method] or 'Pick') }
	if request_mod.wants_directory(request) then
		table.insert(parts, 'directory')
	elseif request_mod.wants_multiple(request) then
		table.insert(parts, 'files')
	else
		table.insert(parts, 'file')
	end
	if request.app_id and request.app_id ~= '' then
		table.insert(parts, 'for ' .. request.app_id)
	end
	table.insert(parts, '%#OilFileChooserHint# ')

	local hints = {}
	if request_mod.wants_directory(request) then
		table.insert(hints, keys.accept_dir .. ' this directory')
	elseif request.method == 'SaveFile' then
		table.insert(hints, keys.accept .. ' overwrite')
		table.insert(hints, keys.accept_dir .. ' new name here')
	elseif request_mod.wants_multiple(request) then
		table.insert(hints, keys.accept .. ' choose')
		table.insert(hints, string.format('%s mark (%d)', keys.toggle_mark, #state.marks))
	else
		table.insert(hints, keys.accept .. ' choose')
	end
	table.insert(hints, keys.cancel .. ' cancel')

	local summary = filter_summary()
	if summary ~= '' then
		table.insert(hints, 1, summary)
	end

	return table.concat(parts, ' ') .. ' ' .. table.concat(hints, '  ') .. '%*'
end

-- NOTE: Keymaps

--- @param bufnr integer
local function map_buffer(bufnr)
	local oil = require('oil')
	local keys = state.opts.keymaps
	local request = state.request

	local function map(mode, lhs, rhs, desc)
		if lhs and lhs ~= '' then
			vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, nowait = true, desc = 'filechooser: ' .. desc })
		end
	end

	map('n', keys.cancel, function()
		request_mod.cancel(request)
	end, 'cancel the dialog')

	if request_mod.wants_directory(request) then
		-- The answer is the directory you are standing in, so <CR> keeps its
		-- usual job of descending into things.
		map('n', keys.accept_dir, function()
			local dir = oil.get_current_dir(bufnr)
			if not dir then
				return
			end
			if request.method == 'SaveFiles' then
				accept_save_files(dir)
			else
				accept({ dir })
			end
		end, 'return this directory')
		return
	end

	if request.method == 'SaveFile' then
		map('n', keys.accept_dir, function()
			local dir = oil.get_current_dir(bufnr)
			if dir then
				prompt_save_name(dir)
			end
		end, 'save into this directory')
	end

	local multiple = request_mod.wants_multiple(request)

	map('n', keys.accept, function()
		local lnum = vim.api.nvim_win_get_cursor(0)[1]
		local path, is_dir = entry_at(bufnr, lnum)
		if not path or is_dir then
			return oil.select()
		end
		if multiple and #state.marks > 0 then
			return accept(vim.deepcopy(state.marks))
		end
		accept({ path })
	end, 'return the entry under the cursor')

	if multiple then
		map('n', keys.toggle_mark, function()
			toggle_mark(bufnr)
		end, 'mark the entry under the cursor')

		map('n', keys.accept_dir, function()
			accept(vim.deepcopy(state.marks))
		end, 'return the marked entries')

		map('x', keys.accept, function()
			-- Readable while still in visual mode, unlike the '< '> marks.
			local a, b = vim.fn.line('v'), vim.api.nvim_win_get_cursor(0)[1]
			local files = files_in_range(bufnr, math.min(a, b), math.max(a, b))
			vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'n', false)
			accept(files)
		end, 'return the selected entries')
	end
end

-- NOTE: Entry point

--- @param request OilFileChooserRequest
--- @param opts table
function M.start(request, opts)
	state = { request = request, opts = opts, marks = {}, marked = {} }

	vim.api.nvim_set_hl(0, 'OilFileChooserTitle', { link = 'Title', default = true })
	vim.api.nvim_set_hl(0, 'OilFileChooserHint', { link = 'Comment', default = true })
	vim.api.nvim_set_hl(0, 'OilFileChooserMark', { link = 'Visual', default = true })

	local group = vim.api.nvim_create_augroup('oil-filechooser', { clear = true })

	-- canola sets `filetype = 'oil'` and installs its own buffer keymaps
	-- immediately after, so a mapping made synchronously here would be
	-- overwritten. Re-applying on every render is cheap and survives whatever
	-- order those two end up in.
	vim.api.nvim_create_autocmd('FileType', {
		group = group,
		pattern = 'oil',
		callback = function(ev)
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(ev.buf) then
					map_buffer(ev.buf)
				end
			end)
		end,
	})
	vim.api.nvim_create_autocmd('User', {
		group = group,
		pattern = { 'OilEnter', 'OilReadPost' },
		callback = function(ev)
			local bufnr = ev.data and ev.data.buf
			if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
				map_buffer(bufnr)
				render_marks(bufnr)
			end
		end,
	})

	if opts.winbar then
		vim.o.winbar = "%{%v:lua.require'oil-filechooser.ui'.winbar()%}"
	end

	vim.api.nvim_create_user_command('OilFileChooserCancel', function()
		request_mod.cancel(request)
	end, { desc = 'filechooser: answer "cancelled" and quit' })

	local function open_oil()
		vim.schedule(function()
			require('oil').open(request_mod.start_dir(request))
		end)
	end

	-- Normally this runs during startup, well before VimEnter. Reloading the
	-- plugin by hand is the case where that is no longer true.
	if vim.v.vim_did_enter == 1 then
		open_oil()
	else
		vim.api.nvim_create_autocmd('VimEnter', { group = group, once = true, callback = open_oil })
	end
end

return M
