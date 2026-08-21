local test = require("lde-test")

local lde = require("lde-core")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")
local util = require("util")

local tmpBase = path.join(env.tmpdir(), "lde-build-tests")

-- Clean up from any previous test run
fs.rmdir(tmpBase)

--- Creates a package with src directory and source files.
---@param name string # package name, used as the directory name under tmpBase
---@param srcFiles table<string, string> # relative path -> file content
---@param config table? # lde.json contents; defaults to a minimal manifest
---@return string # package directory
local function makePackageWithSrc(name, srcFiles, config)
	fs.mkdir(tmpBase)
	local dir = path.join(tmpBase, name)
	fs.mkdir(dir)

	config = config or {
		name = name,
		version = "0.1.0",
		dependencies = {}
	}

	fs.write(path.join(dir, "lde.json"), json.encode(config))

	local srcDir = path.join(dir, "src")
	fs.mkdir(srcDir)
	fs.mkdir(path.join(dir, "target"))

	for filename, content in pairs(srcFiles) do
		fs.write(path.join(srcDir, filename), content)
	end

	return dir
end

--
-- Package:build (symlink-based, no build script)
--

test.it("Package:build creates a symlink in target/<name>", function()
	local dir = makePackageWithSrc("build-basic", {
		["init.lua"] = 'return "hello"'
	})

	local pkg = assert(lde.Package.open(dir))
	pkg:build()

	local targetDir = pkg:getTargetDir()
	test.truthy(fs.exists(targetDir))
end)

test.it("Package:build target contains the source files", function()
	local dir = makePackageWithSrc("build-contents", {
		["init.lua"] = 'return { version = "1.0" }',
		["helper.lua"] = 'return {}'
	})

	local pkg = assert(lde.Package.open(dir))
	pkg:build()

	local targetDir = pkg:getTargetDir()
	test.truthy(fs.exists(path.join(targetDir, "init.lua")))
	test.truthy(fs.exists(path.join(targetDir, "helper.lua")))
end)

test.it("Package:build is idempotent (can be called twice)", function()
	local dir = makePackageWithSrc("build-idempotent", {
		["init.lua"] = 'return true'
	})

	local pkg = assert(lde.Package.open(dir))
	pkg:build()
	pkg:build()

	test.truthy(fs.exists(pkg:getTargetDir()))
end)

--
-- Package:build input invalidation (build.lua packages)
--

test.it("build script is skipped when src/, lde.json, and build.lua are unchanged", function()
	local dir = makePackageWithSrc("build-skip-unchanged", {
		["init.lua"] = 'return 1'
	})

	-- Each run appends a marker; if the script were re-run the marker would grow.
	fs.write(path.join(dir, "build.lua"), [[
local f = assert(io.open("build-count.txt", "a"))
f:write("x")
f:close()
]])

	local pkg = assert(lde.Package.open(dir))
	pkg:build()
	pkg:build()
	pkg:build()

	test.equal(fs.read(path.join(dir, "build-count.txt")), "x")
	-- the stamp records the input state inside the output dir
	test.truthy(fs.exists(path.join(dir, "target", pkg:getName(), ".lde-build-stamp")))
end)

test.it("build script is re-run when a src file changes", function()
	local dir = makePackageWithSrc("build-rerun-src", {
		["init.lua"] = 'return 1'
	})

	fs.write(path.join(dir, "build.lua"), [[
local f = assert(io.open("build-count-src.txt", "a"))
f:write("x")
f:close()
]])

	local pkg = assert(lde.Package.open(dir))
	pkg:build()
	-- Different size so the mtime/size fast path can't mask the change.
	fs.write(path.join(dir, "src", "init.lua"), 'return 123456')
	pkg:build()

	test.equal(fs.read(path.join(dir, "build-count-src.txt")), "xx")
end)

test.it("build script is re-run when lde.json changes", function()
	local dir = makePackageWithSrc("build-rerun-config", {
		["init.lua"] = 'return 1'
	})

	fs.write(path.join(dir, "build.lua"), [[
local f = assert(io.open("build-count-config.txt", "a"))
f:write("x")
f:close()
]])

	local pkg = assert(lde.Package.open(dir))
	pkg:build()

	-- Rewrite with a clearly larger config so the mtime/size fast path can't mask it.
	fs.write(path.join(dir, "lde.json"), json.encode({
		name        = "build-rerun-config",
		version     = "0.20.0",
		description = "a longer config to change the file size",
		dependencies = {}
	}))
	pkg:build()

	test.equal(fs.read(path.join(dir, "build-count-config.txt")), "xx")
end)

test.it("build script is re-run when build.lua itself changes", function()
	local dir = makePackageWithSrc("build-rerun-script", {
		["init.lua"] = 'return 1'
	})

	fs.write(path.join(dir, "build.lua"), [[
local f = assert(io.open("build-count-script.txt", "a"))
f:write("x")
f:close()
]])

	local pkg = assert(lde.Package.open(dir))
	pkg:build()

	-- Longer script: changes the size so the mtime/size fast path can't mask it.
	fs.write(path.join(dir, "build.lua"), [[
local f = assert(io.open("build-count-script.txt", "a"))
f:write("y")
f:close()
-- extra line to change the file size
]])
	pkg:build()

	test.equal(fs.read(path.join(dir, "build-count-script.txt")), "xy")
end)

--
-- Package:installDependencies with path dependencies
--

test.it("installDependencies installs a local path dependency", function()
	local depDir = makePackageWithSrc("install-dep", {
		["init.lua"] = 'return { name = "install-dep" }'
	})

	local mainDir = path.join(tmpBase, "install-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')

	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "install-main",
		version = "0.1.0",
		dependencies = {
			["install-dep"] = { path = "../install-dep" }
		}
	}))

	local pkg = assert(lde.Package.open(mainDir))
	pkg:installDependencies()

	local depInTarget = path.join(mainDir, "target", "install-dep")
	test.truthy(fs.exists(depInTarget))
	test.truthy(fs.exists(path.join(depInTarget, "init.lua")))
end)

test.it("installDependencies installs multiple dependencies", function()
	makePackageWithSrc("multi-dep-a", {
		["init.lua"] = 'return "a"'
	})

	makePackageWithSrc("multi-dep-b", {
		["init.lua"] = 'return "b"'
	})

	local mainDir = path.join(tmpBase, "multi-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')

	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "multi-main",
		version = "0.1.0",
		dependencies = {
			["multi-dep-a"] = { path = "../multi-dep-a" },
			["multi-dep-b"] = { path = "../multi-dep-b" }
		}
	}))

	local pkg = assert(lde.Package.open(mainDir))
	pkg:installDependencies()

	test.truthy(fs.exists(path.join(mainDir, "target", "multi-dep-a", "init.lua")))
	test.truthy(fs.exists(path.join(mainDir, "target", "multi-dep-b", "init.lua")))
end)

	test.it("installDependencies skips already-installed symlink dependencies", function()
	makePackageWithSrc("skip-dep", {
		["init.lua"] = 'return "skip"'
	})

	local mainDir = path.join(tmpBase, "skip-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')

	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "skip-main",
		version = "0.1.0",
		dependencies = {
			["skip-dep"] = { path = "../skip-dep" }
		}
	}))

	local pkg = assert(lde.Package.open(mainDir))
	pkg:installDependencies()
	pkg:installDependencies()

	test.truthy(fs.exists(path.join(mainDir, "target", "skip-dep")))
end)

