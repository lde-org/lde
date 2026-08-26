-- Tests for the git shorthand expansion (lde.util.gitShorthand): gh:/github:/
-- gitlab:/codeberg: prefixes that expand to clone URLs in CLI name positions,
-- including the gh:<pkg>@owner/repo monorepo form.
local test = require("lde-test")

local gitShorthand = require("lde.util.gitShorthand")

test.it("gh: and github: expand to github.com URLs", function()
	test.equal(gitShorthand.expand("gh:foo/bar"), "https://github.com/foo/bar")
	test.equal(gitShorthand.expand("github:foo/bar"), "https://github.com/foo/bar")
end)

test.it("gitlab: and codeberg: expand to their hosts", function()
	test.equal(gitShorthand.expand("gitlab:foo/bar"), "https://gitlab.com/foo/bar")
	test.equal(gitShorthand.expand("codeberg:foo/bar"), "https://codeberg.org/foo/bar")
end)

test.it("a trailing .git is preserved", function()
	test.equal(gitShorthand.expand("gh:foo/bar.git"), "https://github.com/foo/bar.git")
end)

test.it("the plain owner/repo form has no sub-package", function()
	local url, sub = gitShorthand.expand("gh:foo/bar")
	test.equal(url, "https://github.com/foo/bar")
	test.falsy(sub)
end)

test.it("the @ form expands to the repo URL and returns the sub-package", function()
	local url, sub = gitShorthand.expand("gh:triangle@codebycruz/hood")
	test.equal(url, "https://github.com/codebycruz/hood")
	test.equal(sub, "triangle")

	local url2, sub2 = gitShorthand.expand("gitlab:fmt@foo/bar")
	test.equal(url2, "https://gitlab.com/foo/bar")
	test.equal(sub2, "fmt")

	-- A namespaced sub-package name is allowed.
	local url3, sub3 = gitShorthand.expand("gh:ns/pkg@owner/repo")
	test.equal(url3, "https://github.com/owner/repo")
	test.equal(sub3, "ns/pkg")
end)

test.it("malformed shorthands return an error, not a URL", function()
	local url, sub, err = gitShorthand.expand("gh:foo")
	test.falsy(url)
	test.falsy(sub)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "Invalid git shorthand")

	local url2, _, err2 = gitShorthand.expand("gh:foo/bar@1.0.0")
	test.falsy(url2)
	test.truthy(err2) ---@cast err2 -nil
	test.includes(err2, "Invalid git shorthand")

	local url3, _, err3 = gitShorthand.expand("gh:foo@bar")
	test.falsy(url3)
	test.truthy(err3) ---@cast err3 -nil
	test.includes(err3, "Invalid git shorthand")

	local url4, _, err4 = gitShorthand.expand("gh:foo/bar/baz")
	test.falsy(url4)
	test.truthy(err4) ---@cast err4 -nil
	test.includes(err4, "Invalid git shorthand")

	local url5, _, err5 = gitShorthand.expand("gh:")
	test.falsy(url5)
	test.truthy(err5) ---@cast err5 -nil
	test.includes(err5, "Invalid git shorthand")
end)

test.it("non-shorthand names are not expanded", function()
	local url, sub, err = gitShorthand.expand("foo")
	test.falsy(url)
	test.falsy(sub)
	test.falsy(err)
	test.falsy(gitShorthand.expand("ns/name"))
	test.falsy(gitShorthand.expand("rocks:lpeg"))
	test.falsy(gitShorthand.expand("foo/bar"))
end)
