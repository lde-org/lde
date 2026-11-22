--- Minimal Android APK builder: compile the NativeActivity bootstrap, embed
--- the Lua bundle and package it with aapt2/apksigner.

local fs = require("fs")
local path = require("path")
local process = require("process")
local env = require("env")
local jit = require("jit")

local targetModule = require("sea.target")

local android = {}

local SHIM_C = [==[
#include "android_native_app_glue.h"
#include <jni.h>
#include <android/log.h>
#include <unistd.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

extern const unsigned char lde_bundle_start[];
extern const unsigned char lde_bundle_end[];

/* The directory the package manager installed the APK's native libraries in, from
 * getApplicationInfo().nativeLibraryDir. Native modules are loaded from there. */
static void lde_push_native_library_dir(lua_State* L, struct android_app* app)
{
	JavaVM* vm = app->activity->vm;
	JNIEnv* env = NULL;
	if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) { lua_pushnil(L); return; }

	jobject activity = app->activity->clazz;
	jclass contextClass = (*env)->GetObjectClass(env, activity);
	jmethodID getInfo = (*env)->GetMethodID(env, contextClass, "getApplicationInfo",
		"()Landroid/content/pm/ApplicationInfo;");
	jobject info = getInfo ? (*env)->CallObjectMethod(env, activity, getInfo) : NULL;
	jstring dir = NULL;
	if (info != NULL) {
		jclass infoClass = (*env)->GetObjectClass(env, info);
		jfieldID field = (*env)->GetFieldID(env, infoClass, "nativeLibraryDir", "Ljava/lang/String;");
		if (field != NULL) dir = (jstring)(*env)->GetObjectField(env, info, field);
		(*env)->DeleteLocalRef(env, infoClass);
	}
	if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);

	if (dir != NULL) {
		const char* chars = (*env)->GetStringUTFChars(env, dir, NULL);
		lua_pushstring(L, chars);
		(*env)->ReleaseStringUTFChars(env, dir, chars);
		(*env)->DeleteLocalRef(env, dir);
	} else {
		lua_pushnil(L);
	}
	if (info != NULL) (*env)->DeleteLocalRef(env, info);
	(*env)->DeleteLocalRef(env, contextClass);
}

void android_main(struct android_app* app)
{
	lua_State* L = luaL_newstate();
	if (L == NULL) { ANativeActivity_finish(app->activity); return; }

	luaL_openlibs(L);

	/* Native extensions are extracted beside the bundle by its loader, which
	 * writes relative to the process working directory. Android starts the
	 * process at "/", where an app cannot write; its own data directory is
	 * where the extracted .so files belong. */
	if (app->activity->internalDataPath != NULL) {
		chdir(app->activity->internalDataPath);
	}

	lua_pushlightuserdata(L, app);
	lua_setglobal(L, "LDE_ANDROID_APP");
	lde_push_native_library_dir(L, app);
	lua_setglobal(L, "LDE_ANDROID_LIBDIR");

	if (luaL_loadbuffer(L, (const char*)lde_bundle_start,
			(size_t)(lde_bundle_end - lde_bundle_start), "@bundle") != LUA_OK
		|| lua_pcall(L, 0, 0, 0) != LUA_OK) {
		__android_log_write(ANDROID_LOG_ERROR, "lde", lua_tostring(L, -1));
	}

	lua_close(L);

	/* Lua code may attach this thread to the VM for JNI calls; ART aborts the
	 * process if an attached native thread exits, so detach before returning. */
	JavaVM* vm = app->activity->vm;
	JNIEnv* env = NULL;
	if ((*vm)->GetEnv(vm, (void**)&env, JNI_VERSION_1_6) == JNI_OK) {
		(*vm)->DetachCurrentThread(vm);
	}

	ANativeActivity_finish(app->activity);
}
]==]

