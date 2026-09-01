--- Two jobs, and which one runs is decided by $OIL_FILECHOOSER_REQUEST:
---
--- * In a Neovim the portal daemon started, this is the dialog: open oil and
---   answer the pending request (see `ui.lua`).
--- * In an ordinary Neovim, this keeps the backend registered with
---   xdg-desktop-portal (see `install.lua`), so adding the plugin is the entire
---   installation.

local M = {}

--- @param opts table|nil
function M.setup(opts)
	local options = require('oil-filechooser.config').setup(opts)

	local request_mod = require('oil-filechooser.request')
	if request_mod.pending() then
		-- Inside a dialog. Registration is deliberately not touched here: the
		-- daemon we would be restarting is the one blocked on this process.
		-- That holds even when the request turns out to be unreadable, which
		-- leaves an ordinary Neovim and a dialog the user can only cancel.
		local request = request_mod.read()
		if request then
			require('oil-filechooser.ui').start(request, options)
		end
		return
	end

	vim.api.nvim_create_user_command('OilFileChooser', function(cmd)
		local install = require('oil-filechooser.install')
		local action = cmd.args ~= '' and cmd.args or 'status'
		if action == 'status' then
			vim.notify(install.status(options), vim.log.levels.INFO)
		elseif action == 'install' then
			install.sync(options, function(changed, errors)
				M.report(changed, errors, true)
			end)
		elseif action == 'uninstall' then
			install.uninstall(options, function(errors)
				if #errors > 0 then
					vim.notify('oil-filechooser: ' .. table.concat(errors, '\n'), vim.log.levels.ERROR)
				else
					vim.notify('oil-filechooser: unregistered; the portal falls back to GTK', vim.log.levels.INFO)
				end
			end)
		else
			vim.notify('oil-filechooser: unknown action ' .. action, vim.log.levels.ERROR)
		end
	end, {
		nargs = '?',
		desc = 'oil-filechooser: register the portal backend / show its state',
		complete = function()
			return { 'status', 'install', 'uninstall' }
		end,
	})

	if options.auto_install then
		-- Off the startup path: a handful of small reads, and nothing at all to
		-- do once the files on disk match the options.
		vim.defer_fn(function()
			require('oil-filechooser.install').sync(options, function(changed, errors)
				M.report(changed, errors, false)
			end)
		end, 500)
	end
end

--- @param changed string[]
--- @param errors string[]
--- @param verbose boolean
function M.report(changed, errors, verbose)
	if #errors > 0 then
		vim.notify('oil-filechooser:\n  ' .. table.concat(errors, '\n  '), vim.log.levels.ERROR)
	elseif #changed > 0 then
		vim.notify(
			string.format('oil-filechooser: registered portal backend (%d file(s) written)', #changed),
			vim.log.levels.INFO
		)
	elseif verbose then
		vim.notify('oil-filechooser: already up to date', vim.log.levels.INFO)
	end
end

--- Entry point for a plugin manager's build step. The startup sync would get
--- there on its own; this just means a fresh install is live immediately.
function M.install()
	require('oil-filechooser.install').sync(require('oil-filechooser.config').options)
end

return M
