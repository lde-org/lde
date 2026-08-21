# lde

`lde` is a project-local package manager and toolkit for Lua, written in Lua and running on LuaJIT. It manages dependencies, runs Lua programs, and compiles them into single executables.

**lde is built with itself.** Working on lde uses the exact same commands as working on any lde package — the same manifest, lockfile, deps, and CLI apply.

## Repo Structure

```
packages/             # Internal packages (local path deps of each other)
  lde/                # CLI binary — entry: src/init.lua
  lde-core/           # Core library: Package, Lockfile, runtime, install logic
  lde-test/           # Test framework
  lde-build/          # Build script context API (injected into build.lua scripts)
  sea/                # Single-executable assembly (compiles bundles into binaries)
  ansi clap semver util luarocks rocked readline
schemas/              # JSON schema for lde.json
crater/               # LuaRocks compatibility shotgun (top-100 + cmake rocks)
minilde.lua           # Bootstrap script (see below)
```

External packages like `fs`, `path`, `env`, `process`, `json`, `archive`, `git2-sys`, `curl-sys` are git deps from `github.com/lde-org/` — not in this repo, installed into `target/` on `lde install`/`lde run`.

## lde vs luajit

**Always use `lde`, never `luajit` directly** (unless bootstrapping — see minilde).

| | `lde` | `luajit` |
|---|---|---|
| `package.path` | Set to `target/` (all installed deps available) | Stock LuaJIT defaults only |
| Deps | Built and installed automatically before running | Nothing — you get bare LuaJIT |
| Runtime isolation | Yes — isolated `_G`, fresh `package.loaded` per run | No |

```sh
lde -e "print(require('json').encode({x=1}))"  # runs with all project deps available
lde ./file.lua                                  # runs file with project's dep tree
lde run                                         # runs the package entry point (src/init.lua)
```

`lde -e` and `lde ./file.lua` both build the package and set `package.path` from `target/` first.

## Package Manifest (`lde.json`)

```jsonc
{
  "name": "my-package",
  "version": "0.1.0",
  "bin": "src/main.lua",        // optional, defaults to src/init.lua
  "scripts": { "build": "..." },
  "dependencies": {
    "json":    { "path": "../json" },                         // local path
    "hood":    { "git": "https://...", "commit": "abc123" }, // git (commit auto-pinned)
    "semver":  { "version": "1.0.0" },                       // registry
    "mylib":   { "luarocks": "luafilesystem" },              // luarocks
    "winapi":  { "git": "...", "optional": true }            // optional
  },
  "devDependencies": { ... },
  "features": { "windows": ["winapi"], "linux": ["..."] }
}
```

The require name is the **key** in `dependencies`, not the package's `name` field. Deps are installed as symlinks (or copies if `build.lua` exists) at `target/<alias>`. `package.path` includes `target/?.lua` and `target/?/init.lua`.

Commit `lde.lock`. Never commit `target/`.

## Commands

```sh
lde run             # run the package entry point
lde run --watch     # re-run the entry point on file changes (fresh state each run)
lde run --hot       # hot-reload: patch require() caches and re-run in the same state
lde ./file.lua --hot  # hot-reload a loose script outside a package
lde test             # run all *.test.lua files
lde test --coverage  # run tests and print a per-file line coverage report
lde test --watch     # re-run tests on file changes
lde compile         # compile to a single executable
lde -e "..."        # run a Lua expression in project context
lde ./file.lua      # run a file in project context

lde add json --path ../json        # add local dep
lde add hood --git https://...     # add git dep (commit auto-pinned)
lde add semver@1.0.0               # add registry dep
lde remove hood                    # remove dep
```

Always use `lde add`/`lde remove` — never edit `lde.json` manually (leaves lockfile out of sync).

## Build Scripts (`build.lua`)

If a package has a `build.lua` at its root, lde runs it instead of symlinking `src/`. The script receives a `lde-build` context via `require("lde-build")` with all paths relative to the output dir (`target/<name>`):

