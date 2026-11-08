-- GitHub OAuth device flow and session refresh.

---@class lde.github.AuthDeviceCode
---@field deviceCode string
---@field userCode string
---@field verificationUri string
---@field expiresIn number
---@field interval number

local flow = {}

---@class lde.github.AuthFlowOpts
---@field store table
---@field http table
---@field now fun(): number
---@field sleep fun(ms: number)
---@field constants table

---@param opts lde.github.AuthFlowOpts
---@return table
function flow.new(opts)
	local instance = {}
	local http = opts.http
	local store = opts.store
	local constants = opts.constants

	---@param current lde.github.AuthSession
	---@return lde.github.AuthSession?
	---@return string? err
	function instance.refresh(current)
		local id, configErr = store.clientId()
		if not id then return nil, configErr end

		if not current.refreshToken or current.refreshToken == "" then
			return nil, "No refresh token is stored; run `lde login` again."
		end
		if store.isRefreshExpired(current, opts.now(), constants.EXPIRY_SKEW) then
			return nil, "The refresh token has expired; run `lde login` again."
		end

		local data, _, err = http.postForm(constants.TOKEN_URL, {
			client_id = id,
			grant_type = "refresh_token",
			refresh_token = current.refreshToken,
		})
		if err then return nil, err end
		if not data then return nil, "GitHub returned an empty token response" end

		local accessToken = data.access_token
		if type(accessToken) ~= "string" or accessToken == "" then
			return nil, http.responseError(data, 200)
		end

		local refreshedAt = opts.now()
		local expiresIn = http.asNumber(data.expires_in)
		local refreshExpiresIn = http.asNumber(data.refresh_token_expires_in)
		local session = {
			accessToken = accessToken,
			refreshToken = type(data.refresh_token) == "string" and data.refresh_token or current.refreshToken,
			expiresAt = expiresIn and (refreshedAt + expiresIn) or current.expiresAt,
			refreshExpiresAt = refreshExpiresIn
				and (refreshedAt + refreshExpiresIn)
				or current.refreshExpiresAt,
			login = current.login,
			id = current.id,
			twoFactor = current.twoFactor,
		}
		store.save(session)
		return session, nil
	end

	--- Start the device flow. Returns the code the caller shows the user.
	---@return lde.github.AuthDeviceCode?
	---@return string? err
	function instance.startDeviceFlow()
		local id, configErr = store.clientId()
		if not id then return nil, configErr end

		local data, _, err = http.postForm(constants.DEVICE_CODE_URL, {
			client_id = id,
			scope = "public_repo offline_access",
		})
		if err then return nil, err end
		if type(data) ~= "table" or type(data.device_code) ~= "string" then
			return nil, http.responseError(data, 200)
		end

		return {
			deviceCode = data.device_code,
			userCode = data.user_code,
			verificationUri = data.verification_uri or data.verification_url,
			expiresIn = http.asNumber(data.expires_in) or 900,
			interval = http.asNumber(data.interval) or 5,
		}, nil
	end

	---@param device lde.github.AuthDeviceCode
	---@return lde.github.AuthSession?
	---@return string? err
	function instance.pollDeviceFlow(device)
		local id, configErr = store.clientId()
		if not id then return nil, configErr end

		local deadline = opts.now() + device.expiresIn
		local interval = device.interval > 0 and device.interval or 5

		while opts.now() < deadline do
			opts.sleep(interval * 1000)

			local data, _, err = http.postForm(constants.TOKEN_URL, {
				client_id = id,
				device_code = device.deviceCode,
				grant_type = "urn:ietf:params:oauth:grant-type:device_code",
			})
			if err then return nil, err end

			local accessToken = type(data) == "table" and data.access_token or nil
			if type(accessToken) == "string" and accessToken ~= "" then
				local issuedAt = opts.now()
				local expiresIn = http.asNumber(data.expires_in)
				local refreshExpiresIn = http.asNumber(data.refresh_token_expires_in)
				local session = {
					accessToken = accessToken,
					refreshToken = type(data.refresh_token) == "string" and data.refresh_token or nil,
					expiresAt = expiresIn and (issuedAt + expiresIn) or nil,
					refreshExpiresAt = refreshExpiresIn and (issuedAt + refreshExpiresIn) or nil,
				}

				local user, userErr = http.fetchUser(session)
				if not user then return nil, userErr end
				session.login = type(user.login) == "string" and user.login or nil
				session.id = http.asNumber(user.id)
				session.twoFactor = user.two_factor_authentication == true

				store.save(session)
				return session, nil
			end

			local code = type(data) == "table" and data.error or nil
			if code == "authorization_pending" then
				-- Keep polling at the current interval.
			elseif code == "slow_down" then
				interval = interval + 5
			elseif code == "expired_token" then
				return nil, "The device code expired; run `lde login` again."
			elseif code == "access_denied" then
				return nil, "Authorization was denied."
			else
				return nil, http.responseError(data, 200)
			end
		end

		return nil, "Timed out waiting for authorization; run `lde login` again."
	end

	--- Full interactive login.
	---@param loginOpts { onCode: (fun(device: lde.github.AuthDeviceCode))? }?
	---@return lde.github.AuthSession?
	---@return string? err
	function instance.login(loginOpts)
		local device, deviceErr = instance.startDeviceFlow()
		if not device then return nil, deviceErr end
		if loginOpts and loginOpts.onCode then
			loginOpts.onCode(device)
		end
		return instance.pollDeviceFlow(device)
	end

	--- Load a session, refreshing the access token when it is expired or close
	--- to expiry. A missing session is reported as a login hint.
	---@return lde.github.AuthSession?
	---@return string? err
	function instance.ensureValid()
		local session, loadErr = store.load()
		if loadErr then return nil, loadErr end
		if not session then
			return nil, "Not logged in to GitHub. Run `lde login` first."
		end

		---@cast session lde.github.AuthSession
		if store.isExpired(session) then
			if store.isRefreshExpired(session) then
				return nil, "Your GitHub session expired; run `lde login` again."
			end
			local refreshed, refreshErr = instance.refresh(session)
			if not refreshed then
				return nil, "Could not refresh your GitHub session ("
					.. (refreshErr or "unknown error") .. "); run `lde login` again."
			end
			session = refreshed
		end

		return session, nil
	end

	return instance
end

return flow
