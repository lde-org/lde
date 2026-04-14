# lde

`lde` is a package manager and toolkit for Lua, written in Lua and running on LuaJIT. It manages project-local dependencies, runs Lua programs, and compiles them into single executables.

## Repo Structure

```
packages/
  lde/          # The CLI binary itself (entry: src/init.lua)
  lde-core/     # Core library: Package, Lockfile, runtime, install logic
  lde-test/     # Built-in test framework
  ansi/clap/env/fs/git/http/json/path/process2/semver/util/  # Internal packages
  sea/          # Single-executable assembly (compiles bundles into binaries)
  archive/      # Archive extraction support
  luarocks/     # LuaRocks integration
  rocked/       # Rockspec support
  readline/     # Readline support
schemas/        # JSON schema for lde.json
tests/          # Top-level integration test fixtures (e.g. some-package/)
```

Each package has:
- `src/` — source files (or `src/init.lua` as the entry point)
- `lde.json` — package manifest
- `lde.lock` — lockfile (auto-generated, commit this)
- `target/` — build output (never commit this)
- `tests/` — test files matching `**/*.test.lua`
- `build.lua` — optional build script (only if the package needs compilation)

## `lde.json` Config

```jsonc
{
  "name": "my-package",
  "version": "0.1.0",
  "description": "...",
  "authors": ["..."],
  "bin": "src/main.lua",          // optional, overrides default entry (src/init.lua via target/<name>)
  "engine": "lde",                // "lde" (default), "lua", or "luajit"
  "scripts": { "build": "..." },  // runnable via `lde <name>` or `lde run <name>`
  "dependencies": {
    "json":    { "path": "../json" },                    // local path dep
    "hood":    { "git": "https://...", "commit": "abc123", "branch": "main" }, // git dep
    "semver":  { "version": "1.0.0" },                  // lde registry dep
    "mylib":   { "luarocks": "luafilesystem" },          // luarocks dep
    "archive": { "archive": "https://.../x.zip" },       // archive dep
    "winapi":  { "git": "...", "optional": true }        // optional dep
  },
  "devDependencies": { ... },
  "features": {
    "windows": ["winapi"],   // optional deps enabled per platform
    "linux":   ["..."],
    "macos":   ["..."]
  }
}
```

- Lockfile is `lde.lock`. Commit it. The `target/` directory is build output — never commit it.
- The **require name** for a dependency is the **key** in `dependencies`, not the package's `name` field. You can alias a package by using a different key.
- `name` in a dep entry overrides the package name used for registry/git lookup (for aliasing).

## How `require()` Paths Are Resolved

`lde install` / `lde run` populate `target/` with symlinks (or copies for packages with a build script). Each dep is installed at `target/<alias>`.

`package.path` is set to:
```
target/?.lua
target/?/init.lua
target/?.so  (or .dll / .dylib)
```

So `require("json")` → `target/json/init.lua` → symlink to `packages/json/src/init.lua`.

During `lde test`, `tests/` is also exposed as `target/tests`, so test files can do:
```lua
local helper = require("tests.lib.something")  -- resolves to tests/lib/something.lua
```

## Build System

- `lde run` / `lde test` both call `pkg:build()` + `pkg:installDependencies()` automatically.
- **No build script**: `src/` is symlinked directly to `target/<name>`.
- **With `build.lua`**: it is executed with `LDE_OUTPUT_DIR` set to the output path (`target/<name>`). The script is responsible for writing files there.
- `target/.installed` stores an FNV1a hash of `lde.lock` — if it matches, install is skipped entirely (fast path).
- Git dependencies are cloned with `--recurse-submodules`.

## Package API (`lde-core`)

`require("lde-core")` returns a table with:
- `lde.Package` — the Package class
- `lde.Lockfile` — the Lockfile class
- `lde.global` — global state/cache helpers
- `lde.runtime` — isolated script execution
- `lde.util` — internal utilities
- `lde.verbose` — boolean, set to `true` in the CLI to show progress output

### `lde.Package`

```lua
local pkg, err = lde.Package.open(dir)       -- opens lde.json or rockspec
local pkg, err = lde.Package.openLDE(dir)    -- opens lde.json only

pkg:getDir()             -- package root directory
pkg:getName()            -- reads name from lde.json
pkg:readConfig()         -- returns lde.Package.Config (cached, invalidated on mtime change)
pkg:readLockfile()       -- returns lde.Lockfile or nil
pkg:getDependencies()    -- merged config+lockfile deps (lockfile wins for pinned commits)
pkg:getDevDependencies() -- devDependencies table
pkg:getModulesDir()      -- target/
pkg:getTargetDir()       -- target/<name>
pkg:getSrcDir()          -- src/
pkg:getTestDir()         -- tests/
pkg:getBuildScriptPath() -- build.lua
pkg:hasBuildScript()     -- true if build.lua exists or buildfn is set
pkg:build(destPath)      -- runs build script or symlinks src/ into target/<name>
pkg:installDependencies(deps, relativeTo, features)  -- installs all deps into target/
pkg:runFile(path, args, vars)    -- runs a Lua file in isolated runtime
pkg:runString(code, args, vars)  -- runs a Lua string in isolated runtime
pkg:runScript(name, capture)     -- runs a script from lde.json scripts table
pkg:runTests()           -- runs all *.test.lua files
pkg:bundle()             -- bundles into a single Lua file
pkg:compile()            -- compiles into a single executable
```