```lua
local build = require("lde-build")

build:fetch(url)            -- HTTP GET, returns body string
build:write(rel, content)   -- write file at outDir/rel
build:read(rel)             -- read file at outDir/rel
build:extract(rel, dest)    -- extract archive at outDir/rel to outDir/dest
build:copy(rel, dest)       -- copy outDir/rel to outDir/dest
build:move(rel, dest)       -- move outDir/rel to outDir/dest
build:delete(rel)           -- delete outDir/rel
build:exists(rel)           -- returns bool
build:sh(cmd)               -- run shell command (asserts exit 0)
```

`LDE_OUTPUT_DIR` env var is also set to the output path. Build scripts are used for packages that need to compile native code or download platform-specific binaries (e.g. `curl-sys`, `git2-sys`).

## Developing lde

Since lde is built with itself, you work on it like any other lde package:

```sh
cd packages/lde
lde test            # run lde's own tests
lde compile         # rebuild the binary → packages/lde/lde
cp lde ~/.lde/lde   # install globally
```

Tests in `packages/lde/tests/` invoke the compiled binary via `env.execPath()`. After source changes, recompile before running those tests.

To run from repo root: `lde test` runs all packages. Use `-C <dir>` to target a specific one.

Prefer the `just` recipes for the two standing checks:

```sh
just test    # lde test — run the full suite across all packages
just check   # lua-language-server over every package; must report zero diagnostics
```

Always run `just check` after changing any Lua file, and never leave the tree
with diagnostics (the recipe exits non-zero if any package reports problems).


## minilde.lua

`minilde.lua` is a minimal bootstrap script for platforms that don't yet have an `lde` binary — used only when creating a new platform build from scratch. It requires only `luajit`, `curl`, and `tar`, and implements just enough of lde to resolve deps and run the package entry point.

```sh
luajit minilde.lua run [-- extra-args]   # build and run the package (passes args after --)
```

Only `run` is supported. Use it to bootstrap the first `lde compile` on a new platform, then use `lde` from there on. The built binary goes to `packages/lde/lde` — copy it to `~/.lde/lde` to install globally.

## Monorepo Conventions

- All packages in `packages/` depend on siblings via `{ "path": "../<pkg>" }`.
- External deps (fs, path, env, etc.) are git deps pointing to `github.com/lde-org/`.
- Add new internal packages to `packages/lde/lde.json` as a path dep.
- Old name `lpm` may appear in legacy code — always use `lde` equivalents.

## Testing

```lua
local test = require("lde-test")
test.it("name", function()
  test.equal(a, b)
  test.deepEqual(t1, t2)
  test.match(actual, expected)   -- subset match (like jest toMatchObject)
  test.truthy(x) / test.falsy(x)
  test.includes(str, substr)
  test.errors(fn, expected?)     -- fn must throw; with expected, the error must match it
end)
test.skip("name", fn)
test.skipIf(cond)("name", fn)
```

Every assertion takes an optional trailing context message, appended to the failure output: `test.equal(a, b, "a must equal b")`. `test.errors` compares string errors without pcall's `path:line:` prefix; non-string errors by identity.

Test files must match `**/*.test.lua`. During `lde test`, `tests/` is exposed as `target/tests` so test files can `require("tests.lib.something")`.

Your own source is built into `target/<name>/` before tests run, so tests reach your modules by package name (the `name` field in `lde.json`) — never `require("src.foo")`:

```lua
-- tests/mathlib.test.lua
local mathlib = require("my-package.mathlib")  -- resolves to src/mathlib.lua
```

## Code Style

Follow `STYLE.md` — the full style guide (naming, LuaCATs, comments, structure).
The rules below are the short form.

Use LuaCATs annotations everywhere — all functions, parameters, and class
definitions. This codebase uses the Lua Language Server; annotations are the
primary way types are communicated across modules.