test.it("installDependencies re-installs when the dep is missing from target/", function()
	makePackageWithSrc("wipe-dep", {
		["init.lua"] = 'return "wipe"'
	})

	local mainDir = path.join(tmpBase, "wipe-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')

	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "wipe-main",
		version = "0.1.0",
		dependencies = {
			["wipe-dep"] = { path = "../wipe-dep" }
		}
	}))

	local pkg = assert(lde.Package.open(mainDir))
	pkg:installDependencies()

	-- Simulate wiped materialization (e.g. the git cache was deleted, taking
	-- the symlink target with it): drop the dep from target/ entirely.
	fs.rmdir(path.join(mainDir, "target", "wipe-dep"))

	-- The .installed marker still matches the lockfile, but the install must
	-- not be treated as a no-op — the dep has to come back.
	local result = pkg:installDependencies()
	test.falsy(result.isCached)
	test.equal(fs.read(path.join(mainDir, "target", "wipe-dep", "init.lua")), 'return "wipe"')
end)

test.it("installDependencies re-installs when a dep symlink is dangling", function()
	local depDir = makePackageWithSrc("dangling-dep", {
		["init.lua"] = 'return "dangling"'
	})

	local mainDir = path.join(tmpBase, "dangling-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')

	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "dangling-main",
		version = "0.1.0",
		dependencies = {
			["dangling-dep"] = { path = "../dangling-dep" }
		}
	}))

	local pkg = assert(lde.Package.open(mainDir))
	pkg:installDependencies()
	test.truthy(fs.islink(path.join(mainDir, "target", "dangling-dep")))

	-- Wipe the symlink's target out from under it, like deleting the git cache
	-- dirs in ~/.lde/git: the link itself is still there but nothing resolves.
	-- The .installed marker hash still matches, so without the integrity check
	-- this would be a silent no-op and require() would fail at runtime.
	fs.rmdir(depDir)
	local ok, err = pcall(function() pkg:installDependencies() end)
	if ok then error("install should not treat a dangling dep as installed") end
	test.includes(tostring(err), "dangling-dep")

	-- Restoring the source lets the next install recover cleanly.
	fs.mkdir(depDir)
	fs.mkdir(path.join(depDir, "src"))
	fs.write(path.join(depDir, "lde.json"), json.encode({
		name = "dangling-dep",
		version = "0.1.0",
		dependencies = {}
	}))
	fs.write(path.join(depDir, "src", "init.lua"), 'return "dangling"')
	pkg:installDependencies()
	test.equal(fs.read(path.join(mainDir, "target", "dangling-dep", "init.lua")), 'return "dangling"')
end)

--
-- installDependencies: build.lua input invalidation for path deps
--

--- A path dep whose build.lua appends to a marker file in the dep dir, so
--- tests can count how many times the build actually ran.
---@param name string
---@param marker string
---@return string depDir
local function makeBuildScriptDep(name, marker)
	local depDir = makePackageWithSrc(name, {
		["init.lua"] = 'return "' .. name .. '"'
	})
	fs.write(path.join(depDir, "build.lua"), string.format([[
local f = assert(io.open("%s", "a"))
f:write("x")
f:close()
]], marker))
	return depDir
end

--- An app that depends on a path dep by name.
---@param name string
---@param depName string
---@return lde.Package
local function makeAppWithDep(name, depName)
	local mainDir = path.join(tmpBase, name)
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')
	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = name,
		version = "0.1.0",
		dependencies = {
			[depName] = { path = "../" .. depName }
		}
	}))
	local pkg, err = lde.Package.open(mainDir)
	assert(pkg, "open failed: " .. tostring(err))
	return pkg
end

test.it("installDependencies skips a path dep's build.lua while its inputs are unchanged", function()
	makeBuildScriptDep("install-skip-dep", "install-skip-count.txt")
	local pkg = makeAppWithDep("install-skip-main", "install-skip-dep")

	pkg:installDependencies()
	test.equal(fs.read(path.join(tmpBase, "install-skip-dep", "install-skip-count.txt")), "x")

	-- locked = true forces the full walk (bypassing the .installed fast path) so
	-- the stamp check itself is exercised, not just the root marker.
	pkg:installDependencies(nil, nil, nil, { isLocked = true })
	test.equal(fs.read(path.join(tmpBase, "install-skip-dep", "install-skip-count.txt")), "x",
		"dep build.lua must not re-run while its inputs are unchanged")
end)

test.it("installDependencies re-runs a path dep's build.lua when its src changes", function()
	local depDir = makeBuildScriptDep("install-src-dep", "install-src-count.txt")
	local pkg = makeAppWithDep("install-src-main", "install-src-dep")

	pkg:installDependencies()
	test.equal(fs.read(path.join(depDir, "install-src-count.txt")), "x")

	-- Different size so the mtime/size fast path can't mask the change.
	fs.write(path.join(depDir, "src", "init.lua"), 'return 123456')
	pkg:installDependencies(nil, nil, nil, { isLocked = true })
	test.equal(fs.read(path.join(depDir, "install-src-count.txt")), "xx",
		"dep build.lua must re-run when the dep's source changed")
end)

test.it("installDependencies re-runs a path dep's build.lua when its build.lua changes", function()
	local depDir = makeBuildScriptDep("install-script-dep", "install-script-count.txt")
	local pkg = makeAppWithDep("install-script-main", "install-script-dep")

	pkg:installDependencies()
	test.equal(fs.read(path.join(depDir, "install-script-count.txt")), "x")

	fs.write(path.join(depDir, "build.lua"), string.format([[
local f = assert(io.open("%s", "a"))
f:write("y")
f:close()
-- extra line to change the file size
]], "install-script-count.txt"))
	pkg:installDependencies(nil, nil, nil, { isLocked = true })
	test.equal(fs.read(path.join(depDir, "install-script-count.txt")), "xy",
		"dep build.lua must re-run when the dep's build.lua changed")
end)

test.it("installDependencies fast path detects a stale path dep build (src change invalidates the cache)", function()
	local depDir = makeBuildScriptDep("install-stale-dep", "install-stale-count.txt")
	local pkg = makeAppWithDep("install-stale-main", "install-stale-dep")

	pkg:installDependencies()
	test.equal(fs.read(path.join(depDir, "install-stale-count.txt")), "x")

	-- Unchanged: the fast path reports cached.
	local isCached = pkg:installDependencies()
	test.truthy(isCached.isCached)
	test.equal(fs.read(path.join(depDir, "install-stale-count.txt")), "x")

	-- The root lockfile/manifest didn't change, but the dep's source did: the
	-- .installed marker alone can't see it, so the fast path must fall back to
	-- a full install that re-runs the dep's build.
	fs.write(path.join(depDir, "src", "init.lua"), 'return 123456789')
	local stale = pkg:installDependencies()
	test.falsy(stale.isCached, "install must not report cached when a dep build is stale")
	test.equal(fs.read(path.join(depDir, "install-stale-count.txt")), "xx",
		"dep build.lua must re-run when its source changed")
end)

--
-- installDependencies: rockspec path dep rebuild stamping
--

test.it("installDependencies skips a rockspec dep's rebuild while its rockspec is unchanged", function()
	local rockDir = path.join(tmpBase, "rockspec-stamp")
	fs.mkdir(rockDir)
	fs.mkdir(path.join(rockDir, "src"))
	fs.write(path.join(rockDir, "src", "init.lua"), 'return "v1"')
	fs.write(path.join(rockDir, "rockspec-stamp-1.0-1.rockspec"), [[
package = "rockspec-stamp"
version = "1.0-1"
source = { url = "https://example.com" }
build = { type = "builtin", modules = { ["rockspec-stamp"] = "src/init.lua" } }
]])

	local pkg = makeAppWithDep("rockspec-stamp-main", "rockspec-stamp")
	pkg:installDependencies()
	test.truthy(fs.exists(path.join(pkg:getModulesDir(), "rockspec-stamp", ".lde-built")))

	-- Rewrite the rock's source: the stamp keys on the rockspec content, not the
	-- sources (a published rock is immutable), so the copy must NOT be refreshed.
	fs.write(path.join(rockDir, "src", "init.lua"), 'return "v2"')
	pkg:installDependencies(nil, nil, nil, { isLocked = true })
	local copied = fs.read(path.join(pkg:getModulesDir(), "rockspec-stamp", "init.lua")) ---@cast copied -nil
	test.includes(copied, "v1")
	test.falsy(copied:find("v2", 1, true))
end)

