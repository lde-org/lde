const test = require("lde-test")
const json = require("json")
const path = require("path")

const auth = require("lde.github.auth")

---@return table fs
---@return table state
local function fakeFs()
	local files = {}
	local chmods = {}
	return {
		files = files,
		chmods = chmods,
		exists = function(p) return files[p] ~= nil end,
		read = function(p) return files[p] end,
		write = function(p, content) files[p] = content; return true end,
		delete = function(p) files[p] = nil; return true end,
		mkdirAll = function() return true end,
		chmod = function(p, mode) chmods[#chmods + 1] = { path = p, mode = mode }; return true end,
	}, { files = files }
end

---@param opts { http: function?, now: table?, fs: table?, getConfig: function?, getEnv: function?, defaultClientId: string? }?
local function makeAuth(opts)
	opts = opts or {}
	local fs = opts.fs or fakeFs()
	local clock = opts.now or { value = 1000 }
	local instance = auth.new({
		fs = fs,
		path = path,
		authPath = function() return "/lde-test/auth.json" end,
		now = function() return clock.value end,
		sleep = function(ms) clock.value = clock.value + ms / 1000 end,
		getConfig = opts.getConfig or function() return { github = { clientId = "test-client" } } end,
		getEnv = opts.getEnv or function() return nil end,
		defaultClientId = opts.defaultClientId,
		http = opts.http or function() return { status = 500, body = "" }, "no http" end,
	})
	return instance, fs, clock
end

---@param payload table
local function jsonResponse(payload)
	return { status = 200, body = json.encode(payload) }
end

test.it("uses the built-in OAuth client ID when none is configured", function()
	local requests = {}
	local instance = makeAuth({
		getConfig = function() return {} end,
		getEnv = function() return nil end,
		http = function(request)
			requests[#requests + 1] = request
			return { status = 200, body = json.encode({
				device_code = "device",
				user_code = "code",
				verification_uri = "https://github.com/login/device",
				expires_in = 900,
				interval = 5,
			}) }
		end,
	})
	const device, err = instance.startDeviceFlow()
	test.truthy(device, err)
	test.includes(requests[1].body, "client_id=" .. auth.DEFAULT_CLIENT_ID)
end)

test.it("treats tokens inside the 60s skew as expired", function()
	local instance = makeAuth()
	test.truthy(instance.isExpired({ accessToken = "x", expiresAt = 1050 }, 1000))
	test.falsy(instance.isExpired({ accessToken = "x", expiresAt = 1100 }, 1000))
	test.falsy(instance.isExpired({ accessToken = "x", expiresAt = nil }, 1000))
	test.truthy(instance.isExpired({ accessToken = "" }, 1000))
end)

test.it("round-trips a session and sets 0600 on POSIX", function()
	local instance, fs = makeAuth()
	local session = {
		accessToken = "ghu_access",
		refreshToken = "ghr_refresh",
		expiresAt = 2000,
		refreshExpiresAt = 5000,
		login = "octocat",
		id = 42,
	}
	const saved, saveErr = instance.save(session)
	test.truthy(saved, saveErr)
	if jit.os ~= "Windows" then
		test.equal(fs.chmods[1].mode, 384)
	end

	const stored = json.decode(fs.files["/lde-test/auth.json"])
	test.equal(stored.version, 1)
	test.equal(stored.github.accessToken, "ghu_access")

	const loaded = instance.load()
	test.truthy(loaded)
	test.equal(loaded.refreshToken, "ghr_refresh")
	test.equal(loaded.login, "octocat")
	test.equal(loaded.id, 42)
end)

test.it("logout deletes the stored session without network access", function()
	local instance, fs = makeAuth()
	instance.save({ accessToken = "ghu_access" })
	test.truthy(fs.files["/lde-test/auth.json"])
	instance.clear()
	test.falsy(instance.load())
	test.falsy(fs.files["/lde-test/auth.json"])
end)

test.it("refreshes an expired access token and persists the new pair", function()
	local requests = {}
	local instance, fs = makeAuth({
		http = function(request)
			requests[#requests + 1] = request
			return jsonResponse({
				access_token = "ghu_new",
				refresh_token = "ghr_new",
				expires_in = 3600,
				refresh_token_expires_in = 100000,
			})
		end,
	})
	instance.save({
		accessToken = "ghu_old",
		refreshToken = "ghr_old",
		expiresAt = 1000,
		refreshExpiresAt = 900000,
		login = "octocat",
		id = 42,
	})

	const session, err = instance.ensureValid()
	test.truthy(session, err)
	test.equal(session.accessToken, "ghu_new")
	test.equal(session.login, "octocat")
	test.equal(requests[1].url, "https://github.com/login/oauth/access_token")
	test.includes(requests[1].body, "grant_type=refresh_token")
	test.includes(requests[1].body, "refresh_token=ghr_old")

	const stored = json.decode(fs.files["/lde-test/auth.json"])
	test.equal(stored.github.accessToken, "ghu_new")
	test.equal(stored.github.refreshExpiresAt, 100000 + 1000)
end)

test.it("points at lde login when refreshing fails", function()
	local instance = makeAuth({
		http = function()
			return jsonResponse({ error = "invalid_grant", error_description = "refresh token is invalid" })
		end,
	})
	instance.save({
		accessToken = "ghu_old",
		refreshToken = "ghr_old",
		expiresAt = 1000,
		refreshExpiresAt = 900000,
	})

	const session, err = instance.ensureValid()
	test.falsy(session)
	test.includes(err, "lde login")
end)

test.it("runs the device flow until GitHub returns a token", function()
	local tokenPolls = 0
	local seenCode
	local instance = makeAuth({
		http = function(request)
			if request.url:find("/login/device/code", 1, true) then
				return jsonResponse({
					device_code = "device-1",
					user_code = "ABCD-1234",
					verification_uri = "https://github.com/login/device",
					expires_in = 900,
					interval = 1,
				})
			end
			if request.url:find("/login/oauth/access_token", 1, true) then
				tokenPolls = tokenPolls + 1
				if tokenPolls == 1 then
					return jsonResponse({ error = "authorization_pending" })
				end
				return jsonResponse({
					access_token = "ghu_live",
					refresh_token = "ghr_live",
					expires_in = 28800,
					refresh_token_expires_in = 15811200,
				})
			end
			if request.url == "https://api.github.com/user" then
				return jsonResponse({ login = "octocat", id = 123 })
			end
			return { status = 404, body = "" }
		end,
	})

	const session, err = instance.login({
		onCode = function(device)
			seenCode = device
		end,
	})
	test.truthy(session, err)
	test.equal(tokenPolls, 2)
	test.equal(seenCode.userCode, "ABCD-1234")
	test.equal(session.login, "octocat")
	test.equal(session.id, 123)
	test.equal(session.accessToken, "ghu_live")
end)

test.it("reports a missing client ID with setup instructions", function()
	local instance = auth.new({
		fs = fakeFs(),
		path = path,
		authPath = function() return "/lde-test/auth.json" end,
		getConfig = function() return {} end,
		getEnv = function() return nil end,
		defaultClientId = "",
		http = function() return nil, "unused" end,
	})
	const session, err = instance.login()
	test.falsy(session)
	test.includes(err, "github.clientId")
	test.includes(err, "device flow")
end)
