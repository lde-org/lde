---
title: Fixtures
order: 0
---

When writing tests, you'll often come across the need to share state or helpers across multiple test files.

For this reason, files in your `./tests` folder are exposed to lua's package system via the `tests` module.

To require the file `./tests/fixtures/foo.lua`, do `require("tests.fixtures.foo")`.

> [!WARNING]
> This is NOT relative require support. You must always use the full `tests.<module>` path, just as you would with `require("mypackage.util")`.

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