test.it("installDependencies rebuilds a rockspec dep when the rockspec changes", function()
	local rockDir = path.join(tmpBase, "rockspec-change")
	fs.mkdir(rockDir)
	fs.mkdir(path.join(rockDir, "src"))
	fs.write(path.join(rockDir, "src", "init.lua"), 'return "base"')
	fs.write(path.join(rockDir, "src", "extra.lua"), 'return "extra"')
	fs.write(path.join(rockDir, "rockspec-change-1.0-1.rockspec"), [[
package = "rockspec-change"
version = "1.0-1"
source = { url = "https://example.com" }
build = { type = "builtin", modules = { ["rockspec-change"] = "src/init.lua" } }
]])

	local pkg = makeAppWithDep("rockspec-change-main", "rockspec-change")
	pkg:installDependencies()
	test.truthy(fs.exists(path.join(pkg:getModulesDir(), "rockspec-change", "init.lua")))
	test.falsy(fs.exists(path.join(pkg:getModulesDir(), "rockspec-change", "extra.lua")))

	-- Adding a module to the rockspec changes its content, so the buildfn stamp
	-- no longer matches and the build must re-run, copying the new module.
	fs.write(path.join(rockDir, "rockspec-change-1.0-1.rockspec"), [[
package = "rockspec-change"
version = "1.0-1"
source = { url = "https://example.com" }
build = { type = "builtin", modules = {
  ["rockspec-change"] = "src/init.lua",
  ["rockspec-change.extra"] = "src/extra.lua",
} }
]])
	pkg:installDependencies(nil, nil, nil, { isLocked = true })
	test.truthy(fs.exists(path.join(pkg:getModulesDir(), "rockspec-change", "extra.lua")),
		"rockspec change must invalidate the .lde-built stamp and rebuild")
end)

--
-- installDependencies --locked (lockfile-only installs)
--

test.it("locked install fails when a git dep is not pinned in the lockfile", function()
	local mainDir = path.join(tmpBase, "locked-unpinned")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')

	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "locked-unpinned",
		version = "0.1.0",
		dependencies = {
			foo = { git = "https://example.invalid/foo" }
		}
	}))

	local pkg = assert(lde.Package.open(mainDir))
	local ok, err = pcall(function()
		pkg:installDependencies(nil, nil, nil, { isLocked = true })
	end)
	test.falsy(ok)
	test.includes(tostring(err), "not pinned")
end)

test.it("locked install allows path deps without lockfile pins", function()
	makePackageWithSrc("locked-path-dep", {
		["init.lua"] = 'return "locked-path-dep"'
	})

	local mainDir = path.join(tmpBase, "locked-path-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')
	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "locked-path-main",
		version = "0.1.0",
		dependencies = {
			["locked-path-dep"] = { path = "../locked-path-dep" }
		}
	}))

	local pkg = assert(lde.Package.open(mainDir))
	local result = pkg:installDependencies(nil, nil, nil, { isLocked = true })
	test.truthy(fs.exists(path.join(mainDir, "target", "locked-path-dep")))
	test.falsy(result.hasChanged)
	test.equal(result.installs, 1)
	test.equal(result.checked, 1)
end)

test.it("installDevDependencies pins dev deps into the lockfile", function()
	makePackageWithSrc("dev-pinned-dep", {
		["init.lua"] = 'return "dev-pinned-dep"'
	})
	makePackageWithSrc("dev-pinned-runtime", {
		["init.lua"] = 'return "dev-pinned-runtime"'
	})

	local mainDir = path.join(tmpBase, "dev-pinned-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')
	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "dev-pinned-main",
		version = "0.1.0",
		dependencies = {
			["dev-pinned-runtime"] = { path = "../dev-pinned-runtime" }
		},
		devDependencies = {
			["dev-pinned-dep"] = { path = "../dev-pinned-dep" }
		}
	}))

	local pkg = assert(lde.Package.open(mainDir))
	pkg:installDependencies()
	pkg:installDevDependencies()

	local lockfile = pkg:readLockfile()
	test.truthy(lockfile) ---@cast lockfile -nil
	test.truthy(lockfile:getDependency("dev-pinned-dep"), "dev dep should be pinned")
	test.truthy(lockfile:getDependency("dev-pinned-runtime"), "runtime pin should survive the dev commit")
	test.truthy(fs.exists(path.join(mainDir, "target", "dev-pinned-dep")))
	test.truthy(fs.exists(path.join(mainDir, "target", "dev-pinned-runtime")))
end)

--
-- Lockfile
--

test.it("installDependencies writes a lockfile with resolved path dependency", function()
	makePackageWithSrc("lockfile-dep", {
		["init.lua"] = 'return "lockfile-dep"'
	})

	local mainDir = path.join(tmpBase, "lockfile-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')
	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "lockfile-main",
		version = "0.1.0",
		dependencies = {
			["lockfile-dep"] = { path = "../lockfile-dep" }
		}
	}))

	local pkg = assert(lde.Package.open(mainDir))
	pkg:installDependencies()

	local lockPath = path.join(mainDir, "lde.lock")
	test.truthy(fs.exists(lockPath))

	local raw = fs.read(lockPath) ---@cast raw -nil
	local content = json.decode(raw) ---@cast content table
	test.equal(content.version, "1")
	test.equal(content.dependencies["lockfile-dep"].path, "../lockfile-dep")
end)

test.it("installDependencies uses lockfile to pin dependency on reinstall", function()
	makePackageWithSrc("pinned-dep", {
		["init.lua"] = 'return "pinned"'
	})
	makePackageWithSrc("other-dep", {
		["init.lua"] = 'return "other"'
	})

	local mainDir = path.join(tmpBase, "pinned-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')
	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "pinned-main",
		version = "0.1.0",
		dependencies = {
			["pinned-dep"] = { path = "../pinned-dep" }
		}
	}))

	local pkg = assert(lde.Package.open(mainDir))
	pkg:installDependencies()

	-- Manually overwrite the lockfile to point at other-dep instead (keeping the
	-- manifest hash, so the pins stay trustworthy and are applied on reinstall)
	local lockfile = lde.Lockfile.new(path.join(mainDir, "lde.lock"), {
		["pinned-dep"] = { path = "../other-dep" }
	})
	lockfile:setManifestHash(lde.Lockfile.manifestHash(pkg:readConfig()))
	lockfile:save()

	-- Remove the installed symlink/junction so reinstall actually runs
	fs.rmdir(path.join(mainDir, "target", "pinned-dep"))

	-- Reinstall — should use the lockfile's path, getting other-dep's init.lua
	pkg:installDependencies()

	local content = fs.read(path.join(mainDir, "target", "pinned-dep", "init.lua"))
	test.equal(content, 'return "other"')
end)

--
-- Transitive dependencies
--

test.it("installDependencies installs transitive dependencies", function()
	makePackageWithSrc("leaf-dep", {
		["init.lua"] = 'return "leaf"'
	})

	local midDir = path.join(tmpBase, "mid-dep")
	fs.mkdir(midDir)
	fs.mkdir(path.join(midDir, "src"))
	fs.write(path.join(midDir, "src", "init.lua"), 'return require("leaf-dep")')

	fs.write(path.join(midDir, "lde.json"), json.encode({
		name = "mid-dep",
		version = "0.1.0",
		dependencies = {
			["leaf-dep"] = { path = "../leaf-dep" }
		}
	}))

	local rootDir = path.join(tmpBase, "trans-root")
	fs.mkdir(rootDir)
	fs.mkdir(path.join(rootDir, "src"))
	fs.write(path.join(rootDir, "src", "init.lua"), 'return true')

	fs.write(path.join(rootDir, "lde.json"), json.encode({
		name = "trans-root",
		version = "0.1.0",
		dependencies = {
			["mid-dep"] = { path = "../mid-dep" }
		}
	}))

	local pkg = assert(lde.Package.open(rootDir))
	pkg:installDependencies()

	test.truthy(fs.exists(path.join(rootDir, "target", "mid-dep")))
	test.truthy(fs.exists(path.join(rootDir, "target", "leaf-dep")))
end)

