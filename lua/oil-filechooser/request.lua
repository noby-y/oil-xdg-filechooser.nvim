--- Reading the pending portal request, and answering it.
---
--- The daemon writes the request as JSON and points $OIL_FILECHOOSER_REQUEST at
--- it, so the whole thing is available for as long as this Neovim lives -- there
--- is no state to lose and no argument list to re-parse. The daemon is blocked
--- on our exit, so answering is: write the response file, then quit.

local M = {}

--- @class OilFileChooserRequest
--- @field method 'OpenFile'|'SaveFile'|'SaveFiles'
--- @field app_id string
--- @field title string
--- @field handle string
--- @field response string  path the answer is written to
--- @field options table

--- Whether this Neovim is a dialog, which is decided by the daemon having set
--- $OIL_FILECHOOSER_REQUEST -- not by the request parsing. A malformed request
--- must not make this look like an ordinary session: the installation checks
--- that run there would restart the daemon that is waiting on us.
--- @return string|nil path
function M.pending()
	local path = vim.env.OIL_FILECHOOSER_REQUEST
	if path == nil or path == '' then
		return nil
	end
	return path
end

--- The pending request, or nil in an ordinary Neovim session.
--- @return OilFileChooserRequest|nil
function M.read()
	local path = M.pending()
	if not path then
		return nil
	end

	local fd = io.open(path, 'r')
	if not fd then
		vim.notify('oil-filechooser: cannot read request ' .. path, vim.log.levels.ERROR)
		return nil
	end
	local raw = fd:read('*a')
	fd:close()

	local ok, request = pcall(vim.json.decode, raw)
	if not ok or type(request) ~= 'table' or type(request.response) ~= 'string' then
		vim.notify('oil-filechooser: malformed request', vim.log.levels.ERROR)
		return nil
	end

	request.options = type(request.options) == 'table' and request.options or {}
	return request
end

--- @param request OilFileChooserRequest
--- @param payload table
--- @return boolean
local function write(request, payload)
	local fd = io.open(request.response, 'w')
	if not fd then
		vim.notify('oil-filechooser: cannot write ' .. request.response, vim.log.levels.ERROR)
		return false
	end
	fd:write(vim.json.encode(payload))
	fd:close()
	return true
end

--- Hands `paths` back to the application and tears this instance down. Quitting
--- is part of the answer: the daemon reads the response file once we exit.
--- @param request OilFileChooserRequest
--- @param paths string[]
function M.respond(request, paths)
	if #paths == 0 then
		return
	end
	if write(request, { response = 0, paths = paths }) then
		vim.cmd('qa!')
	end
end

--- @param request OilFileChooserRequest
function M.cancel(request)
	write(request, { response = 1, paths = {} })
	vim.cmd('qa!')
end

--- Where the dialog should open.
--- @param request OilFileChooserRequest
--- @return string
function M.start_dir(request)
	local options = request.options
	local candidates = {
		options.current_folder,
		options.current_file and vim.fs.dirname(options.current_file) or nil,
		vim.uv.cwd(),
		vim.env.HOME,
	}
	for _, dir in ipairs(candidates) do
		if dir ~= '' and vim.fn.isdirectory(vim.fn.expand(dir)) == 1 then
			return dir
		end
	end
	return vim.env.HOME
end

--- True when the request is answered by a directory rather than by files.
--- @param request OilFileChooserRequest
--- @return boolean
function M.wants_directory(request)
	return request.options.directory == true or request.method == 'SaveFiles'
end

--- @param request OilFileChooserRequest
--- @return boolean
function M.wants_multiple(request)
	return request.options.multiple == true and not M.wants_directory(request)
end

return M
