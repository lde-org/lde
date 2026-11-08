-- Persistent GitHub session storage and expiry checks.

const json = require("json")

---@class lde.github.AuthSession
---@field accessToken string
---@field refreshToken string?
---@field expiresAt number? # epoch seconds
---@field refreshExpiresAt number?
---@field login string?
---@field id number?
---@field twoFactor boolean? # GitHub account has 2FA enabled

local store = {}

---@param value any
---@return number?
local function asNumber(value)
	if type(value) == "number" then return value end
	if type(value) == "string" then return tonumber(value) end
	return nil
end

---@class lde.github.AuthStoreOpts
---@field fs table
---@field path table
---@field getConfig fun(): lde.global.Config
---@field authPath fun(): string
---@field now fun(): number
---@field expirySkew integer
---@field storeVersion integer
---@field defaultClientId string?
---@field getEnv fun(name: string): string?

---@param opts lde.github.AuthStoreOpts
---@return table
function store.new(opts)
	local instance = {}
	local fs, path = opts.fs, opts.path

	---@return string
	local function storePath()
		return opts.authPath()
	end

	---@return string?, string?
	function instance.clientId()
		local fromEnv = opts.getEnv("LDE_GITHUB_CLIENT_ID")
		if fromEnv and fromEnv ~= "" then return fromEnv end

		local config = opts.getConfig()
		local configured = config and config.github and config.github.clientId
		if configured and configured ~= "" then return configured end

		if opts.defaultClientId and opts.defaultClientId ~= "" then
			return opts.defaultClientId
		end

		local configPath = path.join(require("lde-core.global.dirs").getUserDir(), "config.json")
		return nil, table.concat({
			"GitHub login is not configured.",
			"Register a GitHub OAuth App with device flow enabled, then set github.clientId in " .. configPath
				.. " (or LDE_GITHUB_CLIENT_ID).",
		}, "\n")
	end

	---@param session lde.github.AuthSession
	---@param at number?
	---@param skew number?
	---@return boolean
	function instance.isExpired(session, at, skew)
		if not session or not session.accessToken or session.accessToken == "" then return true end
		local expiresAt = asNumber(session.expiresAt)
		if not expiresAt then return false end
		at = at or opts.now()
		skew = skew or opts.expirySkew
		return expiresAt - skew <= at
	end

	---@param session lde.github.AuthSession
	---@param at number?
	---@param skew number?
	---@return boolean
	function instance.isRefreshExpired(session, at, skew)
		local expiresAt = asNumber(session and session.refreshExpiresAt)
		if not expiresAt then return false end
		at = at or opts.now()
		skew = skew or opts.expirySkew
		return expiresAt - skew <= at
	end

	---@return lde.github.AuthSession?
	---@return string? err
	function instance.load()
		local file = storePath()
		if not fs.exists(file) then return nil, nil end

		local content = fs.read(file)
		if not content then return nil, "Could not read " .. file end

		local ok, stored = pcall(json.decode, content)
		if not ok or type(stored) ~= "table" then
			return nil, "Stored GitHub session is corrupt; run `lde login` again."
		end

		local session = stored.github or stored
		if type(session) ~= "table" or type(session.accessToken) ~= "string" or session.accessToken == "" then
			return nil, "Stored GitHub session is incomplete; run `lde login` again."
		end

		return session, nil
	end

	---@param session lde.github.AuthSession
	---@return boolean
	---@return string? err
	function instance.save(session)
		local file = storePath()
		fs.mkdirAll(path.dirname(file))
		local stored = {
			version = opts.storeVersion,
			github = session,
		}
		local ok, err = pcall(function()
			local written = fs.write(file, json.encode(stored))
			assert(written, "could not write " .. file)
			if jit.os ~= "Windows" then
				fs.chmod(file, 384) -- 0600
			end
		end)
		if not ok then return false, tostring(err) end
		return true, nil
	end

	---@return boolean
	function instance.clear()
		local file = storePath()
		if fs.exists(file) then
			fs.delete(file)
		end
		return true
	end

	return instance
end

return store
