---
title: Release v0.10.0
author: David Cruz
published: 2026-08-03
description: A runtime rewrite built on the Lua C API after months of work, plus lde test --watch, a built-in profiler, LuaJIT v3 syntax, and a much faster startup.
---

> Upgrade to the latest version with `lde upgrade`!

## The runtime rewrite

It has been months since 0.9.1. This release is late on purpose. Most of that time went into one thing: reworking how lde runs your code. It is a lot to do justice in one blog post, so here is the short version. lde now embeds LuaJIT the way a C program would, through the Lua C API, instead of running LuaJIT inside of itself.

### Why the rewrite

The old way had a hard limit. LuaJIT has no way to isolate `ffi`. lde sandboxed code with `setfenv`, `debug.sethook`, and similar tools, and that handled most of Lua. It could never namespace away the `ffi` definitions. Definitions leaked between runs and went stale, which caused a steady stream of problems.

The stopgap was [ffix](https://github.com/lde-org/ffix). It worked, but it had to bring its own C parser just to detour and namespace LuaJIT symbols. That put overhead on the `ffi` library itself. Not ideal.

### The fix

The real fix was to redo how lde works from the ground up. I moved to the Lua C API, the same path C and other languages use to embed Lua. The hard requirement was speed. LuaJIT's own FFI API is not re-entrancy safe, so it could not do the job. That forced C bridges, written and then optimized repeatedly, to get a layer with minimal overhead.

The result is `lua-sys`, a clean API for using LuaJIT from LuaJIT:

```lua
local lua = require("lua-sys")

-- Create an independent guest Lua state
local state = lua.new()

-- Evaluate an expression in the guest (shorthand)
print(state:eval("return 1 + 2"))  -- 3

-- Load a chunk, then call it: chunk(...) is shorthand for chunk:eval(...)
local add = state:load("return function(a, b) return a + b end")()
print(add(1, 2))  -- 3

-- Expose host functions to guest code. Table field access is proxied
-- through __index, so g.foo works instead of g:get("foo") / g:set("foo").
local g = state:globals()
g.double = function(x) return x * 2 end
print(state:eval("return double(21)"))  -- 42

-- Plain host tables are coerced to guest tables
g.config = { timeout = 5, retries = 3 }
print(state:eval("return config.timeout"))  -- 5

-- Always close when done
state:close()
```

And it is quite fast. Cross-state calls cost about 70 to 200 nanoseconds depending on direction and argument count:

| Call path | Overhead |
|---|---|
| Host → Guest (noop) | ~70 ns |
| Host → Guest (2 args, 1 return) | ~120 ns |
| Guest → Host callback (noop) | ~130 ns |
| Host → Guest → Host round-trip | ~200 ns |

### The result

The result is a more stable, more isolated, and more secure lde. Packages no longer reach all of lde's internals, and the guest state can be sandboxed further in the future. It also opens a bigger door: `lde-test` and the rest of the standard library now depend only on the Lua C API. Any engine that provides it, Lua 5.4 and Luau included, could run them one day.

It took months of troubleshooting, finding LuaJIT bugs, balancing support across Linux, macOS, and Windows, optimizing, and changing course more than once. Other Lua package managers have appeared since. I am aware of them. I am steadfast on getting lde to a stable 1.0 release and making up for the lost time.

### What changed for you

- Every program runs in a fresh, isolated guest state. `lde run`, `lde test`, `lde -e`, and `lde ./file.lua` all get a clean `_G` and a fresh `package.loaded`. Nothing leaks between runs.
- Error traces and profiles show only your code, never lde's internals. Older versions trimmed lde frames from tracebacks so errors showed less tooling. The new runtime makes that work unnecessary.
- The test runner and the profiler in this release both run on top of the new runtime.

`lua-sys` is a regular lde package. Any project can use it:

```sh
lde add lua-sys --git https://github.com/lde-org/lua-sys
```

## Test runner upgrades

### Watch mode

`lde test --watch` re-runs your tests whenever a file in `src/` or `tests/` changes:

```sh
lde test --watch
```

![test-watch](/blog-assets/0.10.0/test-watch.gif)

The watcher monitors `src/`, `tests/`, and your `lde.json` and `build.lua` at the package root. It ignores changes under `target/`, so dependency installs do not interrupt the loop. From a monorepo root, it watches every package that has tests. Filters work in watch mode too:

```sh
lde test --watch "unit*"
```

### Failure output with code snippets

When a test fails, lde shows the code that failed. The output includes the file and line, a highlighted snippet, and a caret under the failing assertion:

```
  tests/fail.test.lua
     tests/fail.test.lua:3: Expected 1 to equal 2
     │
   1 │ local test = require("lde-test")
   2 │ test.it("fails", function()
   3 │   test.equal(1, 2)
   4 │ end)
     │          ^^^^^
     │
Tests:  1 failed, 0 passed, 1 total
```

The snippet with the caret is the new part of the output.

### Filters

`lde test` accepts one or more glob filters. A file runs when any filter matches:

```sh
lde test "unit*"
lde test "unit*" "other*"
lde test ./tests/unit.test.lua
```

A path that starts with `./` or `/` is resolved against the tests directory. When run from a monorepo root, a filter that matches no files prints `No files matched`.

### Empty suites fail

A test file that registers no tests now fails with `No tests were registered`. An empty suite used to pass silently. A typo in a `skipIf` condition no longer hides a missing suite.

## Built-in profiler

`lde run --profile` samples your program every millisecond and prints a report when it exits:

```sh
lde run --profile
```

![profile](/blog-assets/0.10.0/profile.gif)

The profiler runs inside the new isolated runtime. It samples only your program. Install, build, and module resolution never appear in the report, and lde's own execution adds no samples of its own.

The report shows two things:

- A VM state breakdown: JIT compiled, interpreted, C code, GC, and JIT compiler time.
- A hotspot table with the top 20 functions by sample count.

A profiler answers the question that guessing cannot: where does the time actually go? The VM state bars show whether the JIT compiled your hot loops, whether C code dominates, or whether the GC is the bottleneck. The hotspot table names the functions.

This is how I optimize my own code. I used it on [vkapi](https://github.com/bycruz/vkapi), my Vulkan bindings, until they were as fast as C bindings. It also found the high memory usage in [arisu](https://github.com/bycruz/arisu).

`lde run --flamegraph` writes an interactive flamegraph:

```sh
lde run --flamegraph
```

![flamegraph](/blog-assets/0.10.0/flamegraph.gif)

The file is `profile.html`. It is self-contained. Open it in any browser, hover over a frame to see its share, and click a frame to zoom. Use `--flamegraph=out.html` to write elsewhere. The profiler works for scripts too: `lde ./bench.lua --profile`.

## LuaJIT with modern syntax

lde now ships its own fork of LuaJIT at [github.com/lde-org/luajit](https://github.com/lde-org/luajit). It replaces the previous `lj-dist` distribution. The fork is the latest upstream LuaJIT plus one change: `os.tmpname()` honors `TMPDIR`. That makes lde work in Termux on Android and in containers where `/tmp` is not writable. That is the whole fork. No other changes are planned for now.

The modern syntax is upstream too. Mike Pall's backport of the v3.0 syntax extensions into the 2.1 tree ([LuaJIT/LuaJIT#1476](https://github.com/LuaJIT/LuaJIT/issues/1476)) is released, and the fork tracks [LuaJIT/LuaJIT](https://github.com/LuaJIT/LuaJIT). The syntax works today, in every command that runs code:

```lua
const retries = 5

local function fetch(url)
  return cache?.[url] ?? request(url)
end

local total = 0
for i = 1, 100 do
  if i % 2 == 0 then continue end
  total += i
end

local double = |x| -> x * 2
print(double(21))  -- 42
```

The backport adds:

- `continue` and `const`
- Safe navigation (`?.`) and nil-coalescing (`??`)
- Ternary operator (`?:`)
- `!`, `&&`, `||`, and `!=`
- Compound assignment (`+=`, `-=`, `..=`, and more)
- Bit operators (`&`, `|`, `~`, `<<`, `>>`, and `~>>`)
- Short function expressions (`|x| -> x * 2`)
- Underscores in number literals (`1_000_000`)

Code that does not use the new syntax stays compatible with stock LuaJIT. The backport sets a bytecode flag only when a bit operator is used.

![v3-syntax](/blog-assets/0.10.0/v3-syntax.gif)

## Faster installs

### Parallel downloads

Dependency sources now download in parallel. lde walks the dependency graph, then fetches every known source in one batch:

![parallel-install](/blog-assets/0.10.0/parallel-install.gif)

A single progress bar shows the count, for example `3/5`. The resolution that follows reads from the local cache instead of the network.

### Git dependencies from tarballs

For GitHub and GitLab, lde downloads the repository as a tarball instead of running a full `git clone`. A tarball is smaller and downloads faster. The commit is still pinned, and the result is cached like before.

The tradeoff: a tarball has no submodules. Git dependencies that rely on submodules will not get them on these hosts. The tarball shortcut only works on hosts with archive endpoints, like GitHub and GitLab, and potentially others with the same convention. Other hosts fall back to `git clone`, submodules included.

### Faster LuaRocks lookups

LuaRocks lookups use a persisted URL cache. The full manifest scan runs only on a cache miss. Repeated installs skip the download and the scan.

## Git cache fixes

The git cache got several fixes:

- Cache entries are keyed by resolved commit. A moved branch can no longer reuse a stale entry for the wrong commit.
- `lde update` writes the new commit to the lockfile, so an update actually sticks.
- Cached content is consumed without re-resolving or re-downloading.

The result: stale entries in `~/.lde/git` should stop forcing manual cache deletion. With luck, you will not need to delete that folder again before 1.0.

## Faster startup

The `lde` binary starts faster. The shipped builds are compiled to bytecode, and most modules load lazily. `lde --version` and `lde -e` take a fast path that avoids loading the full runtime.

![startup](/blog-assets/0.10.0/startup.png)

Startup dropped from ~15ms to <1ms. Pretty good, considering it beats cli tools written in Rust, like lux, by 4x, and even Bun, which is notoriously fast.

## Build scripts with `lde-build`

`lde-build` replaces the very rudimentary `build.lua` setup that was there before. The old setup just provided an environment variable saying where to put files, and left you on your own. The new API is rich. It provides a C compiler, filesystem functions that write relative to the output directory, and HTTP fetch. It basically turns your dumb `build.lua` into something as capable as cmake, for free.

A build script is a Lua file at the root of a package. lde runs it instead of symlinking `src/`, and the script builds the package in the output directory:

```lua
local build = require("lde-build")

build:fetch("https://example.com/lib.tar.gz")  -- HTTP GET, returns the body
build:extract("lib.tar.gz", "lib")
build:sh("./configure --prefix=.")
build:cc({ "-c", "lib/foo.c", "-o", "lib/foo.o" })
build:copy("lib/foo.o", ".")
```

The full method set:

- `fetch(url)` downloads a URL and returns the body
- `write(rel, content)` and `read(rel)` handle files in the output dir
- `extract(rel, dest)` unpacks archives
- `copy`, `move`, `delete`, and `exists` manage files
- `sh(cmd)` runs a shell command and fails the build on a non-zero exit
- `cc(args)` runs the C compiler

`cc()` uses the same toolchain that Windows gets bundled. On Windows it puts the compiler and its tools on `PATH`, so C modules build without a manual setup. The `LDE_OUTPUT_DIR` variable is still set for compatibility.

See the [build scripts docs](/docs/package-manager/dependencies/build-scripts) for the full API.

### Builds that cache

A build script now runs only when its inputs change. lde records the size, mtime, and hash of every file under `src/`, plus `lde.json` and `build.lua`. An unchanged package skips the build script and keeps the previous output. The days of recompiling a dependency on every run are over.

## REPL upgrades

### Tab completion

`lde repl` completes variable and field names. Press Tab after a prefix:

```sh
lde repl
```

![repl-autocomplete](/blog-assets/0.10.0/repl-autocomplete.gif)

Completion covers globals and table fields. For example, `json.e` completes to `json.encode`.

This works via introspection at runtime with the debug library.

### Multi-line declarations

The REPL keeps declarations alive across lines. `local function` and `const` declarations become plain globals, so they stay available on the next line:

```lua
> local function greet(name)
>>   return "hello " .. name
>> end
> greet("world")
= "hello world"

> const retries = 5
> retries += 1
> retries
= 6
```

A partial chunk keeps buffering at the `...` prompt until it is complete.

## Windows toolchain

Windows gets a new toolchain, distributed from [github.com/lde-org/toolchain-dist](https://github.com/lde-org/toolchain-dist). It bundles Clang/LLD with BusyBox `sh`, prebuilt for both x86-64 and aarch64:

- `gcc`, `g++`, `cc`, `ar`, `ranlib`, and `ld` map to the LLVM tools, so build systems see a familiar environment.
- `make` and `sh` are included. LuaRocks packages and cmake builds work without extra setup.
- Windows SDK headers and a target sysroot are included. No separate MinGW setup is needed.

LuaRocks `configure` scripts run under the bundled BusyBox `sh`. `compat-5.3` works with it too. The terminal now enables VT processing, so colors and progress bars render correctly.

Previously, Windows was given a toolchain based on gcc mingw, which had problems as it didn't support Windows on ARM, and it lacked sufficient support for the modern UCRT (Window's C Runtime) which lde is using for everything in its toolchain, from luajit builds to local compiles.

## LuaRocks compatibility

LuaRocks support keeps improving:

- Install specs now merge instead of being chosen one at a time. This fixes packages like `luasec` that publish more than one spec.
- Cmake build support is better.

The repo also gains `crater`, a compatibility harness for LuaRocks. It installs the top 100 rocks by downloads and verifies that every module loads under lde. Each package runs twice, cold and warm, with timings recorded. We run it before releases to catch regressions early.

## `lde sync --locked`

`lde sync` gains a `--locked` flag:

```sh
lde sync --locked       # install from the lockfile only
```

`--locked` re-verifies the manifest against the lockfile instead of trusting the cache marker. The `--production` flag, which skips dev dependencies, already existed.

## Dev dependencies in the lockfile

Dev dependencies now live in the lockfile. A cached sync resolves them from the lockfile and skips the network entirely. `lde sync` no longer wastes bandwidth checking dev dependencies on every run.

## Run from another directory

`-C` and `--cwd` run any command as if you were in another directory:

```sh
lde test -C packages/foo
```

This helps in monorepos and in CI, where the package to test depends on the current job.

## Zip releases

Releases now ship as zip archives instead of bare binaries. The install scripts and `lde upgrade` handle this automatically. `lde upgrade` downloads the archive, extracts the new binary, and swaps it into place.

One note: 0.9.1 and older cannot upgrade themselves this time. Their `lde upgrade` expects a bare binary asset, and releases no longer ship one. Upgrade with the installer:

```sh
curl -fsSL https://lde.sh/install | sh
```

After that, `lde upgrade` works as usual.

## Version with commit

`lde --version` now reports the git commit it was built from:

```sh
lde --version
0.10.0-nightly+a1b2c3d
```

When lde is built from a git checkout, the version includes the commit hash. The hash makes it easy to report which exact build you run.

## Fixes

- **test**: fail when a test file registers no tests
- **update**: write the new git commit to the lockfile
- **install**: cache git entries deterministically by resolved commit
- **add**: fix `--dev` not writing the dependency to the file
- **repl**: clear the autocomplete ghost on submit
- **repl**: fix key handling on Windows
- **repl**: keep multi-line chunks buffered (the parse error was lost)
- **repl**: `const` declarations persist across lines
- **readline**: highlight the `const` keyword
- **runtime**: preserve `jit.profile` across isolated runs
- **clap**: do not consume `--` in option parsing
- **x**: handle errors gracefully
- **general**: exit non-zero for unknown commands
- **general**: clearer error when run outside a package
- **tree**: handle git dependencies without a pinned commit
- **build**: handle build.lua target folder changes gracefully
- **upgrade**: delete the old binary before replacing it
- **unix**: support both `.dylib` and `.so`
- **windows**: enable VT terminal output
- **sea**: avoid a double free on Android
- **progress**: update bars only when the percentage changes
- **luajit**: `os.tmpname()` honors `TMPDIR` on Android and in containers

## Ending Note

Hopefully the next blog post will be out sooner than this one took. As for 1.0, I don't plan on having many more versions underneath it. At this point it is just ensuring stability and quality of life that people new to Lua will need in order to succeed with lde.

I appreciate the community that lde has accumulated at this point despite limited outreach. I don't intend on keeping the project very small as it is right now, but it hasn't been advertised as much intentionally to give it time to mature into 1.0 for a major announcement. And I am well aware I need to pick up the pace, as already some competition (even if their credibility may not be the best..) have appeared. But I will make sure it is done right.