### `lde.global`

Manages the global `~/.lde/` directory (git cache, archive cache, registry, tools).

```lua
lde.global.getDir()              -- ~/.lde
lde.global.getGitCacheDir()      -- ~/.lde/git
lde.global.getTarCacheDir()      -- ~/.lde/tar
lde.global.getRegistryDir()      -- ~/.lde/registry
lde.global.getToolsDir()         -- ~/.lde/tools
lde.global.currentVersion        -- e.g. "0.9.0"

lde.global.getOrInitGitRepo(name, url, branch, commit)  -- clones if not cached, returns dir
lde.global.getOrInitArchive(url)                        -- downloads+extracts if not cached, returns dir
lde.global.syncRegistry()                               -- clones/pulls the lde registry
lde.global.lookupRegistryPackage(name)                  -- returns portfile table or nil, err
lde.global.resolveRegistryVersion(portfile, version)    -- returns version, commit
lde.global.writeWrapper(toolName, packageDir, pkgName)  -- writes ~/.lde/tools/<name> wrapper script
lde.global.init()                                       -- ensures ~/.lde dirs exist
```

### `lde.runtime`

Executes Lua in an isolated environment (clears `package.loaded`, fresh `_G` metatable, patches `ffi.cdef`).

```lua
lde.runtime.executeFile(path, opts)    -- runs a file
lde.runtime.executeString(code, opts)  -- runs a string

-- opts: { env, args, globals, packagePath, packageCPath, preload, cwd }
```

## Key Internal Packages

### `fs`

```lua
fs.read(path)                    -- returns string or nil
fs.write(path, content)          -- returns boolean
fs.exists(path)                  -- boolean
fs.isdir(path)                   -- boolean
fs.isfile(path)                  -- boolean
fs.islink(path)                  -- boolean
fs.mkdir(path)                   -- boolean
fs.mklink(src, dest)             -- creates symlink
fs.rmlink(path)                  -- removes symlink/junction
fs.rmdir(path)                   -- recursive delete
fs.delete(path)                  -- os.remove wrapper
fs.copy(src, dest)               -- recursive copy
fs.move(old, new)                -- rename or copy+delete
fs.stat(path)                    -- { size, accessTime, modifyTime, type, mode }
fs.lstat(path)                   -- same but doesn't follow symlinks
fs.readdir(path)                 -- iterator of { name, type } entries
fs.scan(cwd, glob, opts)         -- returns string[] of relative paths matching glob
                                 -- opts: { absolute: boolean, followSymlinks: boolean }
```

### `ansi`

```lua
ansi.printf("{red}msg %s", val)          -- colored print (resets at end)
ansi.format("{green}msg %s", val)        -- returns colored string
ansi.colorize("blue", str)               -- wraps str in color codes
ansi.clearLine()                         -- clears current terminal line

local p = ansi.progress("label")        -- shows spinner line
p:done("optional done msg")             -- replaces line with ✓
p:fail("optional fail msg")             -- replaces line with ✗
```

Available colors: `reset red green yellow blue magenta cyan white gray bold` and `bg_*` variants.

### `clap`

```lua
local args = clap.parse({ ... })   -- parse raw arg list (pass `{...}` from script)

args:pop()                  -- removes and returns next positional arg
args:peek()                 -- returns next positional arg without removing
args:flag("name")           -- returns true if --name present (removes it)
args:option("name")         -- returns value of --name or --name=val (removes it)
args:short("x")             -- returns value of -x or -x=val (removes it)
args:drain(start)           -- returns and removes all remaining args (or from index)
args:count()                -- number of remaining args
```

### `process2`

```lua
-- Blocking execution
local code, stdout, stderr = process.exec("git", { "clone", url }, opts)

-- Async
local child, err = process.spawn("cmd", args, opts)
child:wait()    -- returns code, stdout, stderr
child:poll()    -- returns exit code or nil if still running
child:kill(force)

-- opts: { cwd, env, stdin, stdout, stderr }
-- stdout/stderr: "pipe" (default for exec), "inherit", "null"

process2.platform  -- "linux", "darwin", "win32", "unix"
```

### `env`

```lua
env.var("NAME")          -- get env var
env.set("NAME", value)   -- set env var (nil to unset)
env.cwd()                -- current working directory
env.chdir(dir)           -- change directory
env.tmpdir()             -- system temp directory
env.tmpfile()            -- unique temp file path (safe on all platforms)
env.execPath()           -- path to the current lde executable
```

### `path`

```lua
path.join(a, b, ...)     -- joins with OS separator
path.basename(p)         -- filename portion
path.dirname(p)          -- directory portion
path.extension(p)        -- file extension (without dot)
path.normalize(p)        -- resolves . and ..
path.resolve(base, rel)  -- resolves relative path against base
path.relative(from, to)  -- relative path from -> to
path.isAbsolute(p)       -- boolean
path.parts(p)            -- iterator over path segments
path.separator           -- "/" or "\\"
```

