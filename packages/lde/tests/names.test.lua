-- Tests for lde.global.validatePackageName. The rules mirror what the lde
-- registry enforces (schemas/registry.schema.json in lde-org/registry), so
-- anything lde accepts can actually be published/looked up.
local test = require("lde-test")

local lde = require("lde-core")
local validate = lde.global.validatePackageName

---@param name string
local function isValid(name)
	return validate(name) == nil
end

test.it("accepts flat lowercase names", function()
	test.truthy(isValid("fs"))
	test.truthy(isValid("a"))
	test.truthy(isValid("abc"))
	test.truthy(isValid("git2-sys"))
	test.truthy(isValid("sstream"))
	test.truthy(isValid("abc123"))
	test.truthy(isValid("a-a"))
end)

test.it("accepts valid namespaced names", function()
	test.truthy(isValid("ns-owner/pkg"))
	test.truthy(isValid("abc/pkg"))
	test.truthy(isValid("abc/pkg2"))
	test.truthy(isValid("abc/pkg-1"))
end)

test.it("rejects invalid flat names", function()
	test.falsy(isValid(""))          -- empty
	test.falsy(isValid("Fs"))         -- uppercase
	test.falsy(isValid("foo.bar"))    -- dots
	test.falsy(isValid("1foo"))       -- starts with a digit
	test.falsy(isValid("foo_"))       -- ends with an underscore
	test.falsy(isValid("foo-"))       -- ends with a dash
	test.falsy(isValid("foo bar"))    -- space
	test.falsy(isValid("--x"))        -- does not start with a letter
end)

test.it("rejects invalid namespaced names", function()
	test.falsy(isValid("a/pkg"))      -- namespace too short
	test.falsy(isValid("ab/pkg"))     -- namespace too short
	test.falsy(isValid("abc/"))       -- trailing slash
	test.falsy(isValid("/abc"))       -- leading slash
	test.falsy(isValid("abc//pkg"))   -- empty segment
	test.falsy(isValid("a/b/c"))      -- more than one level
	test.falsy(isValid("abc/Pkg"))    -- uppercase part
	test.falsy(isValid("../x"))       -- traversal
	test.falsy(isValid("abc/.."))     -- traversal in part
end)

test.it("rejects overlong names", function()
	test.falsy(isValid(string.rep("a", 129)))
	test.falsy(isValid("abc/" .. string.rep("a", 130)))
end)
