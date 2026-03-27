---
title: Build Scripts
order: 4
---

# Build Scripts

Projects may contain a build script at the top level outside of the source directory, named `build.lua`.

This is for the sake of doing things like building native dependencies, or preprocessing your code from one language (ie, Teal) to Lua.

It is provided the environment variable `LDE_OUTPUT_DIR` you can access with `os.getenv("LDE_OUTPUT_DIR")`, which will be the path to the output directory for your project, ie `./target/myproject`.

When a build script is present, LDE will intentionally create a folder and clone the source directory of the project first, so the files are available, and are mutable as they won't be symlinked.

Do file operations to this folder. Add .so file, modify files, all you need. Users will get types from the resulting ./target/ folder, so you can even do code generation.

## Example: Native Module

Here's an example that builds [luafilesystem](https://github.com/lunarmodules/luafilesystem) and places it in your `target` directory, to be required as normal!

```lua
local outDir = os.getenv("LDE_OUTPUT_DIR")
local parentDir = outDir:match("^(.*)/[^/]+$")

os.execute("rm -rf " .. outDir)
os.execute("make")

os.execute("cp './src/lfs.so' '" .. parentDir .. "/lfs.so'")
```

## Example: Preprocessing

This example is used in the [hood](https://github.com/codebycruz/hood) graphics library to include C header files into ffi.cdefs.

```lua
local separator = string.sub(package.config, 1, 1)
local outDir = os.getenv("LDE_OUTPUT_DIR")

local function read(p)
	local handle = io.open(p, "r")
	local content = handle:read("*a")
	handle:close()
	return content
end

local init = read(outDir .. separator .. "init.lua")

local escapes = {
	["\\"] = "\\\\",
	["\""] = "\\\"",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t"
}

local preprocessed = string.gsub(init, "%[%[#embed \"([^\"]+)\"%]%]", function(filename)
	local content = read(outDir .. separator .. filename)
	return '"' .. (content:gsub("[\\\"\n\r\t]", escapes)) .. '"'
end)

local outFile = io.open(outDir .. separator .. "init.lua", "w")
outFile:write(preprocessed)
outFile:close()
```