---@param value string?
---@return string[]
local function split(value)
	local parts = {}
	local text = value or ""
	for part in string.gmatch(text, "%S+") do
		parts[#parts + 1] = part
	end
	return parts
end

---@param bin string
---@param args string[]
---@param opts table?
local function run(bin, args, opts)
	local code, stdout, stderr = process.exec(bin, args, opts or {})
	if code ~= 0 then
		error(bin .. " failed (" .. tostring(code) .. "): " .. (stderr or stdout or ""))
	end
	return stdout or ""
end

---@param name string
---@param versionArgs string[]
local function findTool(name, versionArgs)
	local override = env.var("LDE_" .. name:upper())
	if override and override ~= "" then return override end
	local code = process.exec(name, versionArgs)
	if code == 0 then return name end
	error("android: cannot find " .. name .. " on PATH")
end

local function highestNdk(sdk)
	local ndkDir = path.join(sdk, "ndk")
	if not fs.isdir(ndkDir) then
		local bundle = path.join(sdk, "ndk-bundle")
		return fs.isdir(bundle) and bundle or nil
	end

	local names = {}
	for entry in fs.readdir(ndkDir) do
		names[#names + 1] = entry.name
	end
	table.sort(names)
	local best = names[#names]
	return best and path.join(ndkDir, best) or nil
end

local function ndkRoot()
	local explicit = env.var("LDE_ANDROID_NDK")
		or env.var("ANDROID_NDK_HOME")
		or env.var("ANDROID_NDK_ROOT")
	if explicit and explicit ~= "" then return explicit end

	local sdk = env.var("ANDROID_HOME") or env.var("ANDROID_SDK_ROOT")
	if sdk and sdk ~= "" then
		local found = highestNdk(sdk)
		if found then return found end
	end

	local home = os.getenv("HOME")
	if home and home ~= "" then
		local mac = path.join(home, "Library", "Android", "sdk")
		local linux = path.join(home, "Android", "Sdk")
		local found = highestNdk(mac) or highestNdk(linux)
		if found then return found end
	end
end

local function hostTag()
	local osName = jit.os == "Windows" and "windows" or jit.os == "OSX" and "darwin" or "linux"
	local arch = jit.arch == "arm64" and "arm64" or "x86_64"
	return osName .. "-" .. arch
end

local function glueDir()
	local explicit = env.var("LDE_ANDROID_GLUE")
	if explicit and explicit ~= "" then return explicit end
	local ndk = ndkRoot()
	if ndk then return path.join(ndk, "sources", "android", "native_app_glue") end
	error("android: set LDE_ANDROID_GLUE or ANDROID_NDK_HOME")
end

local function androidJar()
	local explicit = env.var("LDE_ANDROID_JAR")
	if explicit and explicit ~= "" then return explicit end

	local sdk = env.var("ANDROID_HOME") or env.var("ANDROID_SDK_ROOT") or env.var("LDE_ANDROID_SDK")
	if sdk then
		local platforms = path.join(sdk, "platforms")
		if fs.isdir(platforms) then
			local best, bestLevel
			for entry in fs.readdir(platforms) do
				local level = tonumber(entry.name:match("^android%-(%d+)$"))
				if level and (not bestLevel or level > bestLevel) then
					local jar = path.join(platforms, entry.name, "android.jar")
					if fs.exists(jar) then
						best, bestLevel = jar, level
					end
				end
			end
			if best then return best end
		end
	end

	error("android: set LDE_ANDROID_JAR or ANDROID_HOME")
end

local function sysroot()
	local ndk = ndkRoot()
	if not ndk then return nil end
	local root = path.join(ndk, "toolchains", "llvm", "prebuilt", hostTag(), "sysroot")
	if fs.isdir(root) then return root end
end

--- The NDK's clang wrapper, e.g. aarch64-linux-android24-clang. It already
--- carries the target, sysroot and compiler-rt builtins, so using it avoids
--- asking a host clang to link with a target runtime it does not ship.
---@param target sea.Target
---@return string?
local function ndkCompiler(target)
	local ndk = ndkRoot()
	if not ndk then return nil end

	const bin = path.join(ndk, "toolchains", "llvm", "prebuilt", hostTag(), "bin")
	const wrapper = path.join(bin, target.triple .. "-clang")
	for _, candidate in ipairs({ wrapper, jit.os == "Windows" and (wrapper .. ".cmd") or "" }) do
		if candidate ~= "" and fs.exists(candidate) then
			local code = process.exec(candidate, { "--version" })
			if code == 0 then return candidate end
		end
	end

	-- Some NDK extractions turn the `clang` symlink into a text file. Fall back
	-- to the versioned binary and pass the target/sysroot explicitly.
	local names = {}
	for entry in fs.readdir(bin) do
		if entry.name:match("^clang%-%d+$") or entry.name:match("^clang%-%d+%.exe$") then
			names[#names + 1] = entry.name
		end
	end
	table.sort(names, function(a, b)
		return (tonumber(a:match("%d+")) or 0) < (tonumber(b:match("%d+")) or 0)
	end)
	local best = names[#names]
	return best and path.join(bin, best) or nil
end

---@param compiler string
---@param target sea.Target
---@return boolean
local function isNdkWrapper(compiler, target)
	return compiler:find(target.triple .. "-clang", 1, true) ~= nil
end

--- The NDK clang wrapper for a target, or nil when no NDK is installed. A
--- native dependency built for Android must use this rather than a host clang:
--- the wrapper carries the sysroot and target runtime that a bare
--- `clang --target=aarch64-linux-android` does not.
---@param target sea.Target
---@return string?
function android.getNDKCompiler(target)
	return ndkCompiler(target)
end

---@param target sea.Target
---@param compiler string
---@param stage string
local function compileShim(target, compiler, stage)
	local ljPath = targetModule.getLuajitPath(compiler, target)
	local glue = glueDir()
	local glueC = path.join(glue, "android_native_app_glue.c")
	if not fs.exists(glueC) then
		error("android: missing " .. glueC)
	end

	local cc = env.var("LDE_ANDROID_CC")
	local isWrapper = false
	if not cc then
		cc = ndkCompiler(target)
		if not cc then
			error("android: cannot find an NDK clang under " .. tostring(ndkRoot())
				.. ". Set ANDROID_NDK_HOME or LDE_ANDROID_CC.")
		end
		isWrapper = isNdkWrapper(cc, target)
	end

	local args = {
		"-shared", "-fPIC", "-O2",
		"-I" .. path.join(ljPath, "include"),
		"-I" .. glue,
		"shim.c", glueC, "bundle.S",
		path.join(ljPath, "lib", "libluajit.a"),
		"-landroid", "-llog", "-ldl", "-lm",
		"-Wl,-z,max-page-size=16384",
		"-Wl,-soname,libmain.so",
		"-o", "libmain.so",
	}

	local root = sysroot()
	if root and not isWrapper then
		args[#args + 1] = "--target=" .. target.triple
		args[#args + 1] = "--sysroot=" .. root
	end

	for _, flag in ipairs(split(env.var("LDE_ANDROID_CFLAGS"))) do
		table.insert(args, #args - 1, flag)
	end
	for _, flag in ipairs(split(env.var("LDE_ANDROID_LDFLAGS"))) do
		table.insert(args, #args - 1, flag)
	end

	run(cc, args, { cwd = stage })

	local out = path.join(stage, "libmain.so")
	if not fs.exists(out) then
		error("android: libmain.so was not produced")
	end
	return out
end

local function xmlEscape(value)
	return (tostring(value):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

---@param opts table
local function manifest(opts)
	local permissions = {}
	for _, name in ipairs(opts.permissions or {}) do
		permissions[#permissions + 1] = string.format('\t<uses-permission android:name="%s" />\n', xmlEscape(name))
	end
	return string.format([[
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
	package="%s" android:versionCode="%d" android:versionName="%s">
%s	<uses-feature android:name="android.hardware.vulkan.version" android:required="false" />
	<uses-feature android:name="android.hardware.touchscreen" android:required="false" />
	<application android:hasCode="false" android:extractNativeLibs="true"%s
		android:label="%s" android:theme="@android:style/Theme.NoTitleBar.Fullscreen">
		<activity android:name="android.app.NativeActivity" android:exported="true"
			android:screenOrientation="fullSensor"
			android:configChanges="orientation|screenSize|keyboardHidden|screenLayout|smallestScreenSize|uiMode">
			<meta-data android:name="android.app.lib_name" android:value="main" />
			<intent-filter>
				<action android:name="android.intent.action.MAIN" />
				<category android:name="android.intent.category.LAUNCHER" />
			</intent-filter>
		</activity>
	</application>
</manifest>
]], opts.packageName, opts.versionCode, xmlEscape(opts.versionName), table.concat(permissions),
		opts.icon and ' android:icon="@mipmap/ic_launcher"' or "", xmlEscape(opts.label))
end

---@param keystore string
---@param keytool string
local function ensureKeystore(keystore, keytool)
	if fs.exists(keystore) then return end
	fs.mkdirAll(path.dirname(keystore))
	run(keytool, {
		"-genkeypair", "-v",
		"-keystore", keystore,
		"-storepass", "android",
		"-alias", "androiddebugkey",
		"-keypass", "android",
		"-keyalg", "RSA",
		"-keysize", "2048",
		"-validity", "10000",
		"-dname", "CN=Android Debug,O=Android,C=US",
	})
end

-- e_machine values in the ELF header, for the ABIs the APK targets build.
---@type table<string, number>
local ELF_MACHINE = { ["arm64-v8a"] = 183, ["x86_64"] = 62 }

--- The ELF machine a shared library was built for, or nil when the file is not ELF.
---@param file string
---@return number?
local function elfMachine(file)
	local f = io.open(file, "rb")
	if not f then return nil end
	local header = f:read(20)
	f:close()
	if not header or #header < 20 or header:sub(1, 4) ~= "\127ELF" then return nil end
	local lo, hi = header:byte(19, 20)
	return lo + hi * 256
end

--- Refuse a library the app names that is built for another machine: it would install and
--- then fail at dlopen on the device, far from its cause.
---@param file string
---@param target sea.Target
local function checkMachine(file, target)
	local want = ELF_MACHINE[target.abi or "arm64-v8a"]
	local machine = elfMachine(file)
	if machine == nil then
		error("android: not an ELF shared library: " .. file)
	end
	if want and machine ~= want then
		error(string.format("android: %s is built for ELF machine %d, not %s. Rebuild it for %s.",
			file, machine, target.abi, target.name))
	end
end

--- The file name a native module ships under in the APK. Android installs only `lib*.so`.
---@param module string # dotted module name, e.g. "image.stb"
---@return string
local function moduleFileName(module)
	return "libldemod_" .. module:gsub("[^%w]", "_") .. ".so"
end

--- Lua run before the bundle: points `require` and `ffi.load` at the native modules shipped
--- in the APK's library directory, under the names `moduleFileName` gave them. Desktop
--- executables do the same by extracting libraries to a temporary directory; an APK can't,
--- since Android does not map code from writable storage.
---@param modules { name: string }[]
---@return string
local function nativePrologue(modules)
	local entries = {}
	for _, module in ipairs(modules) do
		entries[#entries + 1] = string.format("[%q]=%q", module.name, moduleFileName(module.name))
	end
	return string.format([[
do
	local dir = rawget(_G, "LDE_ANDROID_LIBDIR")
	local files = {%s}
	if dir and next(files) then
		local ffi = require("ffi")
		local map = {}
		for name, file in pairs(files) do
			local full = dir .. "/" .. file
			local leaf = name:match("[^.]+$")
			local bare = leaf:match("^lib(.+)$") or leaf
			local slashed = name:gsub("%%.", "/")
			for _, key in ipairs({ name, leaf, bare, leaf .. ".so", "lib" .. bare .. ".so", slashed .. ".so" }) do
				map[key] = full
			end
			-- A C module answers to require through this; an FFI-only library has no
			-- luaopen_ and is reached through ffi.load below. The bundle runs after this
			-- and overwrites the entry when a Lua module has the same name.
			package.preload[name] = function()
				local open = package.loadlib(full, "luaopen_" .. name:gsub("[.-]", "_"))
				if not open then error("module '" .. name .. "' has no luaopen_ entry", 2) end
				return open(name)
			end
		end
		local load = ffi.load
		ffi.load = function(lib, global)
			local hit = map[lib] or map[lib:match("[^/\\]+$")]
			return load(hit or lib, global)
		end
	end
end
]], table.concat(entries, ", "))
end

---@param main string
---@param source string # Lua source bundle, without native libraries
---@param compiler string
---@param targetName string
---@param opts? { packageName: string?, label: string?, versionName: string?, versionCode: number?, icon: string?, permissions: string[]?, libs: string[]?, modules: { name: string, path: string }[]? } # icon: a PNG shown in the launcher; permissions: `uses-permission` names for the manifest; modules: native modules of the dependency tree, shipped in the APK and reached through require/ffi.load
---@return string apkPath
function android.compileAPK(main, source, compiler, targetName, opts)
	opts = opts or {}
	local target = assert(targetModule.getTarget(targetName))
	if target.kind ~= "apk" then
		error("android: " .. targetName .. " is not an APK target")
	end

	local packageName = opts.packageName or ("dev.lde." .. main:gsub("[^%w_]", "_"):lower())
	local label = opts.label or main
	local versionName = opts.versionName or "0.1.0"
	local versionCode = tonumber(opts.versionCode) or 1

	local token = tostring({}):match("0x(%x+)$") or tostring(os.time())
	local stage = path.join(env.tmpdir(), "lde-apk-" .. token)
	local out = path.join(env.tmpdir(), "lde-apk-" .. token .. ".apk")
	fs.mkdirAll(stage)

	-- Native modules from the dependency tree go to the APK's native library directory, the
	-- only place Android maps app code from. A build cache can hold the same library for
	-- several machines side by side (one per toolchain), so only this ABI's copies ship.
	local abi = target.abi or "arm64-v8a"
	local want = ELF_MACHINE[abi]
	---@type { name: string, path: string }[]
	local modules = {}
	for _, module in ipairs(opts.modules or {}) do
		if elfMachine(module.path) == want then
			modules[#modules + 1] = module
		end
	end

	fs.write(path.join(stage, "shim.c"), SHIM_C)
	fs.write(path.join(stage, "bundle.lua"), nativePrologue(modules) .. source)
	fs.write(path.join(stage, "bundle.S"), [[
.globl lde_bundle_start
lde_bundle_start:
.incbin "bundle.lua"
.globl lde_bundle_end
lde_bundle_end:
]])
	fs.write(path.join(stage, "AndroidManifest.xml"), manifest({
		packageName = packageName,
		label = label,
		versionName = versionName,
		versionCode = versionCode,
		permissions = opts.permissions,
		icon = opts.icon ~= nil,
	}))

	compileShim(target, compiler, stage)

	local aapt2 = findTool("aapt2", { "version" })
	local apksigner = findTool("apksigner", { "version" })
	local keytool = findTool("keytool", { "-help" })
	local zip = findTool("zip", { "-h" })
	local jarPath = androidJar()

	-- The launcher icon is a resource: compiled into the flat form aapt2 links, as the one mipmap
	-- the launcher scales down from.
	local resources = {}
	if opts.icon ~= nil then
		if not fs.exists(opts.icon) then
			error("android: icon not found: " .. tostring(opts.icon))
		end
		local mipmap = path.join(stage, "res", "mipmap-xxxhdpi")
		fs.mkdirAll(mipmap)
		fs.copy(opts.icon, path.join(mipmap, "ic_launcher.png"))
		local compiled = path.join(stage, "res.zip")
		run(aapt2, { "compile", "--dir", path.join(stage, "res"), "-o", compiled }, { cwd = stage })
		resources = { "-R", compiled }
	end

	local unsigned = path.join(stage, "unsigned.apk")
	local linkArgs = {
		"link",
		"-o", unsigned,
		"-I", jarPath,
		"--manifest", path.join(stage, "AndroidManifest.xml"),
		"--min-sdk-version", tostring(target.apiLevel or 24),
		"--target-sdk-version", "35",
		"--version-code", tostring(versionCode),
		"--version-name", versionName,
	}
	for _, arg in ipairs(resources) do linkArgs[#linkArgs + 1] = arg end
	run(aapt2, linkArgs, { cwd = stage })

	local libDir = path.join(stage, "lib", abi)
	fs.mkdirAll(libDir)
	fs.copy(path.join(stage, "libmain.so"), path.join(libDir, "libmain.so"))

	-- Extra shared libraries an app brings with it -- a text engine, a codec --
	-- are loaded by the platform's own loader, so they have to be in the APK's
	-- native library directory rather than in the Lua bundle. The app names
	-- them in `android.libs`; each keeps its file name, which is the SONAME
	-- the loader looks for.
	for _, lib in ipairs(opts.libs or {}) do
		if not fs.exists(lib) then
			error("android: extra library not found: " .. tostring(lib))
		end
		checkMachine(lib, target)
		fs.copy(lib, path.join(libDir, path.basename(lib)))
	end

	-- The package manager installs only `lib*.so` files from the APK, so each module is
	-- renamed to the `libldemod_<module>.so` the prologue maps it from.
	for _, module in ipairs(modules) do
		fs.copy(module.path, path.join(libDir, moduleFileName(module.name)))
	end
	run(zip, { "-q", "-r", unsigned, "lib" }, { cwd = stage })

	local aligned = path.join(stage, "aligned.apk")
	local zipalign = env.var("LDE_ZIPALIGN")
	if zipalign and zipalign ~= "" then
		run(zipalign, { "-f", "4", unsigned, aligned }, { cwd = stage })
	else
		local code = process.exec("zipalign", { "-h" })
		if code == 0 then
			run("zipalign", { "-f", "4", unsigned, aligned }, { cwd = stage })
		else
			fs.copy(unsigned, aligned)
		end
	end

	local keystore = env.var("LDE_ANDROID_KEYSTORE")
		or path.join(os.getenv("HOME") or ".", ".android", "debug.keystore")
	ensureKeystore(keystore, keytool)

	run(apksigner, {
		"sign",
		"--ks", keystore,
		"--ks-pass", "pass:android",
		"--key-pass", "pass:android",
		"--ks-key-alias", "androiddebugkey",
		"--out", out,
		aligned,
	}, { cwd = stage })
	run(apksigner, { "verify", out })

	fs.rmdir(stage)
	return out
end

return android
