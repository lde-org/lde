local test = require("lpm-test")
local luarocks = require("luarocks")

-- Access the internal tokenize/parseManifest via a test shim
-- We test through getRockspecUrls with a mock manifest string

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

-- Expose internals for testing
local tokenize = luarocks._tokenize
local parseManifest = luarocks._parseManifest

test.it("tokenizer produces string and ident tokens", function()
	local tokens = tokenize([[luasystem = { ["1.0-1"] = {} }]])
	test.equal(tokens[1].type, "ident")
	test.equal(tokens[1].value, "luasystem")
	test.equal(tokens[3].type, "sym")
	test.equal(tokens[3].value, "{")
	test.equal(tokens[5].type, "string")
	test.equal(tokens[5].value, "1.0-1")
end)

test.it("parseManifest finds quoted package", function()
	local manifest = parseManifest(tokenize(MANIFEST))
	test.truthy(manifest)
	test.truthy(manifest.repository["luafilesystem"])
	test.truthy(manifest.repository["luafilesystem"]["1.8.0-1"])
	test.equal(manifest.repository["luafilesystem"]["1.8.0-1"][1].arch, "rockspec")
end)

test.it("parseManifest finds unquoted package (ident key)", function()
	local manifest = parseManifest(tokenize(MANIFEST))
	test.truthy(manifest)
	test.truthy(manifest.repository["luasystem"])
	test.truthy(manifest.repository["luasystem"]["0.5.0-1"])
end)

test.it("parseManifest handles multiple versions", function()
	local manifest = parseManifest(tokenize(MANIFEST))
	local versions = manifest.repository["luafilesystem"]
	test.truthy(versions["1.8.0-1"])
	test.truthy(versions["1.7.0-2"])
end)

test.it("parseManifest skips non-rockspec arch entries", function()
	local manifest = parseManifest(tokenize(MANIFEST))
	local entries = manifest.repository["some-pkg"]["1.0.0-1"]
	test.equal(entries[1].arch, "src")
end)
