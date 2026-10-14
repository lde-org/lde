-- Git host shorthands for CLI name positions: `gh:owner/repo` is sugar for `--git https://github.com/owner/repo`, and `gh:<pkg>@owner/repo` selects a package inside a monorepo.

---@type table<string, string>
const HOSTS = {
	["gh:"] = "https://github.com/",
	["github:"] = "https://github.com/",
	["codeberg:"] = "https://codeberg.org/",
	["gitlab:"] = "https://gitlab.com/",
}

--- Valid forms: gh:owner/repo (trailing .git allowed) or gh:<package>@owner/repo.
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