--
-- Archive dependencies (URL -> download -> extract -> open)
--

test.it("installDependencies materializes a cached archive dependency", function()
	-- The archive cache dir is keyed by URL; pre-populating it (as if the
	-- download+extract already happened) makes this fully offline while still
	-- exercising the archive dep resolution, lock entry, and build pass.
	local url = "https://example.com/archive-dep-1.0.tar.gz"
	local archiveDir = lde.global.getArchiveDir(url)
	fs.rmdir(archiveDir)
	fs.mkdirAll(archiveDir)
	fs.write(path.join(archiveDir, "lde.json"), json.encode({
		name = "archive-dep",
		version = "0.1.0",
		dependencies = {}
	}))
	fs.mkdir(path.join(archiveDir, "src"))
	fs.write(path.join(archiveDir, "src", "init.lua"), 'return "from-archive"')

	local mainDir = path.join(tmpBase, "archive-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')
	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "archive-main",
		version = "0.1.0",
		dependencies = {
			["archive-dep"] = { archive = url }
		}
	}))

	local pkg = assert(lde.Package.open(mainDir))
	pkg:installDependencies()

	test.truthy(fs.exists(path.join(mainDir, "target", "archive-dep", "init.lua")))
	local lockfile = pkg:readLockfile()
	test.truthy(lockfile) ---@cast lockfile -nil
	local entry = lockfile:getDependency("archive-dep")
	test.truthy(entry) ---@cast entry -nil
	test.equal(entry.archive, url)

	local ok, err = pkg:runString('assert(require("archive-dep") == "from-archive")')
	test.truthy(ok, tostring(err))
end)

test.it("installDependencies treats a wiped archive cache as a fresh install", function()
	-- Same setup as above, but the archive cache dir and the materialized dep
	-- are both deleted afterwards: the next install must not report cached.
	local url = "https://example.com/archive-dep-2.tar.gz"
	local archiveDir = lde.global.getArchiveDir(url)
	fs.rmdir(archiveDir)
	fs.mkdirAll(archiveDir)
	fs.write(path.join(archiveDir, "lde.json"), json.encode({
		name = "archive-dep-2",
		version = "0.1.0",
		dependencies = {}
	}))
	fs.mkdir(path.join(archiveDir, "src"))
	fs.write(path.join(archiveDir, "src", "init.lua"), 'return "v1"')

	local mainDir = path.join(tmpBase, "archive-wipe-main")
	fs.mkdir(mainDir)
	fs.mkdir(path.join(mainDir, "src"))
	fs.write(path.join(mainDir, "src", "init.lua"), 'return true')
	fs.write(path.join(mainDir, "lde.json"), json.encode({
		name = "archive-wipe-main",
		version = "0.1.0",
		dependencies = {
			["archive-dep-2"] = { archive = url }
		}
	}))

	local pkg = assert(lde.Package.open(mainDir))
	pkg:installDependencies()
	test.truthy(fs.exists(path.join(mainDir, "target", "archive-dep-2", "init.lua")))

	-- Wipe the cache dir + the materialized dep, like a user deleting the tar
	-- cache manually: installIsIntact must fall back to a full install. (The
	-- cache is pre-populated again so this stays offline.) Delete the link with
	-- fs.delete: after the cache dir is gone the target link dangles and
	-- fs.rmdir's fs.exists pre-check would no-op on it.
	fs.rmdir(archiveDir)
	fs.delete(path.join(mainDir, "target", "archive-dep-2"))
	fs.mkdirAll(archiveDir)
	fs.mkdir(path.join(archiveDir, "src"))
	fs.write(path.join(archiveDir, "src", "init.lua"), 'return "v1"')
	-- The package metadata must come back too (the cache dir was fully wiped).
	fs.write(path.join(archiveDir, "lde.json"), json.encode({
		name = "archive-dep-2",
		version = "0.1.0",
		dependencies = {}
	}))

	local result = pkg:installDependencies()
	test.falsy(result.isCached, "archive dep must be re-materialized after a cache wipe")
	test.equal(fs.read(path.join(mainDir, "target", "archive-dep-2", "init.lua")), 'return "v1"')
end)

-- Regression: path deps pointing to the same package from different relative starting
-- points must not be treated as conflicts.
test.it("installDependencies does not conflict when two deps reference the same path package differently", function()
	-- shared-dep is referenced by both root (../shared-dep) and mid (../shared-dep, same abs path)
	makePackageWithSrc("shared-dep", { ["init.lua"] = 'return "shared"' })

	-- mid-dep lives one level deeper inside a subdir so its relative path differs
	local midDir = path.join(tmpBase, "conflict-mid")
	fs.mkdir(midDir)
	fs.mkdir(path.join(midDir, "src"))
	fs.write(path.join(midDir, "src", "init.lua"), 'return true')
	fs.write(path.join(midDir, "lde.json"), json.encode({
		name = "conflict-mid",
		version = "0.1.0",
		dependencies = {
			["shared-dep"] = { path = "../shared-dep" }
		}
	}))

	local rootDir = path.join(tmpBase, "conflict-root")
	fs.mkdir(rootDir)
	fs.mkdir(path.join(rootDir, "src"))
	fs.write(path.join(rootDir, "src", "init.lua"), 'return true')
	fs.write(path.join(rootDir, "lde.json"), json.encode({
		name = "conflict-root",
		version = "0.1.0",
		dependencies = {
			["shared-dep"] = { path = "../shared-dep" },
			["conflict-mid"] = { path = "../conflict-mid" }
		}
	}))

	local pkg = assert(lde.Package.open(rootDir))
	-- Should not error
	pkg:installDependencies()

	test.truthy(fs.exists(path.join(rootDir, "target", "shared-dep")))
end)

--
-- Rockspec buildfn: init.lua module mapping regression
--

test.it("rockspec buildfn installs init.lua modules as dir/init.lua not dir.lua", function()
	-- Minimal rockspec with a module that maps to an init.lua (like luacheck.vendor.sha1)
	local rockspecContent = [[
package = "mypkg"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {
    ["mypkg"] = "src/init.lua",
    ["mypkg.sub"] = "src/sub/init.lua",
    ["mypkg.sub.leaf"] = "src/sub/leaf.lua",
  }
}
]]

	local dir = path.join(tmpBase, "rockspec-init-regression")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.mkdir(path.join(dir, "src", "sub"))
	fs.write(path.join(dir, "mypkg-1.0-1.rockspec"), rockspecContent)
	fs.write(path.join(dir, "src", "init.lua"), 'return "mypkg"')
	fs.write(path.join(dir, "src", "sub", "init.lua"), 'return "sub"')
	fs.write(path.join(dir, "src", "sub", "leaf.lua"), 'return "leaf"')

	local pkg = lde.Package.openRockspec(dir)
	test.truthy(pkg) ---@cast pkg -nil

	local outputDir = path.join(dir, "target", "mypkg")
	local ok2, err = pkg:runBuildScript(outputDir)
	test.truthy(ok2, err)

	local modulesDir = path.join(dir, "target")
	-- mypkg -> src/init.lua => should be mypkg/init.lua, NOT mypkg.lua
	test.truthy(fs.exists(path.join(modulesDir, "mypkg", "init.lua")))
	test.equal(fs.exists(path.join(modulesDir, "mypkg.lua")), false)
	-- mypkg.sub -> src/sub/init.lua => mypkg/sub/init.lua
	test.truthy(fs.exists(path.join(modulesDir, "mypkg", "sub", "init.lua")))
	-- mypkg.sub.leaf -> src/sub/leaf.lua => mypkg/sub/leaf.lua
	test.truthy(fs.exists(path.join(modulesDir, "mypkg", "sub", "leaf.lua")))
