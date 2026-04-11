-- Minimal Lua token highlighter.
-- Returns a string with ANSI color codes applied.
-- Colors: Catppuccin Mocha

local reset   = "\27[0m"
local keyword = "\27[38;2;203;166;247m"  -- Mauve      keywords
local str     = "\27[38;2;166;227;161m"  -- Green      strings
local num     = "\27[38;2;250;179;135m"  -- Peach      numbers
local comment = "\27[38;2;88;91;112m"    -- Overlay0   comments
local op      = "\27[38;2;137;180;250m"  -- Blue        operators
local ident   = "\27[38;2;205;214;244m"  -- Text        identifiers

local keywords = {
	["and"]=1,["break"]=1,["do"]=1,["else"]=1,["elseif"]=1,
	["end"]=1,["false"]=1,["for"]=1,["function"]=1,["goto"]=1,
	["if"]=1,["in"]=1,["local"]=1,["nil"]=1,["not"]=1,
	["or"]=1,["repeat"]=1,["return"]=1,["then"]=1,["true"]=1,
	["until"]=1,["while"]=1,
}

---@param line string
---@return string highlighted
local function highlight(line)
	local out = {}
	local i   = 1
	local n   = #line

	while i <= n do
		local c = line:sub(i, i)

		-- comment
		if line:sub(i, i+1) == "--" then
			out[#out+1] = comment .. line:sub(i) .. reset
			break

		-- string: single or double quoted (no multiline)
		elseif c == '"' or c == "'" then
			local q   = c
			local j   = i + 1
			while j <= n do
				local ch = line:sub(j, j)
				if ch == "\\" then j = j + 2
				elseif ch == q then j = j + 1; break
				else j = j + 1 end
			end
			out[#out+1] = str .. line:sub(i, j-1) .. reset
			i = j

		-- number
		elseif c:match("%d") or (c == "." and line:sub(i+1,i+1):match("%d")) then
			local j = i
			-- hex
			if line:sub(i, i+1):lower() == "0x" then
				j = i + 2
				while j <= n and line:sub(j,j):match("[%x]") do j = j + 1 end
			else
				while j <= n and line:sub(j,j):match("[%d%.eExX_]") do j = j + 1 end
			end
			out[#out+1] = num .. line:sub(i, j-1) .. reset
			i = j

		-- identifier or keyword
		elseif c:match("[%a_]") then
			local j = i
			while j <= n and line:sub(j,j):match("[%w_]") do j = j + 1 end
			local word = line:sub(i, j-1)
			out[#out+1] = (keywords[word] and keyword or ident) .. word .. reset
			i = j

		-- operators / punctuation
		elseif c:match("[%+%-%*/%%^#&|~<>=%(%)%[%]{}%;:,%.%%]") then
			out[#out+1] = op .. c .. reset
			i = i + 1

		else
			out[#out+1] = c
			i = i + 1
		end
	end

	return table.concat(out)
end

return highlight
