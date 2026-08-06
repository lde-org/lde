--- Build-time async flag.
---
--- When the install build loop wants native compiles (rockspec builtin/module
--- builds) to run concurrently, it calls `asyncBuild.begin()` around the build
--- pass. The rockspec buildfn then spawns gcc children instead of blocking on
--- `process.exec`, and returns a deferred finalizer; the loop polls all spawned
--- children and calls the finalizers once they finish. Outside of an active
--- session every build behaves exactly as before (synchronous gcc).

local asyncBuild = {}

---@type boolean
local active = false

--- Enter async native-build mode for the duration of a build pass.
function asyncBuild.begin()
	active = true
end

--- Leave async mode. No-op when not active.
function asyncBuild.finish()
	active = false
end

---@return boolean true while async native builds are in flight-capable mode
function asyncBuild.isActive()
	return active
end

return asyncBuild
