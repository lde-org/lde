---
title: Test Fixtures
order: 2
---

# Test Fixtures

Your `tests/` folder is automatically exposed as a package named `tests`, so any `.lua` file inside it can be required using the `tests.` prefix, the same way you'd require any other dependency.

Note that this is not relative require support. You must always use the full `tests.<module>` path, just as you would with `require("mypackage.util")`.

This is useful for sharing helpers or fixtures across multiple test files:

```lua tests/fixture.lua
return {
	makeUser = function(name)
		return { name = name, active = true }
	end
}
```

```lua tests/users.test.lua
local test = require("lde-test")
local fixture = require("tests.fixture")

test.it("user is active by default", function()
	local user = fixture.makeUser("alice")
	test.equal(user.active, true)
end)
```
