--- Registering the backend with xdg-desktop-portal, from inside Neovim.
---
--- Every file this writes lives under $HOME: xdg-desktop-portal scans
--- $XDG_DATA_HOME for `.portal` files, so nothing here needs root and the whole
--- installation is "the plugin is on the runtimepath".
---
--- Writing is idempotent and content-addressed -- `check()` compares what is on
--- disk with what the current options imply, and `sync()` only touches the
--- files that differ. That is what lets it run on every startup.

local M = {}

local APP = 'oil-filechooser'
local BUS_NAME = 'org.freedesktop.impl.portal.desktop.' .. APP
local UNIT = APP .. '.service'
local KEY = 'org.freedesktop.impl.portal.FileChooser'

-- -- Small filesystem helpers ---------------------------------------------------

--- @param path string
--- @return string|nil
local function read_file(path)
	local fd = io.open(path, 'r')
	if not fd then
		return nil
	end
	local content = fd:read('*a')
	fd:close()
	return content
end

--- @param path string
--- @param content string
--- @return string|nil err
local function write_file(path, content)
	vim.fn.mkdir(vim.fs.dirname(path), 'p')
	local fd, err = io.open(path, 'w')
	if not fd then
		return err or ('cannot write ' .. path)
	end
	fd:write(content)
	fd:close()
	return nil
end

--- @param name string
--- @param fallback string
--- @return string
local function xdg_dir(name, fallback)
	local value = vim.env[name]
	if value and value ~= '' then
		return value
	end
	return vim.fs.joinpath(vim.env.HOME, fallback)
end

--- @return string[]
local function desktops()
	local list = {}
	for _, name in ipairs(vim.split(vim.env.XDG_CURRENT_DESKTOP or '', ':', { trimempty = true })) do
		table.insert(list, name:lower())
	end
	return list
end

--- The plugin's own directory, derived from this file rather than configured:
--- the daemon is started by systemd and has to be told where its script is.
--- @return string
function M.root()
	local source = debug.getinfo(1, 'S').source:sub(2)
	return vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))))
end

--- @return string
local function daemon_command()
	local python = vim.fn.exepath('python3')
	if python == '' then
		python = '/usr/bin/python3'
	end
	return python .. ' ' .. vim.fs.joinpath(M.root(), 'daemon', 'portal.py')
end

-- -- Generated file contents ----------------------------------------------------

--- @return table<string, string>
function M.paths()
	local config_home = xdg_dir('XDG_CONFIG_HOME', '.config')
	local data_home = xdg_dir('XDG_DATA_HOME', '.local/share')
	return {
		portal = vim.fs.joinpath(data_home, 'xdg-desktop-portal', 'portals', APP .. '.portal'),
		dbus = vim.fs.joinpath(data_home, 'dbus-1', 'services', BUS_NAME .. '.service'),
		unit = vim.fs.joinpath(config_home, 'systemd', 'user', UNIT),
		wants = vim.fs.joinpath(config_home, 'systemd', 'user', 'xdg-desktop-portal.service.wants', UNIT),
		portal_dir = vim.fs.joinpath(config_home, 'xdg-desktop-portal'),
	}
end

--- `default=` from a system portals.conf, so a generated preference file keeps
--- the desktop's own backends. Dropping `default=hyprland;gtk` would leave
--- screencast without its Hyprland backend.
--- @param basename string
--- @return string|nil
local function system_default(basename)
	local content = read_file(vim.fs.joinpath('/usr/share/xdg-desktop-portal', basename))
	if not content then
		return nil
	end
	return content:match('\n%s*default%s*=%s*([^\n]+)') or content:match('^%s*default%s*=%s*([^\n]+)')
end

--- Sets (or clears) our backend in the `[preferred]` section, leaving every
--- other line of the file exactly as it was.
--- @param basename string
--- @param backend string|nil  nil removes the key
--- @return string|nil content  nil when there is nothing to write
local function preference_content(basename, backend)
	local paths = M.paths()
	local path = vim.fs.joinpath(paths.portal_dir, basename)
	local existing = read_file(path)

	if not existing then
		if not backend then
			return nil
		end
		return table.concat({
			'# Written by the ' .. APP .. ' Neovim plugin.',
			'# `default` is copied from /usr/share/xdg-desktop-portal/' .. basename .. ' --',
			'# this file outranks that one, and dropping the line would take the',
			'# desktop\'s own backends (screencast above all) with it.',
			'[preferred]',
			'default=' .. (system_default(basename) or 'gtk'),
			KEY .. '=' .. backend,
			'',
		}, '\n')
	end

	local lines = vim.split(existing:gsub('\n$', ''), '\n')
	local section, header, replaced = nil, nil, false
	local out = {}
	for _, line in ipairs(lines) do
		local name = line:match('^%s*%[(.-)%]%s*$')
		if name then
			section = name
			if name == 'preferred' then
				header = #out + 1
			end
		end
		if section == 'preferred' and line:match('^%s*' .. vim.pesc(KEY) .. '%s*=') then
			replaced = true
			if backend then
				table.insert(out, KEY .. '=' .. backend)
			end
		else
			table.insert(out, line)
		end
	end

	if not replaced and backend then
		if header then
			table.insert(out, header + 1, KEY .. '=' .. backend)
		else
			vim.list_extend(out, { '', '[preferred]', KEY .. '=' .. backend })
		end
	end

	return table.concat(out, '\n') .. '\n'
end

