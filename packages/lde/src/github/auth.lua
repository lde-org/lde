-- GitHub OAuth device-flow login and token storage.
--
-- Device flow needs no client secret: the CLI only carries a public client ID
-- (github.clientId in ~/.lde/config.json or LDE_GITHUB_CLIENT_ID). Access
-- tokens are short-lived (about 8 hours); the refresh token lasts six months.

const constants = require("lde.github.auth.constants")
const flowModule = require("lde.github.auth.flow")
const httpModule = require("lde.github.auth.http")
const storeModule = require("lde.github.auth.store")

---@class lde.github.AuthDeps
---@field fs table?
---@field path table?
---@field http (fun(opts: table): (table?, string?))? # injectable transport
---@field now (fun(): number)?
---@field sleep (fun(ms: number))?
---@field getConfig (fun(): lde.global.Config)?
---@field authPath (fun(): string)?
---@field userAgent string?
---@field getEnv (fun(name: string): string?)?
---@field defaultClientId string?

local auth = {}

auth.DEFAULT_CLIENT_ID = constants.DEFAULT_CLIENT_ID
auth.STORE_VERSION = constants.STORE_VERSION
auth.EXPIRY_SKEW = constants.EXPIRY_SKEW
auth.DEVICE_CODE_URL = constants.DEVICE_CODE_URL
auth.TOKEN_URL = constants.TOKEN_URL
auth.API_URL = constants.API_URL

---@param opts lde.github.AuthDeps?
---@return table # a bound auth instance
function auth.new(opts)
	opts = opts or {}

	local path = opts.path or require("path")
	local fs = opts.fs or require("fs")
	local http = opts.http or function(requestOpts)
		---@cast requestOpts curl.CurlOptions
		return require("curl-sys").request(requestOpts)
	end
	local now = opts.now or os.time
	local sleep = opts.sleep or function(ms)
		---@cast ms number
		require("lde-core.util.childpool").sleep(ms)
	end
	local getConfig = opts.getConfig or function()
		return require("lde-core.global").getConfig()
	end
	local authPath = opts.authPath or function()
		return path.join(require("lde-core.global.dirs").getUserDir(), "auth.json")
	end
	local userAgent = opts.userAgent or (function()
		local ok, version = pcall(require, "lde.version")
		return "lde/" .. (ok and tostring(version) or "0.11.0")
	end)()
	local getEnv = opts.getEnv or os.getenv

	local store = storeModule.new({
		fs = fs,
		path = path,
		getConfig = getConfig,
		authPath = authPath,
		now = now,
		expirySkew = constants.EXPIRY_SKEW,
		storeVersion = constants.STORE_VERSION,
		defaultClientId = opts.defaultClientId ~= nil
			and opts.defaultClientId
			or constants.DEFAULT_CLIENT_ID,
		getEnv = getEnv,
	})
	---@cast http fun(opts: table): (table?, string?)
	local httpClient = httpModule.new({
		http = http,
		userAgent = userAgent,
		apiUrl = constants.API_URL,
	})
	local flow = flowModule.new({
		store = store,
		http = httpClient,
		now = now,
		sleep = sleep,
		constants = constants,
	})

	local instance = {
		isExpired = store.isExpired,
		isRefreshExpired = store.isRefreshExpired,
		load = store.load,
		save = store.save,
		clear = store.clear,
		refresh = flow.refresh,
		startDeviceFlow = flow.startDeviceFlow,
		pollDeviceFlow = flow.pollDeviceFlow,
		login = flow.login,
		ensureValid = flow.ensureValid,
	}
	instance.needsRefresh = store.isExpired
	return instance
end

---@type table?
local defaultInstance

---@return table
local function default()
	if not defaultInstance then
		defaultInstance = auth.new()
	end
	return defaultInstance
end

for _, name in ipairs({
	"isExpired",
	"isRefreshExpired",
	"load",
	"save",
	"clear",
	"refresh",
	"startDeviceFlow",
	"pollDeviceFlow",
	"login",
	"ensureValid",
	"needsRefresh",
}) do
	auth[name] = function(...)
		return default()[name](...)
	end
end

return auth
