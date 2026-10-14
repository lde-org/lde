--- While a build pass is active, rockspec builds spawn gcc children and return a deferred finalizer the loop polls; otherwise they run synchronously as before.

const asyncBuild = {}

---@type boolean
local active = false

function asyncBuild.begin()
	active = true
end

function asyncBuild.finish()
	active = false
end

function asyncBuild.isActive()
	return active
end

return asyncBuild
