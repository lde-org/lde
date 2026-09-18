-- Version parsing and range matching. Ranges are what a manifest's registry
-- dependency uses when it names more than one version: "0.1" is the whole 0.1
-- prefix, "^0.1.2" the 0.1 line, ">=1.2 <2" a comparable window.
local test = require("lde-test")

local semver = require("semver")

--
-- parse / compare
--

test.it("parse defaults missing version parts to 0", function()
	test.equal(semver.parse("1.2.3").patch, 3)
	test.equal(semver.parse("0.1").minor, 1, "a partial version is a real version, not all zeros")
	test.equal(semver.parse("0.1").patch, 0)
	test.equal(semver.parse("1").major, 1)
	test.equal(semver.parse("1.2.3-rc.1").patch, 3, "prerelease suffixes are ignored")
	test.equal(semver.parse("1.2.3+deadbeef").patch, 3, "build metadata is ignored")
end)

test.it("compare orders partial versions numerically", function()
	test.equal(semver.compare("0.1", "0.1.0"), 0)
	test.truthy(semver.compare("0.1.1", "0.1") > 0)
	test.truthy(semver.compare("0.10.0", "0.9.0") > 0, "10 must sort after 9")
	test.truthy(semver.compare("1.0.0", "2.0.0") < 0)
end)

test.it("isCompatibleUpdate only accepts same-major bumps", function()
	test.truthy(semver.isCompatibleUpdate("1.2.0", "1.3.0"))
	test.truthy(semver.isCompatibleUpdate("1.2.0", "1.2.1"))
	test.falsy(semver.isCompatibleUpdate("1.2.0", "2.0.0"))
	test.falsy(semver.isCompatibleUpdate("1.2.0", "1.2.0"), "an equal version is not an update")
end)

--
-- isExact
--

test.it("isExact tells a pin from a range", function()
	test.truthy(semver.isExact("1.2.3"))
	test.truthy(semver.isExact("1.2.3-rc.1"), "a prerelease is still one version")
	test.falsy(semver.isExact("1.2"))
	test.falsy(semver.isExact("1"))
	test.falsy(semver.isExact("1.2.x"))
	test.falsy(semver.isExact("^1.2.3"))
	test.falsy(semver.isExact(">=1.2"))
	test.falsy(semver.isExact("latest"))
end)

--
-- exact versions and prefixes
--

test.it("an exact version matches only itself", function()
	test.truthy(semver.satisfies("1.2.3", "1.2.3"))
	test.falsy(semver.satisfies("1.2.4", "1.2.3"), "a pin must never float")
	test.falsy(semver.satisfies("1.2.2", "1.2.3"))
	test.truthy(semver.satisfies("1.2.3", "=1.2.3"))
end)

test.it("a partial version matches its whole prefix", function()
	test.truthy(semver.satisfies("0.1.0", "0.1"))
	test.truthy(semver.satisfies("0.1.9", "0.1"))
	test.falsy(semver.satisfies("0.2.0", "0.1"), "0.1 must not float into 0.2")
	test.falsy(semver.satisfies("0.0.9", "0.1"))

	test.truthy(semver.satisfies("1.9.9", "1"))
	test.falsy(semver.satisfies("2.0.0", "1"))
	test.falsy(semver.satisfies("0.9.9", "1"))
end)

test.it("x/* components are wildcards", function()
	test.truthy(semver.satisfies("1.2.7", "1.2.x"))
	test.truthy(semver.satisfies("1.2.7", "1.2.*"))
	test.falsy(semver.satisfies("1.3.0", "1.2.x"))
	test.truthy(semver.satisfies("1.9.9", "1.x"))

	test.truthy(semver.satisfies("0.0.1", "*"))
	test.truthy(semver.satisfies("99.0.0", "latest"))
	test.truthy(semver.satisfies("1.0.0", ""), "an empty constraint is unbounded")
end)

--
-- comparators
--

test.it("comparison operators bound the range", function()
	test.truthy(semver.satisfies("1.2.0", ">=1.2"))
	test.falsy(semver.satisfies("1.1.9", ">=1.2"))

	test.falsy(semver.satisfies("1.2.9", ">1.2"), ">1.2 excludes the whole 1.2 prefix")
	test.truthy(semver.satisfies("1.3.0", ">1.2"))
	test.falsy(semver.satisfies("1.2.0", ">1.2.0"))
	test.truthy(semver.satisfies("1.2.1", ">1.2.0"))

	test.truthy(semver.satisfies("1.1.9", "<1.2"))
	test.falsy(semver.satisfies("1.2.0", "<1.2"))
	test.truthy(semver.satisfies("1.2.9", "<=1.2"), "<=1.2 includes the whole 1.2 prefix")
	test.falsy(semver.satisfies("1.3.0", "<=1.2"))
	test.truthy(semver.satisfies("1.2.0", "<=1.2.0"))
end)

