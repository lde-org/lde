---
title: Profiling
order: 6
---

# Profiling

`lde run --profile` samples your program and prints a flat call profile when it exits:

```sh
lde run --profile
```

The profiler runs inside the isolated runtime and samples only your program. Install, build, and module resolution never appear in the report, and lde's own execution adds no samples of its own.

The report shows two things:

- A **VM state breakdown**: JIT compiled, interpreted, C code, GC, and JIT compiler time.
- A **hotspot table** with the top 20 functions by sample count.

The VM state bars show whether the JIT compiled your hot loops, whether C code dominates, or whether the GC is the bottleneck. The hotspot table names the functions.

## Flamegraphs

`lde run --flamegraph` writes an interactive flamegraph:

```sh
lde run --flamegraph
```

The file is `profile.html`. It is self-contained — open it in any browser, hover over a frame to see its share, and click a frame to zoom. Use `--flamegraph=out.html` to write elsewhere.

## JSON output

`lde run --json` writes the raw sampled data as JSON for tooling and CI:

```sh
lde run --json profile.json
```

Like `--flamegraph`, a bare `--json` defaults to `profile.json`; combine with `--profile` to also print the text report. The file follows `schemas/lde.profile.schema.json` and contains the sample total, the VM state breakdown, the hotspot table, and the folded call stacks — the same data the flamegraph is built from, so tools can render their own views or compare runs without parsing the HTML.

## Profiling scripts

The profiler works for loose scripts too:

```sh
lde ./bench.lua --profile
```

## Profiling the test suite

To profile the full test suite from a monorepo root:

```sh
lde run --profile --flamegraph -- -C packages/foo test
```

## Limitations

`--profile`, `--flamegraph`, and `--json` are not supported with `--hot` or `--watch`.
