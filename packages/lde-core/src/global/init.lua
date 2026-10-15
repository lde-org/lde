--- The lde home tree: directory layout, compile toolchain, git/archive caches,
--- registry access and tool shims. Each concern lives in its own submodule; the
--- fields below are the flat `lde.global.<fn>` API callers use.

const fs = require("fs")

const global = {}
-- Registered before the submodules load: lde-core.global.config (and through it
-- the registry submodule) requires this table back.
package.loaded[(...)] = global

const dirs = require("lde-core.global.dirs")
const toolchain = require("lde-core.global.toolchain")
const git = require("lde-core.global.git")
const archive = require("lde-core.global.archive")
const registry = require("lde-core.global.registry")
const wrapper = require("lde-core.global.wrapper")
const mingw = require("lde-core.global.mingw")

global.getConfig = require("lde-core.global.config")
global.currentVersion = (function()
	const ok, v = pcall(require, "lde.version")
	return ok and v or "0.11.0"
end)()

global.setDir = dirs.setDir
global.getDir = dirs.getDir
global.getUserDir = dirs.getUserDir
global.getConfigPath = dirs.getConfigPath
global.getGitCacheDir = dirs.getGitCacheDir
global.getTarCacheDir = dirs.getTarCacheDir
global.getRockspecCacheDir = dirs.getRockspecCacheDir
global.getToolsDir = dirs.getToolsDir
global.getMingwDir = dirs.getMingwDir

global.setTarget = toolchain.setTarget
global.getTarget = toolchain.getTarget
global.getTargetKey = toolchain.getTargetKey
global.getTargetFlag = toolchain.getTargetFlag
global.getTargetTriple = toolchain.getTargetTriple
global.getCCCommand = toolchain.getCCCommand
global.getCCBin = toolchain.getCCBin
global.getMakeBin = toolchain.getMakeBin
global.getScriptShell = toolchain.getScriptShell
global.getShellPath = toolchain.getShellPath

global.getGitRepoDir = git.getGitRepoDir
global.markGitRepoCached = git.markGitRepoCached
global.isGitRepoCached = git.isGitRepoCached
global.cloneDir = git.cloneDir
global.resolveGitRef = git.resolveGitRef
global.getOrInitGitRepo = git.getOrInitGitRepo
global.planGitRepo = git.planGitRepo
global.extractGitTarball = git.extractGitTarball
global.parseGitUrl = git.parseGitUrl
global.repoNameFromUrl = git.repoNameFromUrl
global.openEnclosingRepo = git.openEnclosingRepo
global.getOrCloneRepo = git.getOrCloneRepo
global.findNamedPackageIn = git.findNamedPackageIn

global.getOrInitArchive = archive.getOrInitArchive
global.getArchiveDir = archive.getArchiveDir
global.sourceDirFor = archive.sourceDirFor
global.extractArchive = archive.extractArchive

global.getRegistryDir = registry.getRegistryDir
global.syncRegistry = registry.syncRegistry
global.lookupRegistryPackage = registry.lookupRegistryPackage
global.resolveRegistryVersion = registry.resolveRegistryVersion
global.validatePackageName = registry.validatePackageName

global.writeWrapper = wrapper.writeWrapper
global.ensureMingw = mingw.ensureMingw

function global.init()
	-- mkdirAll: LDE_HOME (or a --tree) may point at a not-yet-existing path whose
	-- parents also need creating, not just the final dir.
	fs.mkdirAll(global.getDir())

	const gitCacheDir = global.getGitCacheDir()
	if not fs.exists(gitCacheDir) then
		fs.mkdir(gitCacheDir)
	end

	const tarCacheDir = global.getTarCacheDir()
	if not fs.exists(tarCacheDir) then
		fs.mkdir(tarCacheDir)
	end

	const rockspecCacheDir = global.getRockspecCacheDir()
	if not fs.exists(rockspecCacheDir) then
		fs.mkdir(rockspecCacheDir)
	end

	local toolsDir = global.getToolsDir()
	if not fs.exists(toolsDir) then
		fs.mkdir(toolsDir)
	end
end

return global
