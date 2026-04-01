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

test.it("getSrcUrls returns src urls", function()
	local m = Manifest.new(MANIFEST)
	local urls, err = luarocks.getSrcUrls(m, "luafilesystem")
	test.equal(err, nil)
	test.truthy(urls["1.8.0-1"])
	test.truthy(urls["1.8.0-1"]:find("luafilesystem-1.8.0-1.src.rock", 1, true))
end)

test.it("getSrcUrls excludes rockspec-only versions", function()
	local m = Manifest.new(MANIFEST)
	local urls, err = luarocks.getSrcUrls(m, "luafilesystem")
	test.equal(err, nil)
	-- 1.7.0-2 only has rockspec, should not appear
	test.equal(urls["1.7.0-2"], nil)
end)

test.it("getSrcUrls returns nil for package with no src entries", function()
	local m = Manifest.new(MANIFEST)
	-- luafilesystem 1.7.0-2 only has rockspec, but we need a package with NO src at all
	-- use a custom manifest snippet
	local noSrcManifest = luarocks.Manifest.new([[
repository = {
   nosrcpkg = {
      ["1.0.0-1"] = { { arch = "rockspec" } }
   }
}
]])
	local urls, err = luarocks.getSrcUrls(noSrcManifest, "nosrcpkg")
	test.equal(urls, nil)
	test.truthy(err)
end)

test.it("getSrcUrl picks latest src version", function()
	local m = Manifest.new(MANIFEST)
	local url, err = luarocks.getSrcUrl(m, "luasystem")
	test.equal(err, nil)
	test.truthy(url:find("luasystem-0.5.0-1.src.rock", 1, true))
end)

test.it("getEntries returns all entries for a package", function()
	local m = Manifest.new(MANIFEST)
	local entries, err = luarocks.getEntries(m, "luafilesystem")
	test.equal(err, nil)
	test.truthy(entries["1.8.0-1"])
	test.equal(#entries["1.8.0-1"], 2)
end)

test.it("getEntries returns nil for unknown package", function()
	local m = Manifest.new(MANIFEST)
	local entries, err = luarocks.getEntries(m, "doesnotexist")
	test.equal(entries, nil)
	test.truthy(err)
end)

test.it("getUrl prefers src over rockspec", function()
	local m = Manifest.new(MANIFEST)
	local url, arch, err = luarocks.getUrl(m, "luafilesystem")
	test.equal(err, nil)
	test.equal(arch, "src")
	test.truthy(url:find(".src.rock", 1, true))
end)

test.it("getUrl falls back to rockspec when no src available", function()
	local m = Manifest.new(MANIFEST)
	local url, arch, err = luarocks.getUrl(m, "luafilesystem", "1.7.0-2")
	test.equal(err, nil)
	test.equal(arch, "rockspec")
	test.truthy(url:find(".rockspec", 1, true))
end)

test.it("getUrl returns src for src-only package", function()
	local m = Manifest.new(MANIFEST)
	local url, arch, err = luarocks.getUrl(m, "some-pkg")
	test.equal(err, nil)
	test.equal(arch, "src")
	test.truthy(url:find("some-pkg-1.0.0-1.src.rock", 1, true))
end)

-- Regression: getUrl must pick the LATEST version first, then prefer src within that version.
-- Previously it would find the latest src version independently, returning an old version
-- even when a newer version existed with only a rockspec.
test.it("getUrl picks latest version even if older version has src", function()
	local m = Manifest.new([[
repository = {
   mypkg = {
      ["2.0.0-1"] = { { arch = "rockspec" } },
      ["1.0.0-1"] = { { arch = "rockspec" }, { arch = "src" } }
   }
}
]])
	local url, arch, err = luarocks.getUrl(m, "mypkg")
	test.equal(err, nil)
	-- Must use 2.0.0-1 (latest), not 1.0.0-1 (has src but older)
	test.truthy(url:find("mypkg-2.0.0-1", 1, true))
	test.equal(arch, "rockspec")
end)

test.it("getUrl prefers src when latest version has both src and rockspec", function()
	local m = Manifest.new([[
repository = {
   mypkg = {
      ["2.0.0-1"] = { { arch = "rockspec" }, { arch = "src" } },
      ["1.0.0-1"] = { { arch = "rockspec" } }
   }
}
]])
	local url, arch, err = luarocks.getUrl(m, "mypkg")
	test.equal(err, nil)
	test.truthy(url:find("mypkg-2.0.0-1.src.rock", 1, true))
	test.equal(arch, "src")
end)