end)

test.it("rockspec buildfn: module key ending in .init installs as dir/init.lua (luasystem pattern)", function()
	local rockspecContent = [[
package = "mysystem"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {
    ["system.init"] = "system/init.lua",
  }
}
]]

	local dir = path.join(tmpBase, "rockspec-dotinit-regression")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "system"))
	fs.write(path.join(dir, "mysystem-1.0-1.rockspec"), rockspecContent)
	fs.write(path.join(dir, "system", "init.lua"), 'return "system"')

	local pkg = lde.Package.openRockspec(dir)
	test.truthy(pkg) ---@cast pkg -nil

	local outputDir = path.join(dir, "target", "mysystem")
	local ok, err = pkg:runBuildScript(outputDir)
	test.truthy(ok, err)

	local modulesDir = path.join(dir, "target")
	-- system.init -> system/init.lua => should be at target/system/init.lua
	test.truthy(fs.exists(path.join(modulesDir, "system", "init.lua")))
	-- must NOT be at target/system/init/init.lua
	test.equal(fs.exists(path.join(modulesDir, "system", "init", "init.lua")), false)
end)

test.it("rockspec: platform lua modules are not misclassified as native modules", function()
	local platKey = jit.os == "OSX" and "macosx" or jit.os == "Windows" and "win32" or "linux"

	local rockspecContent = string.format([[
package = "mypkg"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {
    ["mypkg.http"] = "src/http.lua",
    ["mypkg.core"] = { sources = { "src/core.c" } },
  },
  platforms = {
    ["%s"] = {
      modules = {
        ["mypkg.extra"] = "src/extra.lua",
        ["mypkg.native"] = { sources = { "src/native.c" } },
      }
    }
  }
}
]], platKey)

	local dir = path.join(tmpBase, "rockspec-module-classify")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "mypkg-1.0-1.rockspec"), rockspecContent)
	fs.write(path.join(dir, "src", "http.lua"), 'return "http"')
	fs.write(path.join(dir, "src", "extra.lua"), 'return "extra"')

	local pkg = lde.Package.openRockspec(dir)
	test.truthy(pkg) ---@cast pkg -nil

	local outputDir = path.join(dir, "target", "mypkg")
	pkg:runBuildScript(outputDir) -- may fail on C compile, that's ok

	local modulesDir = path.join(dir, "target")
	-- lua modules must be copied as .lua files, not passed to gcc
	test.truthy(fs.exists(path.join(modulesDir, "mypkg", "http.lua")))
	test.truthy(fs.exists(path.join(modulesDir, "mypkg", "extra.lua")))
	-- must NOT exist as .so (would mean they were misclassified as native)
	test.equal(fs.exists(path.join(modulesDir, "mypkg", "http.so")), false)
	test.equal(fs.exists(path.join(modulesDir, "mypkg", "extra.so")), false)
end)

--
-- runTests: target/tests setup
--

local testFixture = 'return { magic = 42 }'
local testFile = [[
local t = require("lde-test")
local fixture = require("tests.fixture")
t.it("can require tests.fixture", function()
	t.equal(fixture.magic, 42)
end)
]]

test.it("runTests can require tests.fixture without build script", function()
	local dir = makePackageWithSrc("runtests-symlink", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "fixture.lua"), testFixture)
	fs.write(path.join(testsDir, "main.test.lua"), testFile)

	local pkg = assert(lde.Package.open(dir))
	local results = pkg:runTests()

	test.equal(results.failures, 0)
	test.equal(results.error, nil)
end)

test.it("runTests can require tests.fixture with build script", function()
	local dir = makePackageWithSrc("runtests-copy", { ["init.lua"] = 'return true' })

	local f = io.open(path.join(dir, "build.lua"), "w") ---@cast f -nil
	f:write('local f = io.open(os.getenv("LDE_OUTPUT_DIR") .. "/init.lua", "w"); f:write("return true"); f:close()')
	f:close()

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "fixture.lua"), testFixture)
	fs.write(path.join(testsDir, "main.test.lua"), testFile)

	local pkg = assert(lde.Package.open(dir))
	local results = pkg:runTests()

	test.equal(results.failures, 0)
	test.equal(results.error, nil)
end)

-- Package with a build.lua so target/tests is a copy (stamped sync) rather
-- than a symlink.
---@param name string
---@return string dir
local function makeBuildScriptPackage(name)
	local dir = makePackageWithSrc(name, { ["init.lua"] = 'return true' })
	fs.write(path.join(dir, "build.lua"), [[
local f = io.open(os.getenv("LDE_OUTPUT_DIR") .. "/init.lua", "w")
f:write("return true")
f:close()
]])
	return dir
end

---@param dir string
---@param file string
---@return string
local function targetTestsFile(dir, file)
	return path.join(dir, "target", "tests", file)
end

test.it("runTests refreshes target/tests copy when a test helper changes", function()
	local dir = makeBuildScriptPackage("runtests-stamp-change")

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "fixture.lua"), 'return { magic = 42 }')
	fs.write(path.join(testsDir, "main.test.lua"), [[
local t = require("lde-test")
local fixture = require("tests.fixture")
t.it("fixture works", function()
	t.truthy(fixture.magic)
end)
]])

	local pkg = assert(lde.Package.open(dir))
	test.equal(pkg:runTests().failures, 0)

	-- The stamp is written alongside the copy so unchanged runs can skip it.
	test.truthy(fs.exists(targetTestsFile(dir, ".lde-tests-stamp")))

	-- Edit the helper and re-run: the copy must be refreshed so
	-- require("tests.*") never serves stale content. Different size on
	-- purpose — the stamp's size/mtime fast path can't hide the change.
	fs.write(path.join(testsDir, "fixture.lua"), 'return { magic = 777 }')
	test.equal(pkg:runTests().failures, 0)

	local copied = fs.read(targetTestsFile(dir, "fixture.lua")) ---@cast copied -nil
	test.includes(copied, "777")
	test.falsy(copied:find("magic = 42", 1, true))
end)

test.it("runTests skips the target/tests copy when tests/ is unchanged", function()
	local dir = makeBuildScriptPackage("runtests-stamp-skip")

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "main.test.lua"), [[
local t = require("lde-test")
t.it("passes", function() end)
]])

	local pkg = assert(lde.Package.open(dir))
	test.equal(pkg:runTests().failures, 0)

	-- A file dropped into the copy that isn't in tests/ survives the second
	-- run, proving the copy wasn't re-made (a re-copy would wipe it).
	local marker = targetTestsFile(dir, "marker.txt")
	fs.write(marker, "keep me")
	test.equal(pkg:runTests().failures, 0)
	test.truthy(fs.exists(marker))
end)

test.it("runTests refreshes the target/tests copy when a test file is removed", function()
	local dir = makeBuildScriptPackage("runtests-stamp-delete")

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "unused.lua"), 'return "unused"')
	fs.write(path.join(testsDir, "main.test.lua"), [[
local t = require("lde-test")
t.it("passes", function() end)
]])

	local pkg = assert(lde.Package.open(dir))
	test.equal(pkg:runTests().failures, 0)
	test.truthy(fs.exists(targetTestsFile(dir, "unused.lua")))

	fs.delete(path.join(testsDir, "unused.lua"))
	test.equal(pkg:runTests().failures, 0)
	test.falsy(fs.exists(targetTestsFile(dir, "unused.lua")))
