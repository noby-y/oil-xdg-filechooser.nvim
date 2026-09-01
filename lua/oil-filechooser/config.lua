local M = {}

--- Terminals the daemon knows how to launch, best first. `{class}` is replaced
--- with `opts.class`: the dialog needs a window class of its own so a window
--- rule can float it without floating every other terminal.
local TERMINALS = {
	kitty = { 'kitty', '--class', '{class}', '-e' },
	ghostty = { 'ghostty', '--class={class}', '-e' },
	wezterm = { 'wezterm', 'start', '--class', '{class}', '--' },
	foot = { 'foot', '--app-id={class}', '-e' },
	alacritty = { 'alacritty', '--class', '{class}', '-e' },
	['xterm'] = { 'xterm', '-class', '{class}', '-e' },
}

M.defaults = {
	--- Window class of the dialog. Also what a WM float rule matches on.
	class = 'oil-filechooser',
	--- Full argv the daemon prefixes to `editor`, or nil to pick the first
	--- entry of `terminal_priority` that is actually installed.
	terminal = nil,
	terminal_priority = { 'kitty', 'ghostty', 'wezterm', 'foot', 'alacritty', 'xterm' },
	--- The editor argv itself. Anything here runs with $OIL_FILECHOOSER_REQUEST set.
	editor = { 'nvim' },

	keymaps = {
		--- Return the entry under the cursor (or every marked entry).
		accept = '<CR>',
		--- Return the directory you are standing in. For a save request, ask
		--- for a filename in it first.
		accept_dir = '<C-y>',
		--- Add the entry under the cursor to the selection. Multi-select
		--- requests only; it is the only way to pick files from two directories.
		toggle_mark = '<Tab>',
		--- Answer "user cancelled" and quit.
		cancel = 'q',
	},

	--- Show what the application asked for + keymap hints above the oil window.
	winbar = true,
	--- Ask before returning a file that matches none of the request's filters.
	--- The application is free to reject it, usually silently.
	confirm_filter_mismatch = true,

	--- Register the portal backend on startup whenever the files on disk do not
	--- match these options. This is what makes adding the plugin the whole
	--- installation; there is nothing to run by hand.
	auto_install = true,
	--- Also point ~/.config/xdg-desktop-portal/*.conf at this backend. Without
	--- it the backend is installed but the portal keeps using GTK.
	manage_portal_preference = true,
}

--- @type table
M.options = vim.deepcopy(M.defaults)

--- @param opts table|nil
--- @return table
function M.setup(opts)
	M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
	return M.options
end

--- The argv the daemon runs, terminal first. nil when no known terminal is
--- installed and none was configured.
--- @param opts table
--- @return string[]|nil
function M.terminal_argv(opts)
	local argv = opts.terminal
	if not argv then
		for _, name in ipairs(opts.terminal_priority) do
			if TERMINALS[name] and vim.fn.executable(name) == 1 then
				argv = TERMINALS[name]
				break
			end
		end
	end
	if not argv then
		return nil
	end

	return vim.tbl_map(function(arg)
		return (arg:gsub('{class}', opts.class))
	end, argv)
end

return M
