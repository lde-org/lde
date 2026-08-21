--- Typo suggestions for command names.

--- Classic Levenshtein edit distance between two strings.
---@param a string
---@param b string
---@return integer
local function levenshtein(a, b)
	local la, lb = #a, #b
	if la == 0 then return lb end
	if lb == 0 then return la end

	local prev = {}
	for j = 0, lb do prev[j] = j end
	for i = 1, la do
		local cur = { [0] = i }
		local ai = a:byte(i)
		for j = 1, lb do
			local cost = ai == b:byte(j) and 0 or 1
			cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		end
		prev = cur
	end
	return prev[lb]
end

--- Suggests the closest command for a typo'd (or partially typed) name.
--- Exact prefixes win (e.g. `lde com` -> compile/completion); otherwise the
--- nearest candidate by edit distance, only when the distance is small enough
--- to plausibly be a typo (at most 2 edits, and never more edits than the
--- input has characters).
---@param name string
---@param candidates string[]
---@return string? hint # "Did you mean `test`?", or a list for ambiguous prefixes
local function suggestCommand(name, candidates)
	local prefixed = {}
	for _, c in ipairs(candidates) do
		if c:sub(1, #name) == name then
			prefixed[#prefixed + 1] = c
		end
	end
	if #prefixed == 1 then
		return "Did you mean `" .. prefixed[1] .. "`?"
	elseif #prefixed > 1 then
		return "Did you mean one of: `" .. table.concat(prefixed, "`, `") .. "`?"
	end

	local best, bestDist
	for _, c in ipairs(candidates) do
		local dist = levenshtein(name, c)
		if not bestDist or dist < bestDist then
			best, bestDist = c, dist
		end
	end
	if bestDist and bestDist <= 2 and bestDist <= #name then
		return "Did you mean `" .. best .. "`?"
	end
	return nil
end

return { command = suggestCommand }
