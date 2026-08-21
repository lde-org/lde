# lde Style Guide

This document defines the style rules for the lde codebase. All Lua code in
`packages/` must follow these rules. LLM tools and human contributors must
follow them. The rules use Simplified Technical English. They are short and
direct. Do not add rules to this document without a review.

## 1. Naming

Use camelCase for all names.

| Name type | Form | Example |
|---|---|---|
| Local variable | camelCase | `local packageDir` |
| Function parameter | camelCase | `---@param packageDir string` |
| Local function | camelCase | `local function resolveDir()` |
| Class field | camelCase | `---@field cachedConfig lde.Package.Config?` |
| Class name | PascalCase | `ldee.Package`, `lde.Lockfile` |
| Module table | PascalCase or lowercase | `Package`, `lockfile` |
| Method | camelCase | `function Package:readConfig()` |
| Constant | UPPER_SNAKE | `MANIFEST_TTL` |

Do NOT use snake_case. Do NOT use single-letter names, except loop indexes
(`i`, `n`) and ignored values (`_`).

Do name things by what they do or what they hold. Do NOT use short names that
need a comment to explain.

Do NOT add type prefixes to names. Do NOT write `strName`, `tblDeps`, or
`isValidFlag`. Write `name`, `deps`, and `valid`.

Do prefix booleans with `is` or `has`. This reads like natural English:

| Name | Example usage |
|---|---|
| `isRoot` | `if isRoot then` |
| `hasBuildScript` | `if package:hasBuildScript() then` |
| `isStale` | `if lockfile:isStale(config) then` |
| `isCached` | `return isCached` |

Do NOT write bare boolean names like `locked`, `cached`, or `stale` for
variables and fields. Write `isLocked`, `isCached`, `isStale`. This applies
to local variables, class fields, and function names that answer a yes/no
question.

## 2. LuaCATS annotations

Use LuaCATS annotations everywhere. This codebase uses the Lua Language
Server. Annotations are the primary way types travel between modules.

Do type every function parameter. This is mandatory:

```lua
---@param dir string
---@param opts { summary: boolean?, locked: boolean? }?
local function resolveDir(dir, opts) end
```

Do NOT write `---@return` when the language server can infer the return type.
This is the common case. Omit it 99 times out of 100. It is cleaner that way.

Do write `---@return` only when inference is impossible. Examples: a function
returns `nil, errorMessage` on failure, or returns one of several shapes:

```lua
---@return string? resolved
---@return string? err
local function resolveDir(dir) end
```

Do declare classes with `---@class` and `---@field`:

```lua
---@class lde.Package
---@field dir string
---@field cachedConfig lde.Package.Config?
local Package = {}
Package.__index = Package
```

Do write `---@type` for a local whose type inference fails or is ambiguous
(for example, a table built from dynamic keys). Do NOT write `---@type` for
values the language server already infers.

Do NOT use `---@param` to repeat an inferred type. Do NOT annotate the obvious.

Do use `---@cast` to narrow a type after a runtime check. Do NOT cast to
silence real type errors. Fix the error instead.

Do put the `---@cast` on the same line as the check that guarantees it — one
line, not two:

```lua
test.truthy(value) ---@cast value -nil
test.truthy(pkg, err) ---@cast pkg -nil
```

Do prefer `assert` over a guard-plus-cast when the value comes from a call:
`local pkg = assert(lde.Package.open(dir))` narrows `pkg` to non-nil and
raises with the call's error in one expression. Do NOT write a helper that
only wraps `assert`.

Do NOT put two casts on one line: the language server only honors the first
inline `---@cast` on a line. Keep one cast per line.

Do type FFI structs as classes that extend `ffi.cdata*` and list the fields
they store. The language server cannot see `ffi.cdef` declarations, so this
is the supported way to get checked field access:

Name the class `<package>.ffi.<type>` so it cannot collide across packages:

```lua
ffi.cdef[[
	struct timespec { long tv_sec; long tv_nsec; };
]]
---@class mylib.ffi.timespec: ffi.cdata*
---@field tv_sec number
---@field tv_nsec number

local t = ffi.new("timespec")
---@cast t mylib.ffi.timespec
return tonumber(t.tv_sec)
```

