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

## Memory profiling

`lde run --memprof` reads the guest state's allocator every millisecond of CPU time and reports memory at exit:

```sh
lde run --memprof
```

The report shows:

- **Retained after exit**: the change between a post-load baseline and the state after two full garbage collections at exit. Locals of your entry file are gone by then, so a leak they hold does not show up here. The leak suspects cover that case.
- **Peak** bytes seen during the run.
- **Leak suspects**: retainer paths that kept growing between heap snapshots (see below).
- The top 15 **allocation sites**.

### Allocation sites

Each millisecond, the memory that the program gained since the last sample is charged to the line that is running, with its callers:

```
  Allocation sites
  memory that grew between 1ms samples, charged to the line running at the sample
  ──────────────────────────────────────────────────────
   86.6%  369.3 MiB   temp_work  factory.lua:44
                    ← run churn.lua:9 ← main init.lua:21 ← main chunk init.lua:29
    3.9%  16.5 MiB    table_payload  factory.lua:23
                    ← leak_round init.lua:13 ← main init.lua:20 ← main chunk init.lua:29
```

This is churn, not retention: a site that allocates short-lived tables in a loop tops this list even when nothing leaks. Growth that a sample sees inside the garbage collector goes to the stack of the previous sample, which ran the code that triggered it. The line is approximate: it is the line where the sample landed, often the loop line next to the allocation.

The sampled bytes include the Lua heap and GC-managed FFI cdata from `ffi.new`. They do not include `ffi.C.malloc`, memory allocated inside C libraries, or JIT machine code, because those bypass LuaJIT's allocator.

### Memory over time

`lde run --memgraph` prints the same report and also writes an interactive HTML graph (default `memory.html`):

```sh
lde run --memgraph            # memory.html
lde run --memgraph mem.html
```

The graph shows the heap size over profiled CPU time, with the reachable bytes of each heap snapshot, and the allocations of each moment colored by site. Below it, an allocation flamegraph shows where the memory came from, outermost caller at the top. Drag over the timeline to show only the allocations of that range in the flamegraph. Double-click clears the range.

### Finding leaks

While the program runs, `--memprof` takes heap snapshots with lua-sys's [`state:heapSnapshot()`](https://lde-org.github.io/lua-sys/reference.html): it walks everything reachable from globals, loaded modules, the call stack and the registry, and gives each object to the first path that reaches it. The walk is C code and leaves no garbage in your program's heap. A snapshot costs about as much as one full garbage collection.

The first snapshot is at 10ms of CPU time. The gap then doubles up to 10s, and snapshots wait while they have used more than 10% of the run, so a big heap gets fewer snapshots instead of a slower run.

A leak suspect is a path whose bytes grew in most snapshots, reported at the deepest named field that holds most of the growth:

```
  Leak suspects · 5 heap snapshots (10ms → 310ms), reachable 288.5 KiB → 7.3 MiB
  ──────────────────────────────────────────────────────
  +4.9 MiB    ▁▂▃▅█  init.lua:local ffi_store.entries  +1576 items
  +2.1 MiB    ▁▂▃▅█  init.lua:local table_store.entries  +1576 items
```

Path syntax:

| Part | Meaning |
|---|---|
| `init.lua:local x` | A local of the entry file. A local of a function is `file.lua:12:local x`, where 12 is the line the function starts on. |
| `_G.x` | A global. |
| `require("mod")` | A loaded module's table. |
| `.field` | A table field. |
| `[]` | All array elements of the table. |
| `[*]` | All other keys. Tables with more than 64 keys use `[*]` for string keys too. |
| `<upvalue x>` | An upvalue of a function. |
| `<mt>`, `<env>`, `<key>` | A metatable, a function environment, a table key. |

Table and function sizes are estimates from their contents. String and cdata sizes are exact.

To compare chosen points, such as before and after each request, take labeled snapshots. With two or more labeled snapshots, the report compares those instead of the automatic ones. The module only exists under `--memprof`:

```lua
local memprof = package.loaded["lde.memprof"]

local function handle(request)
	if memprof then memprof.snapshot("request " .. request.id) end
	-- ...
end
```

Use `--memprof --json profile.json` to include the memory section in the JSON output. `stacks` and the timeline's `sites` map a stack, innermost frame first, as `function@file:line` frames joined by `;`, to the bytes charged to it. `timeline` has up to 400 buckets of `bucketMs` each, and the buckets get wider on long runs:

```json
"memory": {
  "intervalMs": 1,
  "baseline": 23576,
  "final": 4443189,
  "retained": 4419613,
  "peak": 4447845,
  "allocated": 4424269,
  "stacks": { "work@/app/src/init.lua:4;/app/src/init.lua:0@/app/src/init.lua:9": 4170633 },
  "bucketMs": 2,
  "timeline": [
    { "atMs": 0, "bytes": 261460, "peak": 261460, "allocated": 301100, "sites": { "work@/app/src/init.lua:4;…": 301100 } }
  ],
  "snapshots": [
    { "atMs": 10, "attributed": 295424, "objects": 6211 },
    { "atMs": 310, "attributed": 7654432, "objects": 151377 }
  ],
  "leaks": [
    { "path": "init.lua:local ffi_store.entries", "growth": 5872025, "items": 1776, "series": [0, 5872025] }
  ]
}
```

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
