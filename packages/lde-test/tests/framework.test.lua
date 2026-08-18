-- Tests for lde-test itself: the errors() assertion and the optional context
-- message accepted by every assertion.
local test = require("lde-test")

test.it("errors passes when the function throws", function()
	test.errors(function() error("boom") end)
	test.errors(function() error("boom", 0) end)
end)

test.it("errors matches string error messages without position prefixes", function()
	test.errors(function() error("boom") end, "boom")
	test.errors(function() error("boom", 0) end, "boom")
end)

test.it("errors matches non-string errors by identity", function()
	local e = { code = 42 }
	test.errors(function() error(e) end, e)
end)

test.it("errors fails when the function does not throw", function()
	local ok, err = pcall(test.errors, function() end)
	test.falsy(ok)
	test.includes(tostring(err), "Expected function to throw an error")
end)

test.it("errors fails on a mismatched error message", function()
	local ok, err = pcall(test.errors, function() error("boom") end, "nope")
	test.falsy(ok)
	test.includes(tostring(err), "Expected error to equal nope, got boom")
end)

test.it("errors accepts a context message", function()
	local ok, err = pcall(test.errors, function() end, nil, "should have thrown")
	test.falsy(ok)
	test.includes(tostring(err), "should have thrown")
end)

test.it("assertions accept an optional context message", function()
	test.equal(1, 1, "equal context")
	test.notEqual(1, 2, "notEqual context")
	test.truthy(true, "truthy context")
	test.falsy(false, "falsy context")
	test.includes("hello", "ell", "includes context")
	test.greater(2, 1, "greater context")
	test.less(1, 2, "less context")
	test.greaterEqual(2, 2, "greaterEqual context")
	test.lessEqual(2, 2, "lessEqual context")
	test.deepEqual({ a = 1 }, { a = 1 }, "deepEqual context")
	test.match({ a = 1, b = 2 }, { a = 1 }, "match context")
end)

test.it("context messages surface in assertion failures", function()
	local ok, err = pcall(test.equal, 1, 2, "should equal each other")
	test.falsy(ok)
	test.includes(tostring(err), "should equal each other")

	local ok2, err2 = pcall(test.match, { x = 1 }, { x = 2 }, "mismatch context")
	test.falsy(ok2)
	test.includes(tostring(err2), "mismatch context")

	local ok3, err3 = pcall(test.includes, "abc", "zzz", "substring context")
	test.falsy(ok3)
	test.includes(tostring(err3), "substring context")
end)