test.it("an operator may be spelled apart from its version", function()
	test.truthy(semver.satisfies("1.2.0", ">= 1.2"))
	test.truthy(semver.satisfies("1.5.0", ">= 1.2 < 2.0"))
end)

test.it("caret allows changes that keep the leftmost non-zero part", function()
	test.truthy(semver.satisfies("1.2.3", "^1.2.3"))
	test.truthy(semver.satisfies("1.9.9", "^1.2.3"))
	test.falsy(semver.satisfies("1.2.2", "^1.2.3"))
	test.falsy(semver.satisfies("2.0.0", "^1.2.3"))

	test.truthy(semver.satisfies("0.2.9", "^0.2.3"))
	test.falsy(semver.satisfies("0.3.0", "^0.2.3"))

	test.truthy(semver.satisfies("0.0.3", "^0.0.3"))
	test.falsy(semver.satisfies("0.0.4", "^0.0.3"))

	test.truthy(semver.satisfies("0.0.5", "^0.0"))
	test.falsy(semver.satisfies("0.1.0", "^0.0"))
	test.truthy(semver.satisfies("0.9.0", "^0"))
	test.falsy(semver.satisfies("1.0.0", "^0"))
end)

test.it("tilde allows patch-only changes", function()
	test.truthy(semver.satisfies("1.2.9", "~1.2.3"))
	test.falsy(semver.satisfies("1.3.0", "~1.2.3"))
	test.falsy(semver.satisfies("1.2.2", "~1.2.3"))

	test.truthy(semver.satisfies("1.2.9", "~1.2"))
	test.falsy(semver.satisfies("1.3.0", "~1.2"))

	test.truthy(semver.satisfies("1.9.0", "~1"))
	test.falsy(semver.satisfies("2.0.0", "~1"))

	test.truthy(semver.satisfies("1.2.9", "~>1.2"), "~> is the LuaRocks spelling of ~")
end)

--
-- compound constraints
--

test.it("space or comma joined comparators are AND", function()
	test.truthy(semver.satisfies("1.5.0", ">=1.2 <2"))
	test.falsy(semver.satisfies("2.0.0", ">=1.2 <2"))
	test.falsy(semver.satisfies("1.1.0", ">=1.2 <2"))
	test.truthy(semver.satisfies("1.2.9", ">=1.2, <1.3"))
	test.falsy(semver.satisfies("1.3.0", ">=1.2, <1.3"))
end)

test.it("|| alternatives are OR", function()
	test.truthy(semver.satisfies("1.2.5", "^1.2 || ^2"))
	test.truthy(semver.satisfies("2.5.0", "^1.2 || ^2"))
	test.falsy(semver.satisfies("3.0.0", "^1.2 || ^2"))
	test.falsy(semver.satisfies("1.1.0", "^1.2 || ^2"))
end)

test.it("a malformed constraint satisfies nothing", function()
	test.falsy(semver.satisfies("1.0.0", "banana"))
	test.falsy(semver.satisfies("1.0.0", "~1.0.0 || banana"))
	test.falsy(semver.satisfies("1.0.0", "!1.0.0"))
end)

--
-- maxSatisfying
--

test.it("maxSatisfying picks the highest matching version", function()
	local versions = { ["0.1.0"] = "a", ["0.1.3"] = "b", ["0.2.0"] = "c", ["1.0.0"] = "d" }
	test.equal(semver.maxSatisfying(versions, "0.1"), "0.1.3")
	test.equal(semver.maxSatisfying(versions, "^0.1 || ^0.2"), "0.2.0")
	test.equal(semver.maxSatisfying(versions, ">=0.1 <2"), "1.0.0", "ignores non-matching candidates")
	test.equal(semver.maxSatisfying(versions, "1.0.0"), "1.0.0", "an exact pin resolves to itself")
	test.equal(semver.maxSatisfying(versions, "*"), "1.0.0")
end)

test.it("maxSatisfying returns nil when nothing matches", function()
	local versions = { ["0.1.0"] = "a", ["0.2.0"] = "b" }
	test.equal(semver.maxSatisfying(versions, "0.5"), nil)
	test.equal(semver.maxSatisfying(versions, "banana"), nil)
	test.equal(semver.maxSatisfying(nil, "0.1"), nil, "a portfile without versions matches nothing")
end)