end)

test.it("runTests fails when a test file registers no tests", function()
	local dir = makePackageWithSrc("runtests-empty", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "empty.test.lua"), 'local t = require("lde-test")')

	local pkg = assert(lde.Package.open(dir))
	local results = pkg:runTests()

	test.equal(results.failures, 1)
	test.equal(results.total, 1)
	test.equal(#results.files, 1)
	test.equal(results.files[1].error, "No tests were registered")
end)

--
-- runTests: file filter globs
--

local filterTestFile = [[
local t = require("lde-test")
t.it("runs", function() end)
]]

test.it("runTests with single filter runs only matching files", function()
	local dir = makePackageWithSrc("runtests-filter-single", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "foo.test.lua"), filterTestFile)
	fs.write(path.join(testsDir, "bar.test.lua"), filterTestFile)
	fs.write(path.join(testsDir, "baz.test.lua"), filterTestFile)

	local pkg = assert(lde.Package.open(dir))
	local results = pkg:runTests(nil, { "foo*" })

	test.equal(results.failures, 0)
	test.equal(#results.files, 1)
	test.equal(results.files[1].file, "foo.test.lua")
end)

test.it("runTests with multiple filters runs matching files (OR logic)", function()
	local dir = makePackageWithSrc("runtests-filter-multi", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "alpha.test.lua"), filterTestFile)
	fs.write(path.join(testsDir, "beta.test.lua"), filterTestFile)
	fs.write(path.join(testsDir, "gamma.test.lua"), filterTestFile)

	local pkg = assert(lde.Package.open(dir))
	local results = pkg:runTests(nil, { "alpha*", "*gamma*" })

	test.equal(results.failures, 0)
	test.equal(#results.files, 2)
	test.equal(results.total, 2)
end)

test.it("runTests with filter that matches nothing returns empty results", function()
	local dir = makePackageWithSrc("runtests-filter-empty", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "main.test.lua"), filterTestFile)

	local pkg = assert(lde.Package.open(dir))
	local results = pkg:runTests(nil, { "doesnot*exist*" })

	test.equal(results.failures, 0)
	test.equal(#results.files, 0)
	test.equal(results.total, 0)
end)

test.it("runTests without filters runs all test files", function()
	local dir = makePackageWithSrc("runtests-filter-none", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "a.test.lua"), filterTestFile)
	fs.write(path.join(testsDir, "b.test.lua"), filterTestFile)

	local pkg = assert(lde.Package.open(dir))
	local results = pkg:runTests()

	test.equal(results.failures, 0)
	test.equal(#results.files, 2)
	test.equal(results.total, 2)
end)

test.it("runTests with absolute path filter runs only that file", function()
	local dir = makePackageWithSrc("runtests-filter-abspath", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "ohyes.test.lua"), filterTestFile)
	fs.write(path.join(testsDir, "ohno.test.lua"), filterTestFile)

	local absPath = path.join(testsDir, "ohyes.test.lua")
	local pkg = assert(lde.Package.open(dir))
	local results = pkg:runTests(nil, { absPath })

	test.equal(results.failures, 0)
	test.equal(#results.files, 1)
	test.equal(results.files[1].file, "ohyes.test.lua")
end)

test.it("runTests with path-like filter containing glob resolves and matches", function()
	local dir = makePackageWithSrc("runtests-filter-pathglob", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	local subDir = path.join(testsDir, "sub")
	fs.mkdir(testsDir)
	fs.mkdir(subDir)
	fs.write(path.join(testsDir, "one.test.lua"), filterTestFile)
	fs.write(path.join(subDir, "two.test.lua"), filterTestFile)

	local globPath = path.join(testsDir, "sub", "*.test.lua")
	local pkg = assert(lde.Package.open(dir))
	local results = pkg:runTests(nil, { globPath })

	test.equal(results.failures, 0)
	test.equal(#results.files, 1)
	test.equal(results.files[1].file, "sub" .. path.separator .. "two.test.lua")
end)

--
-- runTests: Teal (.tl) and Moonscript (.moon) test files are compiled to Lua
-- in target/tests before running, mirroring how build() compiles src/.
--

test.it("runTests compiles Teal (.tl) test files before running", function()
	local dir = makePackageWithSrc("runtests-teal", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "a.test.tl"), [[
local t = require("lde-test")
t.it("teal test passes", function()
	t.equal(40 + 2, 42)
end)
]])

	local pkg = assert(lde.Package.open(dir))
	local results = pkg:runTests()

	test.equal(results.failures, 0)
	test.equal(#results.files, 1)
	-- The runner reports the compiled .lua name, not the .tl source.
	test.equal(results.files[1].file, "a.test.lua")
	-- Compiled Lua landed in target/tests as a real dir (not a symlink).
	test.truthy(fs.exists(targetTestsFile(dir, "a.test.lua")))
	test.falsy(fs.islink(path.join(dir, "target", "tests")))
end)

test.it("runTests compiles Moonscript (.moon) test files before running", function()
	local dir = makePackageWithSrc("runtests-moon", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "a.test.moon"), util.dedent([[
		t = require("lde-test")
		t.it "moon test passes", ->
			t.equal 40 + 2, 42
	]]))

	local pkg = assert(lde.Package.open(dir))
	local results = pkg:runTests()

	test.equal(results.failures, 0)
	test.equal(#results.files, 1)
	test.equal(results.files[1].file, "a.test.lua")
	test.truthy(fs.exists(targetTestsFile(dir, "a.test.lua")))
	-- Moonscript sources don't survive in the compiled output.
	test.falsy(fs.exists(targetTestsFile(dir, "a.test.moon")))
end)

test.it("runTests maps .tl filters onto the compiled test file", function()
	local dir = makePackageWithSrc("runtests-filter-tl", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "foo.test.tl"), [[
local t = require("lde-test")
t.it("foo runs", function() end)
]])
	fs.write(path.join(testsDir, "bar.test.lua"), filterTestFile)

	local pkg = assert(lde.Package.open(dir))
	local results = pkg:runTests(nil, { "foo.test.tl" })

	test.equal(results.failures, 0)
	test.equal(#results.files, 1)
	test.equal(results.files[1].file, "foo.test.lua")
end)

test.it("runTests swaps a compiled target/tests back to a symlink for pure-Lua tests", function()
	local dir = makePackageWithSrc("runtests-src-lang-to-lua", { ["init.lua"] = 'return true' })

	local testsDir = path.join(dir, "tests")
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "a.test.tl"), [[
local t = require("lde-test")
t.it("teal runs", function() end)
]])

	local pkg = assert(lde.Package.open(dir))
	test.equal(pkg:runTests().failures, 0)
	test.truthy(fs.exists(targetTestsFile(dir, "a.test.lua")))

	-- Drop the .tl test, add a plain Lua one: target/tests must go back to
	-- being a symlink instead of serving the stale compiled copy.
	fs.rmdir(testsDir)
	fs.mkdir(testsDir)
	fs.write(path.join(testsDir, "b.test.lua"), filterTestFile)

	test.equal(pkg:runTests().failures, 0)
	test.equal(#pkg:runTests().files, 1)
	test.truthy(fs.islink(path.join(dir, "target", "tests")))
end)

test.it(
	"rockspec buildfn: array-style sources table compiles native module", function()
		local rockDir = path.join(tmpBase, "array-sources-rock")
		fs.mkdir(rockDir)
		fs.mkdir(path.join(rockDir, "src"))
		fs.write(path.join(rockDir, "src", "greet.c"), [[
#include <stddef.h>
typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);
extern void lua_pushstring(lua_State *L, const char *s);
extern void lua_createtable(lua_State *L, int narr, int nrec);
extern void lua_setfield(lua_State *L, int idx, const char *k);
extern void lua_pushcclosure(lua_State *L, lua_CFunction fn, int n);
static int greet(lua_State *L) { lua_pushstring(L, "hello"); return 1; }
int luaopen_greet(lua_State *L) {
	lua_createtable(L, 0, 1);
	lua_pushcclosure(L, greet, 0);
	lua_setfield(L, -2, "greet");
	return 1;
}
]])
		fs.write(path.join(rockDir, "greet-1.0.0-1.rockspec"), [[
			package = "greet"
			version = "1.0.0-1"
			source = { url = "git://example.com/greet" }
			build = {
				type = "builtin",
				modules = { greet = { "src/greet.c" } }
			}
		]])

		local appDir = path.join(tmpBase, "array-sources-app")
		fs.mkdir(appDir)
		fs.mkdir(path.join(appDir, "src"))
		fs.write(path.join(appDir, "src", "init.lua"),
			'local m = require("greet"); assert(m.greet() == "hello")')
		fs.write(path.join(appDir, "lde.json"), json.encode({
			name = "array-sources-app",
			version = "0.1.0",
			dependencies = { greet = { path = "../array-sources-rock" } }
		}))

		local app = lde.Package.open(appDir) ---@cast app -nil
		app:installDependencies()
		local ok, err = app:runFile()
		if not ok then print(err) end
		test.truthy(ok)
	end)

