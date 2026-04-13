---
title: Release v0.9.1
author: David Cruz
published: 2026-04-12
description: New REPL, Android support, native curl/git/archive libraries, git submodule support, test lifecycle hooks, and more.
---

> Upgrade to the latest version with `lde upgrade`!

## New REPL

`lde repl` has been rebuilt from scratch with a custom readline implementation — no external dependencies required.

```sh
lde repl
```

![repl](/blog-assets/0.9.1/repl2.gif)

The new REPL supports line editing, history, and syntax highlighting, implemented in pure Lua with platform-specific raw terminal handling for both POSIX and Windows. It runs inside the lde environment, so `require()` works as expected for your project's dependencies.

## Android support

lde now runs natively on Android via [Termux](https://termux.dev). Prebuilt binaries for `aarch64-linux-android` are included in every release.

The install script handles Android automatically:

```sh
curl -fsSL https://lde.sh/install | sh
```

## Native curl, git, and archive libraries

lde's three core I/O subsystems have been rewritten to use native C bindings rather than shelling out or using pure Lua implementations:

- **curl-sys** — HTTP downloads now use libcurl directly, replacing subprocess calls to the `curl` binary. OpenSSL is statically linked on all platforms, so no runtime TLS dependency.
- **git2-sys** — Git operations now go through libgit2, replacing subprocess calls to the `git` binary. `git` no longer needs to be installed. On Linux and Android, libgit2 links dynamically to OpenSSL (which is typically already present). On macOS it uses SecureTransport, and on Windows it uses WinHTTP.
- **deflate-sys** — Archive extraction now uses libdeflate via FFI, replacing subprocess calls to `tar`, `zip`, and `unzip`. libdeflate is self-contained with no external dependencies.

These are compiled ahead of time and bundled into the lde binary.

![nogit](/blog-assets/0.9.1/nogit.gif)

## Git submodule support

All git clones — including dependency installs — now recursively initialize submodules:

```json
{
	"dependencies": {
		"mylib": { "git": "https://github.com/example/mylib" }
	}
}
```

If `mylib` has submodules, they're cloned too. This was previously only done in some cases.

## Test lifecycle hooks

`lde-test` now supports `afterAll` and `afterEach` hooks for teardown logic:

```lua
local test = require("lde-test")

test.afterEach(function()
  -- runs after every test in this file
  cleanup()
end)

test.afterAll(function()
  -- runs once after all tests in this file
  db:close()
end)

test.it("does something", function()
  -- ...
end)
```

`afterEach` runs after every individual test. `afterAll` runs once when all tests in the file are done.

## Lockfile auto-invalidation on `lde add` / `lde remove`

Previously, adding or removing a dependency could leave the installed `target/` out of sync until you manually ran `lde sync`. Now, `lde add` and `lde remove` automatically invalidate the lockfile cache so the next `lde run` or `lde sync` re-installs cleanly.

## Fixes

- **archive**: handle deeply nested zip archives
- **upgrade**: pass `User-Agent` header to GitHub API to avoid rate limiting
- **repl**: fix `os.tmpname` to use `TMPDIR` on Android/Termux
- **android**: replace `os.tmpname` in runtime to resolve correctly under Termux
- **sea**: fall through to `ldd` fallback when `-dumpmachine` output doesn't contain a libc identifier
- **sea**: use stdout when stderr is empty for compile error output
- **sea**: fix `string.find` pattern mode for glob matching
- **process2**: fix deadlock in async process reading
- **process2**: stop merging stdout and stderr into a single stream
- **test**: run test callbacks inside the lde environment to avoid upvalue leaks
- **sea**: use compiler-derived target triple for libc and architecture detection instead of host arch