--- Every file the installation consists of, path -> exact content.
--- @param opts table
--- @return table<string, string>
function M.desired(opts)
	local paths = M.paths()
	local files = {}
	local use_in = table.concat(desktops(), ';')

	files[paths.portal] = table.concat({
		'[portal]',
		'DBusName=' .. BUS_NAME,
		'Interfaces=org.freedesktop.impl.portal.FileChooser',
		use_in ~= '' and ('UseIn=' .. use_in) or nil,
		'',
	}, '\n')

	files[paths.dbus] = table.concat({
		'[D-BUS Service]',
		'Name=' .. BUS_NAME,
		'Exec=' .. daemon_command(),
		'SystemdService=' .. UNIT,
		'',
	}, '\n')

	files[paths.unit] = table.concat({
		'[Unit]',
		'Description=Neovim + oil as the XDG FileChooser portal backend',
		'PartOf=graphical-session.target',
		'After=graphical-session.target',
		'',
		'[Service]',
		'Type=dbus',
		'BusName=' .. BUS_NAME,
		'ExecStart=' .. daemon_command(),
		'Slice=session.slice',
		'',
		'[Install]',
		'WantedBy=xdg-desktop-portal.service',
		'',
	}, '\n')

	if opts.manage_portal_preference then
		-- A desktop-specific file outranks the generic one, so the generic file
		-- alone would leave XDG_CURRENT_DESKTOP=Hyprland on GTK.
		local names = { 'portals.conf' }
		for _, desktop in ipairs(desktops()) do
			table.insert(names, desktop .. '-portals.conf')
		end
		for _, basename in ipairs(names) do
			local content = preference_content(basename, APP)
			if content then
				files[vim.fs.joinpath(paths.portal_dir, basename)] = content
			end
		end
	end

	return files
end

-- -- Inspecting and applying -----------------------------------------------------

--- @param opts table
--- @return {stale: string[], enabled: boolean, preference_stale: boolean}
function M.check(opts)
	local files = M.desired(opts)
	local paths = M.paths()
	local stale, preference_stale = {}, false
	for path, content in pairs(files) do
		if read_file(path) ~= content then
			table.insert(stale, path)
			if vim.startswith(path, paths.portal_dir) then
				preference_stale = true
			end
		end
	end
	table.sort(stale)

	-- `WantedBy=xdg-desktop-portal.service` means enabling leaves this symlink
	-- behind, which is cheaper to look at than asking systemctl.
	local enabled = vim.uv.fs_lstat(paths.wants) ~= nil
	return { stale = stale, enabled = enabled, preference_stale = preference_stale }
end

--- @param commands string[][]
--- @param cb fun(errors: string[])
local function run_all(commands, cb)
	local errors = {}
	local index = 0
	local function step()
		index = index + 1
		local cmd = commands[index]
		if not cmd then
			return cb(errors)
		end
		vim.system(cmd, { text = true }, function(result)
			if result.code ~= 0 then
				table.insert(errors, table.concat(cmd, ' ') .. ': ' .. vim.trim(result.stderr or ''))
			end
			step()
		end)
	end
	step()
end

--- Writes whatever differs and tells systemd about it.
--- @param opts table
--- @param cb nil|fun(changed: string[], errors: string[])
function M.sync(opts, cb)
	cb = cb or function() end
	local status = M.check(opts)
	if #status.stale == 0 and status.enabled then
		return cb({}, {})
	end

	local files = M.desired(opts)
	local errors, changed = {}, {}
	for _, path in ipairs(status.stale) do
		local err = write_file(path, files[path])
		if err then
			table.insert(errors, err)
		else
			table.insert(changed, path)
		end
	end

	local commands = {
		{ 'systemctl', '--user', 'daemon-reload' },
		{ 'systemctl', '--user', 'enable', '--now', UNIT },
		-- Picks up a changed ExecStart without disturbing an idle backend.
		{ 'systemctl', '--user', 'try-restart', UNIT },
	}
	if status.preference_stale or not status.enabled then
		-- The portal only reads its preference files at startup.
		table.insert(commands, { 'systemctl', '--user', 'restart', 'xdg-desktop-portal.service' })
	end

	run_all(commands, function(command_errors)
		vim.list_extend(errors, command_errors)
		cb(changed, errors)
	end)
end

--- @param opts table
--- @param cb nil|fun(errors: string[])
function M.uninstall(opts, cb)
	cb = cb or function() end
	local paths = M.paths()

	run_all({ { 'systemctl', '--user', 'disable', '--now', UNIT } }, function(errors)
		for _, path in ipairs({ paths.portal, paths.dbus, paths.unit }) do
			os.remove(path)
		end
		if opts.manage_portal_preference then
			local names = { 'portals.conf' }
			for _, desktop in ipairs(desktops()) do
				table.insert(names, desktop .. '-portals.conf')
			end
			for _, basename in ipairs(names) do
				local content = preference_content(basename, nil)
				if content then
					write_file(vim.fs.joinpath(paths.portal_dir, basename), content)
				end
			end
		end
		run_all({
			{ 'systemctl', '--user', 'daemon-reload' },
			{ 'systemctl', '--user', 'restart', 'xdg-desktop-portal.service' },
		}, function(more)
			vim.list_extend(errors, more)
			cb(errors)
		end)
	end)
end

--- @param opts table
--- @return string
function M.status(opts)
	local status = M.check(opts)
	local lines = {
		'oil-filechooser',
		'  plugin:   ' .. M.root(),
		'  daemon:   ' .. daemon_command(),
		'  unit:     ' .. (status.enabled and 'enabled' or 'not enabled'),
	}
	if #status.stale == 0 then
		table.insert(lines, '  files:    up to date')
	else
		table.insert(lines, '  files:    ' .. #status.stale .. ' out of date')
		for _, path in ipairs(status.stale) do
			table.insert(lines, '    - ' .. path)
		end
	end
	return table.concat(lines, '\n')
end

return M
