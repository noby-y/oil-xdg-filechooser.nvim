local M = {}

M.defaults = {
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

return M
