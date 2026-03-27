local ansi = require("ansi")
local lde = require("lde-core")

---@param code string
local function eval(code)
	local pkg = lde.Package.open()

	local ok, result
	if pkg then
		pkg:installDependencies()
		ok, result = pkg:runString(code)
	else
		ok, result = lde.runtime.executeString(code)
	end

	if not ok then
		ansi.printf("{red}%s", tostring(result))
	elseif result ~= nil then
		print(tostring(result))
	end
end

return eval