## 3. Comments

Keep comments small in number and high in value.

Allowed comment content:

1. LuaCATs annotations (see section 2).
2. Safety concerns. Example: a check that prevents a crash or a corrupt file.
3. Behavior that the code does not make obvious. Example: why a fallback
   exists, why an order matters, why a workaround is needed.

Forbidden comment content:

1. Narration of the code. Do NOT write `-- increment the counter` above
   `count = count + 1`.
2. Obvious restatements. Do NOT write `-- only sync once` above an `if`
   guard that says the same thing.
3. LLM-looking filler. Do NOT write `-- This function does X`, `-- Helper
   for Y`, or `-- TODO: fix later` without a concrete explanation.
4. Markers like `-- ==== Section ====` inside a file. Split the file instead.
5. Comments that can go stale. Do NOT describe what the code "used to do".

Do write a module-level comment when the module's contract is not obvious
from its name. Example: `resolve.lua` explains the two-phase install walk.

Do NOT leave commented-out code in the tree. Delete it.

## 4. Code structure

Do keep files small. A file that grows past ~400 lines should be split into
modules. One class per file is the default.

Do put the class, its `new`, and its methods in one file. Do NOT scatter
methods of one class across files.

Do return `nil, err` for expected failures. Do use `lde.error.raise` only for
deep call stacks where threading the error out is not practical.

Do require modules at the top of the file. Do NOT require inside loops.

Do NOT create module load cycles. A module must not require a module that
requires it back. Require the leaf module (`lde-core.error`) instead of the
whole tree (`lde-core`) when you only need one function.

## 5. Formatting

Do use tabs for indentation. The repo ships `.editorconfig`; follow it.

Do use one statement per line.

Do break long conditionals across lines. Put the operator at the start of the
continued line:

```lua
if not file:sub(1, 1) == "/" or file:match("^%a:[/\\]") then
```

Do NOT leave trailing whitespace.

## 6. LuaJIT 3.0 syntax

lde runs on the latest LuaJIT, which backports most of the LuaJIT 3.0 syntax
extensions (see https://luajit.org/extensions.html#lj30_bp_syntax). Use them
where they simplify or clarify.

Allowed and encouraged:

| Syntax | Use instead of |
|---|---|
| `cond ? a : b` | `cond and a or b` (and its `false` pitfall) |
| `x ?? default` | `x or default` when `x` can be `false` |
| `x?.field` | `x and x.field` chains |
| `a += b`, `s ..= t` | `a = a + b`, `s = s .. t` |
| `a & b`, `a \| b`, `~a` | `bit.band`, `bit.bor`, `bit.bnot` |
| `x = || -> expr` | anonymous function literals |

Forbidden:

1. Do NOT use `||` (logical or), `&&` (logical and), or `!=` (not equal).
   Use `or`, `and`, `~=`. (The `||` in the lambda syntax `|| ->` is the empty
   parameter list, not a logical operator.)
2. Do NOT use the optional method-call form `obj?:method()`. It is confusing
   and the language server cannot parse it.
3. Do NOT use `//` (floor division). It is NOT backported to this LuaJIT.

Language-server caveats:

1. The language server cannot parse `a?.[key]` (bracket safe-navigation) —
   write `a and a[key]`.
2. The language server still reports `need-check-nil` on `?.` bases and in
   some ternary branches. Prefer `and`/`or` when the checker complains rather
   than adding casts.

## 7. Performance

Do minimize allocations. LuaJIT's GC is stop-the-world. Reuse tables. Use
`table.concat` instead of string concatenation in hot loops.

Do NOT create closures inside tight loops.

Do use FFI for hot paths. See AGENTS.md, section "Performance".

## 8. Tests

Do name test files `*.test.lua` under `tests/`.

Do write one `test.it` per behavior. Do NOT bundle several assertions into
one test when they test different behaviors.

Do pass a context message as the last argument to an assertion when the
failure message would be ambiguous:

```lua
test.equal(plan.dir, repoDir, "cached repos must not plan a download")
```

Do keep tests hermetic. Do NOT hit the network. Inject fakes through
constructors (see `lde.Registry` in `packages/lde-registry`).
