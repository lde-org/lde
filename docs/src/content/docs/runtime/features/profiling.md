---
title: Profiling
order: 2
---

A profiler is shipped by lde, using LuaJIT's highly [performant sampling profiler](https://luajit.org/ext_profiler.html) that can be used in production environments due to its minimal overhead.

> [!WARNING]
> Profiling is not supported with `--hot` or `--watch`.

```sh
lde run --profile
```

The report shows two things:

- A **VM state breakdown**: JIT compiled, interpreted, C code, GC, and JIT compiler time.
  - This is useful to try and minimize the amount of time spent in interpreted code and in GC.
- A **hotspot table** with the top 20 functions by sample count.
  - Helpful to figure out which functions are taking up the most time.

![VM State Breakdown](/blog-assets/0.10.0/profile.gif)

## Flamegraphs

`lde run --flamegraph` writes an interactive flamegraph:

```sh
lde run --flamegraph
```

This generates a self contained `profile.html` file. You can open it in any browser, hover over frames, click to expand.

![Flamegraph](/blog-assets/0.10.0/flamegraph.gif)

> [!TIP]
> You can write to a custom file path using `--flamegraph=out.html`.

## JSON output

`lde run --profile --json` writes the raw sampled data as JSON. This is useful for historical metrics, or feeding into tooling like llms for analysis.

```sh
lde run --profile --json profile.json
```