--
-- Regression: src.sources as a string (not a table) must not crash ipairs
--

test.it("rockspec: sources = 'file.c' (string) is accepted without crashing", function()
	local dir = path.join(tmpBase, "string-sources-rock")
	fs.mkdir(dir)
	fs.write(path.join(dir, "string-sources-1.0-1.rockspec"), [[
package = "string-sources"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {
    foo = { sources = "src/foo.c" },
  }
}
]])
	-- openRockspec must not error even though sources is a string
	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err) ---@cast pkg -nil
end)

--
-- Regression: build.install.lua files must be copied to target
--

test.it("rockspec: install.lua files are copied to target modulesDir", function()
	local dir = path.join(tmpBase, "install-lua-rock")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "lua"))
	fs.mkdir(path.join(dir, "lua", "mypkg"))
	fs.write(path.join(dir, "lua", "mypkg", "util.lua"), 'return "util"')
	fs.write(path.join(dir, "install-lua-1.0-1.rockspec"), [[
package = "install-lua"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {},
  install = {
    lua = {
      ["mypkg.util"] = "lua/mypkg/util.lua",
    }
  }
}
]])

	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err) ---@cast pkg -nil

	local outputDir = path.join(dir, "target", "install-lua")
	local ok, berr = pkg:runBuildScript(outputDir)
	test.truthy(ok, berr)

	-- mypkg.util -> lua/mypkg/util.lua => target/mypkg/util.lua
	test.truthy(fs.exists(path.join(dir, "target", "mypkg", "util.lua")))
end)

--
-- Regression: array-style install.bin should use basename, not full relative path
--

test.it("rockspec: array-style install.bin uses basename as bin name and target location", function()
	local dir = path.join(tmpBase, "array-bin-rock")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "bin"))
	fs.write(path.join(dir, "bin", "myscript"), 'print("hi")')
	fs.write(path.join(dir, "array-bin-1.0-1.rockspec"), [[
package = "array-bin"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {},
  install = {
    bin = { "bin/myscript" }
  }
}
]])

	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err) ---@cast pkg -nil

	local outputDir = path.join(dir, "target", "array-bin")
	local ok, berr = pkg:runBuildScript(outputDir)
	test.truthy(ok, berr)

	-- file must land at target/array-bin/myscript, not target/array-bin/bin/myscript
	test.truthy(fs.exists(path.join(outputDir, "myscript")))
	test.equal(fs.exists(path.join(outputDir, "bin", "myscript")), false)

	-- readConfig must return bin = "myscript", not "bin/myscript"
	local cfg = pkg:readConfig()
	test.equal(cfg.bin, "myscript")
end)

--
-- Regression: platform build.install.lua must merge over the base build, and
-- array-style lua entries install under their basename (LuaSec pattern).
--

test.it("rockspec: platform install.lua merges and array keys use basename", function()
	local platKey = jit.os == "OSX" and "macosx" or jit.os == "Windows" and "win32" or "linux"

	local dir = path.join(tmpBase, "plat-install-lua-rock")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "ssl.lua"), 'return "ssl"')
	fs.write(path.join(dir, "src", "https.lua"), 'return "https"')
	fs.write(path.join(dir, "plat-install-1.0-1.rockspec"), string.format([[
package = "plat-install"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {},
  platforms = {
    ["%s"] = {
      install = {
        lua = {
          "src/ssl.lua",
          ["ssl.https"] = "src/https.lua",
        }
      }
    }
  }
}
]], platKey))

	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err) ---@cast pkg -nil

	local outputDir = path.join(dir, "target", "plat-install")
	local ok, berr = pkg:runBuildScript(outputDir)
	test.truthy(ok, berr)

	-- array key "src/ssl.lua" must land as target/ssl.lua (basename),
	-- not target/src/ssl.lua
	test.truthy(fs.exists(path.join(dir, "target", "ssl.lua")))
	test.equal(fs.exists(path.join(dir, "target", "src", "ssl.lua")), false)
	-- string key ssl.https -> target/ssl/https.lua
	test.truthy(fs.exists(path.join(dir, "target", "ssl", "https.lua")))
end)

--
-- Regression: rockspec native modules must honor incdirs (LuaSec bundles its
-- luasocket headers under src/luasocket and includes <luasocket/io.h>).
--

test.it("rockspec: native compile honors module incdirs", function()
	local dir = path.join(tmpBase, "incdirs-rock")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.mkdir(path.join(dir, "src", "inc"))
	fs.write(path.join(dir, "src", "inc", "greet.h"), "int lde_incdir_ok(void);\n")
	fs.write(path.join(dir, "src", "greet.c"), [[
#include <greet.h>
#include <stddef.h>
typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);
extern void lua_pushinteger(lua_State *L, int n);
int lde_incdir_ok(void) { return 42; }
static int greet(lua_State *L) { lua_pushinteger(L, lde_incdir_ok()); return 1; }
int luaopen_greet(lua_State *L) { return 0; }
]])
	fs.write(path.join(dir, "incdirs-1.0-1.rockspec"), [[
package = "incdirs"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "builtin",
  modules = {
    greet = {
      sources = { "src/greet.c" },
      incdirs = { "src/inc" },
    }
  }
}
]])

	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err) ---@cast pkg -nil

	local outputDir = path.join(dir, "target", "incdirs")
	local ok, berr = pkg:runBuildScript(outputDir)
	-- Without incdirs support this fails: greet.h not found
	test.truthy(ok, berr)
	test.truthy(fs.exists(path.join(dir, "target", "greet." .. (jit.os == "Windows" and "dll" or "so"))))
end)

--
-- Regression: a string-valued `libraries` (and string sources/libdirs/defines)
-- must be treated as a one-element list (lzlib declares `libraries = "z"` and
-- `libdirs = "$(ZLIB_LIBDIR)"`; without this the link drops -lz and the .so
-- fails with "undefined symbol: inflate"). Pure unit test: no compiler, no
-- platform-specific link inspection (ldd/otool/objdump all differ per OS).
--

