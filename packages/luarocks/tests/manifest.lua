local test = require("lde-test")
local luarocks = require("luarocks")
local Manifest = luarocks.Manifest

local MANIFEST = [[
modules = {}
commands = {}
repository = {
   ["luafilesystem"] = {
      ["1.8.0-1"] = {
         {
            arch = "rockspec"
         }, {
            arch = "src"
         }
      },
      ["1.7.0-2"] = {
         {
            arch = "rockspec"
         }
      }
   },
   luasystem = {
      ["0.4.5-1"] = {
         {
            arch = "rockspec"
         }, {
            arch = "src"
         }
      },
      ["0.5.0-1"] = {
         {
            arch = "rockspec"
         }, {
            arch = "src"
         }
      }
   },
   ["some-pkg"] = {
      ["1.0.0-1"] = {
         {
            arch = "src"
         }
      }
   }
}
]]

test.it("finds quoted package", function()
	local m = Manifest.new(MANIFEST)
	local versions = m:package("luafilesystem")
	test.truthy(versions)
	test.truthy(versions["1.8.0-1"])
	test.equal(versions["1.8.0-1"][1].arch, "rockspec")
end)

test.it("finds unquoted package (ident key)", function()
	local m = Manifest.new(MANIFEST)
	local versions = m:package("luasystem")
	test.truthy(versions)
	test.truthy(versions["0.5.0-1"])
end)

test.it("returns all versions for a package", function()
	local m = Manifest.new(MANIFEST)
	local versions = m:package("luafilesystem")
	test.truthy(versions["1.8.0-1"])
	test.truthy(versions["1.7.0-2"])
end)

test.it("returns multiple arch entries per version", function()
	local m = Manifest.new(MANIFEST)
	local versions = m:package("luafilesystem")
	local entries = versions["1.8.0-1"]
	test.equal(entries[1].arch, "rockspec")
	test.equal(entries[2].arch, "src")
end)

test.it("returns nil for unknown package", function()
	local m = Manifest.new(MANIFEST)
	test.equal(m:package("doesnotexist"), nil)
end)

test.it("handles non-rockspec only entries", function()
	local m = Manifest.new(MANIFEST)
	local versions = m:package("some-pkg")
	test.equal(versions["1.0.0-1"][1].arch, "src")
end)

test.it("getRockspecUrls returns rockspec urls", function()
	local m = Manifest.new(MANIFEST)
	local urls, err = luarocks.getRockspecUrls(m, "luafilesystem")
	test.equal(err, nil)
	test.truthy(urls["1.8.0-1"])
	test.truthy(urls["1.7.0-2"])
end)

test.it("getRockspecUrls excludes non-rockspec-only versions", function()
	local m = Manifest.new(MANIFEST)
	local urls = luarocks.getRockspecUrls(m, "some-pkg")
	-- some-pkg 1.0.0-1 only has arch=src, no rockspec entry
	test.equal(urls, nil)
end)

test.it("getRockspecUrl picks latest when no constraint", function()
	local m = Manifest.new(MANIFEST)
	local url, err = luarocks.getRockspecUrl(m, "luafilesystem")
	test.equal(err, nil)
	test.truthy(url:find("luafilesystem-1.8.0-1.rockspec", 1, true))
end)

test.it("getRockspecUrl returns nil for unknown package", function()
	local m = Manifest.new(MANIFEST)
	local url, err = luarocks.getRockspecUrl(m, "doesnotexist")
	test.equal(url, nil)
	test.truthy(err)
end)
