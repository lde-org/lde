-- Starts child processes that each write one JSON result file, reaps them as they finish, and hands decoded results to the caller. The callers differ only in argv and rendering.

const fs = require("fs")
const path = require("path")
const env = require("env")
const json = require("json")
const process = require("process")
const ffi = require("ffi")

local sleep
if jit.os == "Windows" then
	pcall(ffi.cdef, "void Sleep(unsigned long dwMilliseconds);")
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	pcall(ffi.cdef, "int usleep(unsigned int usec);")
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

---@class lde.childPool.Entry
---@field item any
---@field child process.Child?
---@field resultFile string

---@class lde.childPool.Opts
---@field items any[]
---@field jobs integer
---@field pollMs number
---@field prefix string # scratch directory name prefix under the temp dir
---@field argvFor fun(item: any, resultFile: string): string[]
---@field spawnErrorResult fun(item: any, err: string?): table # JSON body written when the child cannot start
---@field onDone fun(item: any, decoded: table?, output: string, exitCode: number?)

const childPool = {}

---@param ms number
function childPool.sleep(ms)
	sleep(ms)
end

---@param opts lde.childPool.Opts
function childPool.run(opts)
	const execPath = assert(env.execPath(), "no executable path")
	const scratch = path.join(env.tmpdir(), opts.prefix .. "-" .. tostring({}):match("0x(%x+)$"))
	fs.mkdirAll(scratch)

	---@type lde.childPool.Entry[]
	const running = {}
	local next = 1

	local function startNext()
		if next > #opts.items then return end
		const item = opts.items[next]
		const resultFile = path.join(scratch, next .. ".json")
		-- Piped and silent: the child records results and this process renders them.
		local child, err = process.spawn(execPath, opts.argvFor(item, resultFile), { stdout = "pipe", stderr = "pipe" })
		if not child then
			fs.write(resultFile, json.encode(opts.spawnErrorResult(item, err)))
		end
		running[#running + 1] = { item = item, child = child, resultFile = resultFile }
		next += 1
	end

	local function reapFinished()
		for i = #running, 1, -1 do
			const entry = running[i]
			if not entry.child or entry.child:poll() ~= nil then
				local output, exitCode = "", nil
				if entry.child then
					exitCode = entry.child:poll()
					local _, stdout, stderr = entry.child:wait()
					output = (stdout or "") .. (stderr or "")
				end

				local decoded
				if fs.exists(entry.resultFile) then
					const okDecode, parsed = pcall(json.decode, fs.read(entry.resultFile) or "")
					if okDecode and type(parsed) == "table" then decoded = parsed end
				end
				opts.onDone(entry.item, decoded, output, exitCode)
				table.remove(running, i)
			end
		end
	end

	while next <= #opts.items and #running < opts.jobs do startNext() end
	while #running > 0 do
		reapFinished()
		while next <= #opts.items and #running < opts.jobs do startNext() end
		if #running > 0 then sleep(opts.pollMs) end
	end

	fs.rmdir(scratch)
end

return childPool
