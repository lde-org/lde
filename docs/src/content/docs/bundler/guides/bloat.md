---
title: Analyzing Binary Bloat
order: 3
---

# Analyzing Binary Bloat

`lde bloat` builds your project and shows what makes up the compiled binary, aka which dependencies and files take how much space, as a percentage of the total. It's the quickest way to find what you can cut down on to reduce your bundle size.

## How it works

lde builds your project and installs dependencies into `./target/`, then measures exactly what `lde compile` would embed: each Lua module compiled to LuaJIT bytecode, plus every native shared library (`.so` / `.dll` / `.dylib`). No C toolchain is required. Content is grouped by dependency and sorted by size, so the biggest bloat is always at the top.

## Basic usage

```sh
lde bloat
```

The report shows:

- **Lua / Native summary** — how many files and total bytes of each kind, plus the overall total.
- **A proportional bar** — the top 5 dependencies, each in a contrasting color, sized by their share of the bundle. The legend below maps each color to a dependency.
- **A sized tree** — every dependency with its total size and percentage, expanded into per-file sizes (file names are shown relative to their dependency).

## Interactive mode

In a terminal, `lde bloat` is interactive: dependencies start collapsed (`[ ]`), and you can:

- **↑/↓** (or **j/k**) — move the cursor through a scrolling window
- **Enter** — expand (`[+]`) or collapse a dependency to see its files
- **q** / **Esc** / **Ctrl+C** — quit

When stdout is piped or redirected, the full static tree is printed instead.

## Comparing against a compiled binary

By default, percentages are of the embedded bundle. Pass `--binary` to also compare against a compiled executable and see the LuaJIT runtime's fixed overhead:

```sh
lde compile
lde bloat --binary            # uses ./<name> from lde compile
lde bloat --binary dist/app   # or a specific path
```

The report then shows the binary's total size and how much of it is the LuaJIT runtime + C glue.

## JSON report

`--json` prints the report as JSON to stdout (a path writes it to a file):

```sh
lde bloat --json              # stdout
lde bloat --json report.json
```
