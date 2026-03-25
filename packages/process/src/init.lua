local env = require("env")

local process = {}

local isWindows = jit.os == "Windows"

---@param arg string
local function escape(arg)
	if isWindows then
		if not string.match(arg, '[%s"^&|<>%%]') and arg ~= "" then
			return arg
		end

		local inner = arg
			:gsub('(\\+)"', function(backslashes)
				return backslashes .. backslashes .. '\\"'
			end)
			:gsub('(\\+)$', function(backslashes)
				return backslashes .. backslashes
			end)
			:gsub('"', '\\"')

		return '"' .. inner .. '"'
	else
		return "'" .. string.gsub(arg, "'", "'\\''") .. "'"
	end
end

---@alias process.Stdio "pipe" | "inherit" | "null"

---@class process.CommandOptions
---@field cwd string?
---@field env table<string, string>?
---@field unsafe boolean? # If true, do not escape command and arguments. Especially useful because windows is completely worthless :)
---@field stdin string?
---@field stdout process.Stdio? # Defaults to "pipe"
---@field stderr process.Stdio? # Defaults to "pipe"
---@field maxOutputChunks number? # Max 4096-byte chunks to read from stdout (default 10)

---@class process.SpawnOptions: process.CommandOptions

---@param name string
---@param args string[]?
---@param options process.CommandOptions?
local function formatCommand(name, args, options)
	local escapeFunc = (options and options.unsafe) and function(s) return s end or escape

	if process.platform ~= "win32" then
		name = escapeFunc(name)
	end

	local command
	if args then
		local parts = { name }
		for i, arg in ipairs(args) do
			parts[i + 1] = escapeFunc(arg)
		end

		command = table.concat(parts, " ")
	else
		command = name
	end

	if options and options.cwd then
		if isWindows then
			command = "cd /d " .. escapeFunc(options.cwd) .. " && " .. command
		else
			command = "cd " .. escapeFunc(options.cwd) .. " && " .. command
		end
	end

	if options and options.env then
		local parts = {}
		for k, v in pairs(options.env) do
			if isWindows then
				parts[#parts + 1] = "set " .. string.match(k, "^[%w_]+$") .. "=" .. escapeFunc(v) .. "&&"
			else
				parts[#parts + 1] = "export " .. string.match(k, "^[%w_]+$") .. "=" .. escapeFunc(v) .. ";"
			end
		end

		command = table.concat(parts, " ") .. " " .. command
	end

	return command
end

---@param path string
---@param chunkSize number
---@param maxChunks number
---@return string?
local function readChunked(path, chunkSize, maxChunks)
	local handle = io.open(path, "rb")
	if not handle then
		return
	end

	local buf = {}
	while true do
		local chunk = handle:read(chunkSize)
		if not chunk or #buf > maxChunks then break end
		buf[#buf + 1] = chunk
	end

	handle:close()
	return table.concat(buf)
end

---@param name string
---@param args string[]?
---@param options process.CommandOptions?
local function executeCommand(name, args, options)
	local stdoutMode = (options and options.stdout) or "pipe"
	local stderrMode = (options and options.stderr) or "pipe"

	local command = formatCommand(name, args, options)

	local tmpInputFile = nil
	if options and options.stdin then
		tmpInputFile = env.tmpfile()
		local f = io.open(tmpInputFile, "wb")
		if f then
			f:write(options.stdin)
			f:close()
			command = command .. " < " .. escape(tmpInputFile)
		end
	end

	local tmpOutputFile = nil
	if stdoutMode == "pipe" then
		tmpOutputFile = env.tmpfile()
		command = command .. " >" .. escape(tmpOutputFile)
	elseif stdoutMode == "null" then
		command = command .. (isWindows and " >nul" or " >/dev/null")
	end

	local tmpErrorFile = nil
	if stderrMode == "pipe" then
		tmpErrorFile = env.tmpfile()
		command = command .. " 2>" .. escape(tmpErrorFile)
	elseif stderrMode == "null" then
		command = command .. (isWindows and " 2>nul" or " 2>/dev/null")
	end

	local exitCode = os.execute(command)
	local ranSuccessfully = exitCode == true or exitCode == 0 -- todo: WTAF?

	local catastrophicFailure = nil ---@type string?
	local output ---@type string?
	if tmpOutputFile then
		if ranSuccessfully then
			output = readChunked(tmpOutputFile, 4096, (options and options.maxOutputChunks) or 10)
			if not output then
				catastrophicFailure = "Failed to read stdout"
			end
		end
		os.remove(tmpOutputFile)
	end
	if tmpErrorFile then
		if not ranSuccessfully and not output then
			output = readChunked(tmpErrorFile, 4096, 10)
			if not output then
				catastrophicFailure = "Failed to read stderr"
			end
		end
		os.remove(tmpErrorFile)
	end

	if tmpInputFile then os.remove(tmpInputFile) end

	if catastrophicFailure then
		error(catastrophicFailure)
	end

	return ranSuccessfully, output
end

---@param name string
---@param args string[]?
---@param options process.CommandOptions?
---@return boolean? # Success
---@return string? # Captured stdout on success, captured stderr on failure
function process.exec(name, args, options)
	return executeCommand(name, args, options)
end

---@param name string
---@param args string[]?
---@param options process.CommandOptions?
---@return boolean # Success
---@return string? # Captured stderr on failure
function process.spawn(name, args, options)
	options = options or {}
	if not options.stdout then
		options = setmetatable({ stdout = "null" }, { __index = options })
	end
	return executeCommand(name, args, options)
end

if isWindows then
	process.platform = "win32"
elseif jit.os == "Linux" then
	process.platform = "linux"
elseif jit.os == "OSX" then
	process.platform = "darwin"
else
	process.platform = "unix"
end

return process
