--- Version parsing and range matching: an exact version, a prefix/range (`~`,
--- `^`, `>=`/`<`, space/`,` = AND, `||` = OR) or "latest"/"*". Prerelease and
--- build suffixes never take part in a comparison.
const semver = {}

---@class semver.Version
---@field major number
---@field minor number
---@field patch number

--- Bounds in "major.minor.patch"; a missing one is unbounded on that side.
---@class semver.Bound
---@field lower string?
---@field lowerInc boolean?
---@field upper string?
---@field upperInc boolean?

---@param major number
---@param minor number
---@param patch number
local function format(major, minor, patch)
	return string.format("%d.%d.%d", major, minor, patch)
end

---@param v string
---@return semver.Version
function semver.parse(v)
	local major, minor, patch = v:match("(%d+)%.(%d+)%.(%d+)")
	if not major then
		major, minor = v:match("(%d+)%.(%d+)")
	end
	if not major then
		major = v:match("%d+")
	end
	return {
		major = tonumber(major) or 0,
		minor = tonumber(minor) or 0,
		patch = tonumber(patch) or 0
	}
end

---@param v1 string
---@param v2 string
function semver.compare(v1, v2)
	const a = semver.parse(v1)
	const b = semver.parse(v2)

	if a.major ~= b.major then return a.major - b.major end
	if a.minor ~= b.minor then return a.minor - b.minor end
	return a.patch - b.patch
end

---@param current string
---@param candidate string
function semver.isCompatibleUpdate(current, candidate)
	const c = semver.parse(current)
	const n = semver.parse(candidate)
	return n.major == c.major and semver.compare(candidate, current) > 0
end

--- Callers keep a mistyped pin an error instead of resolving to a nearby version.
---@param constraint string
function semver.isExact(constraint)
	return constraint:find("^%d+%.%d+%.%d+") ~= nil
end

--- Wildcards lower the part count ("1.x" is 1); a bare wildcard is 0, i.e. unbounded.
---@param s string
---@return integer major
---@return integer minor
---@return integer patch
---@return integer? parts # nil when `s` is not a version at all
local function parsePartial(s)
	s = s:match("^([^%-%+]+)") or s -- drop -prerelease / +build
	s = s:gsub("%.[xX*]$", "") -- "1.2.x" -> "1.2"
	if s == "" or s == "*" or s == "x" or s == "X" then
		return 0, 0, 0, 0
	end

	local major, minor, patch = s:match("^(%d+)%.(%d+)%.(%d+)$")
	local parts = 3
	if not major then
		major, minor = s:match("^(%d+)%.(%d+)$")
		parts = 2
		if not major then
			major = s:match("^(%d+)$")
			parts = 1
		end
	end
	if not major then return 0, 0, 0, nil end

	return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0, parts
end

---@param op string # "", "=", ">", ">=", "<", "<=", "^", "~", "~>"
---@param spec string
---@return semver.Bound? # nil when the comparator isn't understood
local function expand(op, spec)
	local major, minor, patch, parts = parsePartial(spec)
	if not parts then return nil end
	if parts == 0 then return {} end -- wildcard: no bounds at all

	local lower = format(major, minor, patch)
	const isExactVersion = parts == 3
	-- The version opening the next prefix ("0.1" -> "0.2.0"), read only below.
	local nextPrefix = format(major + 1, 0, 0)
	if parts == 2 then
		nextPrefix = format(major, minor + 1, 0)
	elseif parts == 3 then
		nextPrefix = lower
	end

	if op == "" or op == "=" then
		if isExactVersion then
			return { lower = lower, lowerInc = true, upper = lower, upperInc = true }
		end
		return { lower = lower, lowerInc = true, upper = nextPrefix, upperInc = false }
	end

	if op == ">=" then
		return { lower = lower, lowerInc = true }
	end

	if op == ">" then
		-- ">1.2" excludes the whole 1.2 prefix, so it starts at 1.3.0.
		if isExactVersion then return { lower = lower, lowerInc = false } end
		return { lower = nextPrefix, lowerInc = true }
	end

	if op == "<" then
		return { upper = lower, upperInc = false }
	end

	if op == "<=" then
		if isExactVersion then return { upper = lower, upperInc = true } end
		return { upper = nextPrefix, upperInc = false }
	end

	if op == "^" then
		-- Keeps the leftmost non-zero part: "0.x" is the wild west, "0.2.3" is limited to 0.2.x.
		local upMajor, upMinor, upPatch
		if major > 0 then
			upMajor, upMinor, upPatch = major + 1, 0, 0
		elseif parts == 1 then
			upMajor, upMinor, upPatch = 1, 0, 0
		elseif parts == 2 or minor > 0 then
			upMajor, upMinor, upPatch = 0, minor + 1, 0
		else
			upMajor, upMinor, upPatch = 0, 0, patch + 1
		end
		return { lower = lower, lowerInc = true, upper = format(upMajor, upMinor, upPatch), upperInc = false }
	end

	if op == "~" or op == "~>" then
		-- Patch-only changes, or the whole major when only the major is spelled out.
		const upper = parts == 1 ? format(major + 1, 0, 0) : format(major, minor + 1, 0)
		return { lower = lower, lowerInc = true, upper = upper, upperInc = false }
	end

	return nil
end

--- OR alternatives, each a list of AND-ed bounds; nil when a comparator is malformed.
---@param constraint string
local function compile(constraint)
	local alternatives = {}
	if constraint == "" then
		alternatives[1] = {} -- unbounded: allows everything
		return alternatives
	end

	for alternative in constraint:gmatch("[^|]+") do
		-- ">= 1.2" writes the operator apart from its version, so glue it back.
		alternative = alternative:gsub(",", " "):gsub("([<>=~^]+)%s+", "%1")
		local bounds = {}
		for token in alternative:gmatch("%S+") do
			local op, spec = token:match("^([<>=~^]*)(.*)$")
			if spec == "latest" then spec = "*" end
			const bound = expand(op, spec)
			if not bound then return nil end
			bounds[#bounds + 1] = bound
		end
		alternatives[#alternatives + 1] = bounds
	end
	return alternatives
end

---@param version string
---@param bound semver.Bound
---@return boolean
local function inBound(version, bound)
	if bound.lower then
		local cmp = semver.compare(version, bound.lower)
		if cmp < 0 or (cmp == 0 and not bound.lowerInc) then return false end
	end
	if bound.upper then
		local cmp = semver.compare(version, bound.upper)
		if cmp > 0 or (cmp == 0 and not bound.upperInc) then return false end
	end
	return true
end

---@param version string
---@param alternatives semver.Bound[][]
---@return boolean
local function matches(version, alternatives)
	for _, bounds in ipairs(alternatives) do
		local isMatch = true
		for _, bound in ipairs(bounds) do
			if not inBound(version, bound) then
				isMatch = false
				break
			end
		end
		if isMatch then return true end
	end
	return false
end

--- A malformed constraint satisfies nothing, so a typo never resolves to a surprise version.
---@param version string
---@param constraint string
---@return boolean
function semver.satisfies(version, constraint)
	local alternatives = compile(constraint)
	if not alternatives then return false end
	return matches(version, alternatives)
end

---@param versions table<string, any>? # set keyed by version (a portfile's `versions`)
---@param constraint string
---@return string?
function semver.maxSatisfying(versions, constraint)
	if not versions then return nil end
	local alternatives = compile(constraint)
	if not alternatives then return nil end

	local best
	for v in pairs(versions) do
		if matches(v, alternatives) and (best == nil or semver.compare(v, best) > 0) then
			best = v
		end
	end
	return best
end

return semver
