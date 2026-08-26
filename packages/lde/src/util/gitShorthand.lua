-- Git host shorthands for CLI name positions: `gh:foo/bar` is sugar for
-- `--git https://github.com/foo/bar`, etc. Mirrors the hosts lde-core already
-- recognizes for tarball downloads (github/gitlab/codeberg).
--
-- Two forms exist:
--   gh:owner/repo            → the repo root package
--   gh:<pkg>@owner/repo      → the package named <pkg> inside the monorepo
--                             (≡ `--git <host>/owner/repo <pkg>`)

---@type table<string, string>
local HOSTS = {
	["gh:"] = "https://github.com/",
	["github:"] = "https://github.com/",
	["codeberg:"] = "https://codeberg.org/",
	["gitlab:"] = "https://gitlab.com/",
}

--- Expands a git shorthand to a clone URL, or nil when the name isn't one.
--- Valid forms: gh:owner/repo (trailing .git allowed), or
--- gh:<package>@owner/repo for a package inside a monorepo.
---@param name string
---@return string? url
---@return string? subPackage # sub-package name inside the repo (monorepo form)
---@return string? err # set when the name starts with a shorthand prefix but is malformed
local function expand(name)
	for prefix, base in pairs(HOSTS) do
		local rest = name:match("^" .. prefix .. "(.*)$")
		if rest then
			local subPackage, repo = rest:match("^([^@]+)@(.+)$")
			if subPackage then
				if repo:match("^[^/@]+/[^/@]+$") then
					return base .. repo, subPackage, nil
				end
				return nil, nil, "Invalid git shorthand '" .. name .. "': expected " .. prefix .. "<package>@owner/repo"
			end
			if rest:match("^[^/@]+/[^/@]+$") then
				return base .. rest, nil, nil
			end
			return nil, nil, "Invalid git shorthand '" .. name .. "': expected " .. prefix .. "owner/repo"
		end
	end
	return nil, nil, nil
end

return { expand = expand }