test.it("rockspec: string-valued native module fields are normalized to lists", function()
	local hasArg = function(args, want)
		for _, a in ipairs(args) do
			if a == want then return true end
		end
		return false
	end

	-- Every string field becomes a one-element list.
	local src = lde.Package.normalizeNativeModule({
		sources = "src/ztest.c",
		defines = "STR_LIB_TEST",
		incdirs = "$(LUA_INCDIR)",
		libdirs = "$(LUA_LIBDIR)",
		libraries = "c",
	})
	test.equal("src/ztest.c", src.sources[1])
	test.equal("STR_LIB_TEST", src.defines[1])
	test.equal("$(LUA_INCDIR)", src.incdirs[1])
	test.equal("$(LUA_LIBDIR)", src.libdirs[1])
	test.equal("c", src.libraries[1])

	-- Build-level defaults apply when a module omits a field.
	local withDefaults = lde.Package.normalizeNativeModule({ sources = { "a.c" } }, {
		libraries = "z",
		defines = "FOO",
	})
	test.equal("z", withDefaults.libraries[1])
	test.equal("FOO", withDefaults.defines[1])

	-- The normalized fields are passed through to the compiler invocation.
	-- Expected flags are built with path.join so the assertions match the
	-- platform-native separators the code produces on Windows too.
	local incFlag = "-I" .. path.join("/lj", "include")
	local libFlag = "-L" .. path.join("/lj", "lib")
	local srcPath = path.join("/pkg", "src/ztest.c")
	local args = lde.Package.nativeGccArgs(src, {
		packageDir = "/pkg",
		modulesDir = "/pkg/target",
		luajitPath = "/lj",
		destAbs = "/pkg/target/ztest.so",
		jitOS = "Linux",
	})
	test.truthy(hasArg(args, "-lc"), "expected -lc to be passed")
	test.truthy(hasArg(args, "-DSTR_LIB_TEST"), "expected -DSTR_LIB_TEST to be passed")
	test.truthy(hasArg(args, incFlag), "expected " .. incFlag .. " to be passed")
	test.truthy(hasArg(args, libFlag), "expected " .. libFlag .. " to be passed")
	test.truthy(hasArg(args, srcPath), "expected " .. srcPath .. " to be passed")
	test.truthy(hasArg(args, "/pkg/target/ztest.so"), "expected the output path to be passed")

	-- Unknown $(VAR) placeholders are skipped rather than passed through raw.
	local skipped = lde.Package.nativeGccArgs({ sources = { "a.c" }, libdirs = { "$(ZLIB_LIBDIR)" } }, {
		packageDir = "/pkg",
		modulesDir = "/pkg/target",
		luajitPath = "/lj",
		destAbs = "/out/a.so",
		jitOS = "Linux",
	})
	for _, a in ipairs(skipped) do
		test.falsy(a:find("ZLIB_LIBDIR", 1, true), "unresolved placeholder leaked into args")
	end
end)

--
-- Regression: make build.variables / install_variables substitution + bin promotion
--

--
-- lde-build exposed to build scripts via preload
--

test.it("build script can require('lde-build') and uses correct outDir", function()
	local dir = path.join(tmpBase, "ldebuild-exposed")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return true')
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "ldebuild-exposed",
		version = "0.1.0",
		dependencies = {}
	}))

	-- build.lua that uses lde-build to write a file
	fs.write(path.join(dir, "build.lua"), [[
local build = require("lde-build")
build:write("output.txt", "hello from lde-build")
]])

	local pkg = assert(lde.Package.open(dir))
	local outputDir = path.join(dir, "target", pkg:getName())
	local ok, err = pkg:runBuildScript(outputDir)
	test.truthy(ok, err)

	local writtenPath = path.join(outputDir, "output.txt")
	test.truthy(fs.exists(writtenPath))
	test.equal(fs.read(writtenPath), "hello from lde-build")
end)

test.it("build script lde-build instance has correct outDir matching LDE_OUTPUT_DIR", function()
	local dir = path.join(tmpBase, "ldebuild-outdir")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return true')
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "ldebuild-outdir",
		version = "0.1.0",
		dependencies = {}
	}))

	-- build.lua that checks outDir matches LDE_OUTPUT_DIR
	fs.write(path.join(dir, "build.lua"), [[
local build = require("lde-build")
local outputDir = os.getenv("LDE_OUTPUT_DIR")
assert(build.outDir == outputDir,
"outDir mismatch: got " .. tostring(build.outDir) .. " expected " .. tostring(outputDir))
]])

	local pkg = assert(lde.Package.open(dir))
	local outputDir = path.join(dir, "target", pkg:getName())
	local ok, err = pkg:runBuildScript(outputDir)
	test.truthy(ok, err)
end)

test.it("build script lde-build fetch, write, sh, and read methods work", function()
	local dir = path.join(tmpBase, "ldebuild-methods")
	fs.mkdir(dir)
	fs.mkdir(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), 'return true')
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "ldebuild-methods",
		version = "0.1.0",
		dependencies = {}
	}))

	-- build.lua that exercises fetch, write, sh, and read
	fs.write(path.join(dir, "build.lua"), [[
local build = require("lde-build")

-- write and read
build:write("hello.txt", "world")
local content = build:read("hello.txt")
assert(content == "world", "read/write mismatch: " .. content)

-- sh should work (echo is available everywhere)
build:sh("echo hello > " .. build.outDir .. "/shell.txt")
local shellContent = build:read("shell.txt")
assert(shellContent:match("hello"), "sh/read mismatch: " .. shellContent)
]])

	local pkg = assert(lde.Package.open(dir))
	local outputDir = path.join(dir, "target", pkg:getName())
	local ok, err = pkg:runBuildScript(outputDir)
	test.truthy(ok, err)

	-- Verify end result
	test.equal(fs.read(path.join(outputDir, "hello.txt")), "world")
	test.truthy(fs.read(path.join(outputDir, "shell.txt")):match("hello"))
end)

test.it("rockspec: make build.variables are substituted and passed to make", function()
	local dir = path.join(tmpBase, "make-vars-rock")
	fs.mkdir(dir)
	-- Makefile that writes MY_INCDIR to built.txt on build, then copies it on install.
	-- install must NOT depend on build (a phony dep would re-run build with install's vars,
	-- overwriting built.txt with an empty MY_INCDIR since it only appears in build.variables).
	fs.write(path.join(dir, "Makefile"), [[
build:
	echo "$(MY_INCDIR)" > hasBuilt.txt

install:
	mkdir -p $(MY_LIBDIR)
	cp hasBuilt.txt $(MY_LIBDIR)/vars.txt
	mkdir -p $(PREFIX)/bin
	echo "#!/bin/sh" > $(PREFIX)/bin/myprog
	chmod 755 $(PREFIX)/bin/myprog
]])
	fs.write(path.join(dir, "make-vars-1.0-1.rockspec"), [[
package = "make-vars"
version = "1.0-1"
source = { url = "https://example.com" }
build = {
  type = "make",
  variables     = { MY_INCDIR = "$(LUA_INCDIR)" },
  install_variables = { MY_LIBDIR = "$(LUADIR)", PREFIX = "$(PREFIX)" },
}
]])

	local pkg, err = lde.Package.openRockspec(dir)
	test.truthy(pkg, err) ---@cast pkg -nil

	local outputDir = path.join(dir, "target", "make-vars")
	local ok, berr = pkg:runBuildScript(outputDir)
	test.truthy(ok, berr)

	-- vars.txt must exist in modulesDir (= target/)
	local modulesDir = path.join(dir, "target")
	test.truthy(fs.exists(path.join(modulesDir, "vars.txt")))

	-- vars.txt must contain the LuaJIT include path (substituted from $(LUA_INCDIR))
	local content = fs.read(path.join(modulesDir, "vars.txt")) or ""
	test.truthy(content:find("luajit", 1, true) or content:find("include", 1, true))

	-- myprog binary must be promoted from target/bin/ into target/make-vars/
	test.truthy(fs.exists(path.join(outputDir, "myprog")))

	-- readConfig must discover the promoted bin
	local cfg = pkg:readConfig()
	test.equal(cfg.bin, "myprog")
end)