- `---@param` is mandatory for every parameter, without exception. A
  function with unannotated parameters is a bug — the language server has no
  diagnostic for it, so it is a review requirement, not an enforced one.
- Omit `---@return` when the language server can infer the return (99% of
  cases — it is cleaner). Write it only when inference is impossible, e.g.
  `nil, err` failure returns.
- Booleans are named with an `is`/`has` prefix: `isRoot`, `hasBuildScript`,
  `isStale`. Never bare `locked`/`cached`/`stale`.
- Casts go on the same line as the check that guarantees them:
  `test.truthy(value) ---@cast value -nil`. Prefer `local pkg = assert(lde.Package.open(dir))`
  over a guard-plus-cast, and never put two casts on one line.
- lde runs on the latest LuaJIT, so LuaJIT 3.0 syntax is available: `?:`,
  `??`, `?.`, `+=`, `..=`, bit operators (`&`, `|`, `~`), and `|| ->` lambdas.
  Use them where they simplify. Never use `||`/`&&`/`!=` (use `or`/`and`/`~=`),
  never `obj?:method()`, never `//`. See STYLE.md §6 for the full rules and
  language-server caveats.
- camelCase for everything; PascalCase only for class names.
- Comments are for LuaCATs types, safety concerns, and non-obvious behavior.
  No narration, no LLM filler.

```lua
---@class MyClass
---@field name string
local MyClass = {}
MyClass.__index = MyClass

---@param path string
function MyClass:read(path) end
```

## Performance

**Minimize allocations.** LuaJIT's GC is a stop-the-world mark-and-sweep — excess table/string creation causes latency spikes. Prefer reusing tables, avoid string concatenation in hot loops (use `table.concat`), and don't create closures or upvalue captures inside tight loops.

**Use FFI for hot paths.** LuaJIT can inline FFI calls to near-C speed, while Lua→C function call overhead is significant. For anything performance-sensitive (byte manipulation, system calls, math-heavy code), prefer `ffi.cdef` + `ffi.C.*` over Lua wrappers. For typed buffers, use `ffi.typeof` to create a reusable constructor rather than calling `ffi.new` directly — this lets LuaJIT specialize and inline allocations:

```lua
local Buffer = ffi.typeof("uint8_t[?]")
local buf = Buffer(1024)  -- fast, JIT-friendly
```

### Profiling

Profile a package entry point:

```sh
lde run --profile              # prints a flat call profile on exit
lde run --profile --flamegraph # also writes a flamegraph HTML file
```

To profile the full test suite from repo root:

```sh
cd packages/lde
lde run --profile --flamegraph -- -C ../.. test
```

This profiles the `lde` entrypoint itself running `lde test` as if invoked from the repo root — gives a complete picture across all packages.

## Key Packages

Local (in `packages/`):

| Package | Purpose |
|---------|---------|
| `lde-core` | `Package`, `Lockfile`, install/build/run/test/compile logic |
| `lde-test` | Test framework |
| `lde-build` | Build script context (injected into `build.lua` scripts) |
| `lde-registry` | `Registry` class: portfile lookup, version resolution, sync |
| `clap` | CLI arg parsing: `args:option()`, `args:flag()`, `args:pop()` |
| `ansi` | Terminal output: `ansi.printf("{red}msg")`, `ansi.progress(label)` |
| `sea` | Compiles bundled Lua + native libs into a self-contained binary |

External (from `github.com/lde-org/`, installed via `lde install`):

| Package | Purpose |
|---------|---------|
| `fs` | File I/O: `read`, `write`, `copy`, `move`, `rmdir`, `scan`, `stat` |
| `path` | Path ops: `join`, `basename`, `dirname`, `resolve`, `relative` |
| `env` | Env vars: `env.var()`, `env.set()`, `env.cwd()`, `env.execPath()` |
| `process` | Subprocesses: `process.exec(cmd, args, opts)`, `process.platform` |
| `json` | `json.encode(t)`, `json.decode(s)` |
