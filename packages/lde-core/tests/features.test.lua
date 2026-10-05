local test = require("lde-test")

local lde = require("lde-core")

local features = require("lde-core.package.features")
local bundlePackage = require("lde-core.package.bundle")

local fs = require("fs")
local env = require("env")
local path = require("path")
local json = require("json")

local tmpBase = path.join(env.tmpdir(), "lde-features-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

local platformFlag = ({ Windows = "windows", Linux = "linux", OSX = "macos", BSD = "bsd" })[jit.os]
local isWindows = jit.os == "Windows"

-- ── platform flags ───────────────────────────────────────────────────────────

test.it("platform flags: the OS's own flag is always on", function()
	local flags = features.platformFlags()
	local found = false
	for _, flag in ipairs(flags) do
		if flag == platformFlag then found = true end
	end
	test.truthy(found)
end)

test.it("platform flags: unix is on for every non-Windows platform", function()
	local defs = features.parse({ unix = { "term" }, windows = { "winapi" } }, "pkg")
	local enabled = features.enabledDependencies(defs, nil)
	if isWindows then
		test.truthy(enabled["winapi"])
		test.falsy(enabled["term"])
	else
		test.truthy(enabled["term"])
		test.falsy(enabled["winapi"])
	end
end)

test.it("platform flags: bsd is mapped (it used to have no flag at all)", function()
	local flags = features.platformFlags()
	test.truthy(#flags >= 1)
	if jit.os == "BSD" then test.equal(flags[1], "bsd") end
end)

-- ── the list: dependency alias vs module name ────────────────────────────────

test.it("list: a bare name is a dependency alias", function()
	local defs = features.parse({ windows = { "winapi" } }, "mypackage")
	test.truthy(features.enabledDependencies(defs, { "windows" })["winapi"])
	test.equal(features.excludes(defs, { "windows" }), nil)
end)

test.it("list: a <package>. name is one of the package's own modules", function()
	-- The documented spelling: the entry is the module name the way require()
	-- spells it, so it always starts with the declaring package's own name and
	-- a dot.
	local defs = features.parse({ vulkan = { "mypackage.vulkan" } }, "mypackage")
	test.equal(next(features.enabledDependencies(defs, { "vulkan" })), nil)
	test.equal(table.concat(features.excludes(defs, { "vulkan" }) --[[@as string[] ]], ","), "vulkan")
end)

test.it("list: nested module names map onto directories", function()
	local defs = features.parse({ v = { "mypackage.a.b" } }, "mypackage")
	test.equal(table.concat(features.excludes(defs, { "v" }) --[[@as string[] ]], ","), "a/b")
end)

test.it("list: a foreign package's prefix is not a module name here", function()
	-- `otherpkg.thing` inside `mypackage` is not one of mypackage's modules, so
	-- it stays a dependency alias. The prefix is what disambiguates, and it is
	-- provable: package names are validated to ^[a-z][a-z0-9_-]*[a-z0-9]$, so
	-- they can never contain a dot.
	local defs = features.parse({ v = { "otherpkg.thing" } }, "mypackage")
	test.truthy(features.enabledDependencies(defs, { "v" })["otherpkg.thing"])
end)

test.it("list: deps and modules can be mixed in one list", function()
	local defs = features.parse({ unix = { "luaposix", "mypackage.raw.windows" } }, "mypackage")
	test.truthy(features.enabledDependencies(defs, { "unix" })["luaposix"])
	test.equal(table.concat(features.excludes(defs, { "unix" }) --[[@as string[] ]], ","), "raw/windows")
end)

test.it("list: excludes are sorted and de-duplicated for a stable lockfile", function()
	local defs = features.parse({ x = { "p.b", "p.a", "p.b" } }, "p")
	test.equal(table.concat(features.excludes(defs, { "x" }) --[[@as string[] ]], ","), "a,b")
end)

test.it("list: nil when nothing is excluded", function()
	test.equal(features.excludes(features.parse({ x = { "dep" } }, "p"), { "x" }), nil)
end)

test.it("list: a flag that is off contributes nothing", function()
	local defs = features.parse({ windows = { "p.a" } }, "p")
	test.equal(features.excludes(defs, nil), nil)
end)

test.it("list: a non-list feature value is rejected, not silently ignored", function()
	-- Silently ignoring it would leave a package quietly shipping the files it
	-- asked to exclude, which is the one failure mode worth being loud about.
	test.errors(function()
		features.parse({ vulkan = { deps = { "x" } } }, "mypackage")
	end)
end)

-- ── what a module name covers ────────────────────────────────────────────────

test.it("match: one module name covers every form the module can ship in", function()
	-- Exclusion matches on the module a file implements, not its filename, so
	-- a native module is gated by the same entry as its Lua twin.
	local excludes = features.excludes(
		features.parse({ w = { "fs.native.core" } }, "fs"), { "w" })
		--[[@as string[] ]]

	test.truthy(features.isExcluded("native/core.lua", excludes))
	test.truthy(features.isExcluded("native/core.so", excludes))
	test.truthy(features.isExcluded("native/core.dll", excludes))
	test.truthy(features.isExcluded("native/core.dylib", excludes))
	-- X/init.lua is the module X, so it is covered too.
	test.truthy(features.isExcluded("native/core/init.lua", excludes))
	test.truthy(features.isExcluded("native/core/init.so", excludes))
end)

test.it("match: a different module is untouched", function()
	local excludes = features.excludes(
		features.parse({ w = { "fs.native.core" } }, "fs"), { "w" })
		--[[@as string[] ]]

	test.falsy(features.isExcluded("native/other.so", excludes))
	test.falsy(features.isExcluded("nested/native/core.so", excludes))
	test.falsy(features.isExcluded("native/coreX.lua", excludes))
end)

test.it("match: filter keeps everything when there are no excludes", function()
	test.equal(#features.filter({ "a.lua", "b.lua" }, nil), 2)
end)

-- ── enabled flags, as build scripts see them ─────────────────────────────────

test.it("enabledFlags: platform flags are on whether or not they are declared", function()
	-- A build script asking `build:feature("linux")` must get true on Linux even
	-- in a package whose manifest never mentions `linux`.
	local flags = features.enabledFlags(features.parse({ custom = { "x" } }, "p"), nil)
	local found = false
	for _, flag in ipairs(flags) do
		if flag == platformFlag then found = true end
	end
	test.truthy(found)
end)

test.it("enabledFlags: requested flags are on even when undeclared", function()
	-- A flag may drive nothing but the build script, so requesting it is enough.
	local flags = features.enabledFlags(nil, { "vulkan" })
	local found = false
	for _, flag in ipairs(flags) do
		if flag == "vulkan" then found = true end
	end
	test.truthy(found)
end)

test.it("enabledFlags: free of duplicates", function()
	local seen = {}
	for _, flag in ipairs(features.enabledFlags(nil, { "b", "a", "b" })) do
		test.falsy(seen[flag])
		seen[flag] = true
	end
end)

-- ── manifest normalization ───────────────────────────────────────────────────

test.it("of(pkg): splits a manifest's lists into deps and modules", function()
	local dir = path.join(tmpBase, "manifest")
	fs.mkdirAll(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), "return true")
	fs.write(path.join(dir, "lde.json"), json.encode({
		name = "manifest",
		version = "0.1.0",
		features = {
			mixed = { "dep", "manifest.raw.windows" },
			deps  = { "other" },
		},
	}))

	local pkg = lde.Package.open(dir) ---@cast pkg -nil
	local defs = features.of(pkg) ---@cast defs -nil
	test.equal(defs.mixed.deps[1], "dep")
	test.equal(defs.mixed.modules[1], "raw/windows")
	test.equal(defs.deps.deps[1], "other")
	test.equal(defs.deps.modules, nil)
end)

test.it("of(pkg): a package with no features yields nil", function()
	local dir = path.join(tmpBase, "nofeatures")
	fs.mkdirAll(path.join(dir, "src"))
	fs.write(path.join(dir, "src", "init.lua"), "return true")
	fs.write(path.join(dir, "lde.json"), json.encode({ name = "nofeatures", version = "0.1.0" }))

	local pkg = lde.Package.open(dir) ---@cast pkg -nil
	test.equal(features.of(pkg), nil)
end)

-- ── excludesFor: manifest beside the modules, then the lockfile ──────────────

test.it("excludesFor: reads the dependency's own manifest when it is adjacent", function()
	local modulesDir = path.join(tmpBase, "adjacent", "target")
	fs.mkdirAll(path.join(modulesDir, "dep"))
	fs.write(path.join(modulesDir, "lde.json"), json.encode({
		name = "dep",
		version = "0.1.0",
		features = { unix = { "dep.raw.windows" } },
	}))

	local excludes = features.excludesFor(modulesDir, "dep", nil)
	if isWindows then
		test.equal(excludes, nil)
	else
		test.equal(table.concat(excludes --[[@as string[] ]], ","), "raw/windows")
	end
end)

test.it("excludesFor: falls back to the locked list when there is no manifest", function()
	-- A dependency materialized as a copy (anything with a build.lua) keeps no
	-- lde.json next to its modules, so the resolved list in the lockfile is all
	-- the bundler has to go on.
	local modulesDir = path.join(tmpBase, "locked", "target")
	fs.mkdirAll(path.join(modulesDir, "dep"))

	local excludes = features.excludesFor(modulesDir, "dep", { exclude = { "a" } }) ---@cast excludes -nil
	test.equal(excludes[1], "a")

	test.equal(features.excludesFor(modulesDir, "dep", nil), nil)
end)

-- ── end to end: a real bundle ────────────────────────────────────────────────

local depDir = path.join(tmpBase, "e2e-dep")
fs.mkdirAll(path.join(depDir, "src", "sub", "nested"))
fs.write(path.join(depDir, "src", "init.lua"), "return { win = true, unix = true }")
fs.write(path.join(depDir, "src", "win.lua"), 'return "windows"')
fs.write(path.join(depDir, "src", "unix.lua"), 'return "unix"')
-- A nested module: `e2e-dep.sub.nested.win` resolves to sub/nested/win.lua.
fs.write(path.join(depDir, "src", "sub", "nested", "win.lua"), 'return "nested"')
-- A native module under the same gating, to prove one entry covers both.
fs.write(path.join(depDir, "src", "plugin.so"), "PLUGIN-BYTES-MARKER")
fs.write(path.join(depDir, "lde.json"), json.encode({
	name = "e2e-dep",
	version = "0.1.0",
	-- Symmetric platform gating: exactly one backend survives, whichever
	-- platform the bundle is built on. This is the shape `fs` would use to stop
	-- being a monorepo.
	features = {
		windows = { "e2e-dep.unix", "e2e-dep.sub.nested.win", "e2e-dep.plugin" },
		unix    = { "e2e-dep.win", "e2e-dep.sub.nested.win" },
	},
}))

local appDir = path.join(tmpBase, "e2e-app")
fs.mkdirAll(path.join(appDir, "src"))
fs.write(path.join(appDir, "src", "init.lua"), 'return require("e2e-dep")')
fs.write(path.join(appDir, "lde.json"), json.encode({
	name = "e2e-app",
	version = "0.1.0",
	dependencies = { ["e2e-dep"] = { path = "../e2e-dep" } },
}))

test.it("bundle: platform-excluded modules are not in the bundle", function()
	local app = lde.Package.open(appDir) ---@cast app -nil
	app:build()
	app:installDependencies()

	local source = bundlePackage(app, {}) --[[@as string]]

	if isWindows then
		test.truthy(source:find('package.preload["e2e-dep.win"]', 1, true))
		test.falsy(source:find('package.preload["e2e-dep.unix"]', 1, true))
	else
		test.truthy(source:find('package.preload["e2e-dep.unix"]', 1, true))
		test.falsy(source:find('package.preload["e2e-dep.win"]', 1, true))
	end
	-- Excluded under both platform flags, so it never survives.
	test.falsy(source:find('package.preload["e2e-dep.sub.nested.win"]', 1, true))
end)

test.it("bundle: the entry point survives exclusion", function()
	local app = lde.Package.open(appDir) ---@cast app -nil
	local source = bundlePackage(app, {}) --[[@as string]]
	test.truthy(source:find('package.preload["e2e-dep"]', 1, true))
end)

test.it("bundle: a native module dropped by a feature is not embedded", function()
	local dep = lde.Package.open(depDir) ---@cast dep -nil
	dep:installDependencies()
	dep:build()

	local withNative = bundlePackage(dep, {}) --[[@as string]]
	local withoutNative = bundlePackage(dep, { features = { "windows" } }) --[[@as string]]

	-- The `windows` flag drops `e2e-dep.plugin`, which is src/plugin.so.
	test.truthy(withNative:find("PLUGIN-BYTES-MARKER", 1, true))
	test.falsy(withoutNative:find("PLUGIN-BYTES-MARKER", 1, true))
	-- ...and it is a Lua module list, so the Lua half still behaves.
	test.truthy(withoutNative:find('package.preload["e2e-dep"]', 1, true))
end)

test.it("bundle: the filtered bundle still runs", function()
	local app = lde.Package.open(appDir) ---@cast app -nil
	local source = bundlePackage(app, {}) --[[@as string]]

	-- Chunk name is absolute on purpose: a bundle that embeds native modules
	-- extracts them next to itself, and a relative name would drop them in the
	-- working directory (i.e. the repo) when the chunk runs.
	local chunk = assert(loadstring(source, "@" .. path.join(tmpBase, "e2e-bundle.lua")))
	local result = chunk()
	test.equal(type(result), "table")
	test.truthy(result.win or result.unix)
end)

test.it("bundle: the lockfile records the resolved excludes", function()
	local app = lde.Package.open(appDir) ---@cast app -nil
	local lockfile = lde.Lockfile.open(app:getLockfilePath()) ---@cast lockfile -nil
	local entry = lockfile:getDependency("e2e-dep") ---@cast entry -nil

	-- Module names are resolved to module paths before they land in the lockfile.
	test.truthy((table.concat(entry.exclude or {}, ",")):find("sub/nested/win", 1, true))
end)

test.it("bundle: a locked exclude still applies when the manifest is unreachable", function()
	-- Simulates a dependency materialized as a copy (anything with a build.lua):
	-- no usable lde.json next to its modules, so the resolved list in the
	-- lockfile is all the bundler has to go on.
	local app = lde.Package.open(appDir) ---@cast app -nil
	local adjacent = path.join(app:getModulesDir(), "lde.json")

	fs.write(adjacent, json.encode({ name = "e2e-dep", version = "0.1.0" }))
	local source = bundlePackage(app, {}) --[[@as string]]
	fs.delete(adjacent)

	test.falsy(source:find('package.preload["e2e-dep.sub.nested.win"]', 1, true))
end)

-- ── build:feature, as seen by a build script ─────────────────────────────────

local bfeatDir = path.join(tmpBase, "bfeat")
fs.mkdirAll(path.join(bfeatDir, "src"))
fs.write(path.join(bfeatDir, "src", "init.lua"), "return true")
fs.write(path.join(bfeatDir, "lde.json"), json.encode({
	name = "bfeat",
	version = "0.1.0",
	features = { unix = { "bfeat.win" } },
}))
fs.write(path.join(bfeatDir, "build.lua"), [[
local build = require("lde-build")
build:write("features.txt", table.concat({
	"windows=" .. tostring(build:feature("windows")),
	"unix=" .. tostring(build:feature("unix")),
	"custom=" .. tostring(build:feature("custom")),
	"nope=" .. tostring(build:feature("nope")),
}, "\n"))
]])

test.it("build:feature reports the platform flags to a build script", function()
	local pkg = lde.Package.open(bfeatDir) ---@cast pkg -nil
	pkg:build()

	local written = fs.read(path.join(bfeatDir, "target", "bfeat", "features.txt")) ---@cast written -nil
	test.truthy(written:find("windows=" .. tostring(isWindows), 1, true))
	test.truthy(written:find("unix=" .. tostring(not isWindows), 1, true))
	test.truthy(written:find("nope=false", 1, true))
end)

test.it("build:feature sees a flag the caller asked for", function()
	local pkg = lde.Package.open(bfeatDir) ---@cast pkg -nil
	-- The installer records the flags a dependency entry named; a package built
	-- directly has only the platform's flags, so set them the way the resolver
	-- would. Clear the previous build first: the stamp would otherwise skip it.
	fs.rmdir(pkg:getModulesDir())
	pkg:setFeatures({ "custom", platformFlag })
	pkg:build()

	local written = fs.read(path.join(bfeatDir, "target", "bfeat", "features.txt")) ---@cast written -nil
	test.truthy(written:find("custom=true", 1, true))
end)