### `git`

```lua
git.clone(url, dir, branch, commit)   -- clones with --recurse-submodules
git.pull(repoDir)
git.checkout(commit, repoDir)
git.getCommitHash(cwd, ref)           -- returns ok, hash
git.init(dir, bare)
git.isInsideWorkTree(dir)
git.remoteGetUrl(remoteName, cwd)
git.getCurrentBranch(cwd)
git.version()
```

## Test Framework (`lde-test`)

Test files must match `**/*.test.lua`.

```lua
local test = require("lde-test")

test.it("does something", function()
  test.equal(a, b)
  test.notEqual(a, b)
  test.truthy(x)
  test.falsy(x)
  test.deepEqual(t1, t2)      -- recursive, checks metatables
  test.match(actual, expected) -- like jest toMatchObject (subset match)
  test.includes(str, substr)
  test.greater(a, b)
  test.less(a, b)
  test.greaterEqual(a, b)
  test.lessEqual(a, b)
end)

test.skip("skipped test", function() end)
test.skipIf(condition)("name", function() end)
```

Run tests: `lde test` (from a package dir, or from repo root to run all packages).

## Running Lua Code for Inspection/Testing

**Never use `luajit` directly.** Always use `lde` to run Lua so the correct runtime context, package paths, and built-in modules are available.

```sh
# Run a one-liner inside the lde context (from any package dir)
lde -e "print(require('json').encode({x=1}))"

# Run a specific file
lde ./path/to/file.lua

# Run a specific file with args
lde ./path/to/file.lua -- arg1 arg2
```

`lde -e` runs the expression/statement with all installed deps available (same as `lde run` but inline). `lde ./file` runs a file directly using the current package's dep tree.

## Updating the `lde` Binary

After making changes to any package source, rebuild the binary:

```sh
cd packages/lde
lde compile
```

This outputs `packages/lde/lde` (or `lde.exe` on Windows). To install it globally: copy to `~/.lde/lde`.

**Important:** Tests in `packages/lde/tests/` run the actual `lde` CLI binary via `env.execPath()`. If those tests fail after source changes, recompile and replace the binary first.

## Managing Dependencies

Always use `lde add` / `lde remove` instead of manually editing `lde.json`. Manual edits leave `lde.lock` out of sync and can break installs.

```sh
# Add a local path dep
lde add json --path ../json

# Add a git dep (commit is resolved and pinned automatically)
lde add hood --git https://github.com/codebycruz/hood
lde add hood --git https://github.com/codebycruz/hood --branch main

# Add a registry dep
lde add semver@1.0.0

# Remove a dep
lde remove hood
```

## Monorepo Conventions

- All packages live in `packages/` and depend on each other via `{ "path": "../<pkg>" }`.
- The `lde` package's `lde.json` lists all sibling packages as path dependencies.
- When adding a new internal package, add it to `packages/lde/lde.json` as a path dep.
- `lde-core` uses `package.loaded[(...)] = lde` early to allow circular requires within the package.

## Bootstrap Mode

`lde` can be built with `BOOTSTRAP=1` using stock LuaJIT (no existing `lde` binary required). In this mode, `packages/lde/src/init.lua` manually creates symlinks in `target/` for all dependencies instead of using the normal install flow.

```sh
BOOTSTRAP=1 luajit packages/lde/src/init.lua compile
```

## Naming

The project was previously named `lpm`. You may see `lpm.json` or `lpm-test` references in older code — always use the `lde` equivalents (`lde.json`, `lde-test`) when writing new code. The compat aliases are handled internally.

## Global Cache Layout

```
~/.lde/
  git/          # cloned git repos, keyed as <name>[-branch][-commit]
  tar/          # extracted archives, keyed by sanitized URL
  registry/     # cloned lde registry (git repo)
  rockspecs/    # cached rockspec files
  tools/        # wrapper scripts installed by `lde install --global`
  mingw/        # MinGW toolchain (Windows only, for compiling C extensions)
  config.json   # global lde config
```

## CI Build Architecture

`lde compile` links against `libluajit` from [lj-dist](https://github.com/lde-org/lj-dist) using a C compiler controlled by `SEA_CC`. Linux and macOS use the system compiler. Windows and Android need special toolchains.

**Windows:** The system GCC on `windows-latest` targets msvcrt, but lj-dist's `libluajit` is built against UCRT. This causes linker errors (`undefined reference to __imp_fseeko64` etc). CI downloads [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (a Clang/LLD MinGW-w64 toolchain targeting UCRT) and sets `SEA_CC`:

| Runner | `SEA_CC` |
|---|---|
| `windows-latest` | `x86_64-w64-mingw32-clang` |
| `windows-11-arm` | `aarch64-w64-mingw32-clang` |

**Android:** Android uses Bionic rather than glibc. The binary is compiled on the host using the Android NDK's clang (`aarch64-linux-android21-clang`), which links against Bionic. Tests run inside a Termux Docker container (`termux/termux-docker:aarch64` under QEMU on the ARM64 runner), which provides a matching Bionic environment.