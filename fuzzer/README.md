# lde fuzzer

A fuzzing suite for lde: generates CLI invocations and package contents,
runs them against the binary under test, records every outcome, and fails
when any case produces a crash, a leaked raw traceback, or a hang.

The invariant every case must satisfy: **graceful success or a clean,
single-line error** — never the `lde crashed` screen (exit 2), never a
`stack traceback` escaping the error boundary, never a blocked process.

## Usage

```sh
cd fuzzer
lde sync                      # install process/fs/path/json/ansi

LDE=/path/to/lde lde run -- --seed 42 --count 1000
```

- `LDE` — the binary under test (default: `lde` from PATH).
- `--seed N` — PRNG seed (default: current time). Reuse a seed to reproduce
  the exact same run, case for case.
- `--count N` — cases per fuzzer (default: 500; the CLI fuzzer and the
  package-content fuzzer each run `N`).
- `--cli-only` / `--packages-only` — run a single fuzzer.
- `LDE_FUZZ_DIR` — scratch dir (default: `<cwd>/.fuzz`).

## What it fuzzes

**CLI fuzzer** (`src/cli.lua`) — grammar-based generation over the real
command surface: commands, global flags (`-C`, `--tree`, `--version`,
`--help`, `-e`, `--lua`, `--setup`, ...), per-command flags, the hidden
backends (`__complete`, `__build-pkg`), plus garbage values (empty strings,
unicode, ANSI escapes, `{red}` format-tag injection, long tokens, `--`
separators, random bytes). Cases run in an empty dir or a real project with
path deps. `-e`/`--lua` cases run random Lua (syntax errors, runtime errors,
weird returns, `os.exit`, heavy loops); hangs there are user code, not lde
bugs, and are recorded but not counted as findings.

**Package-content fuzzer** (`src/packages.lua`) — random projects: manifests
(valid JSON, random junk structures, invalid JSON, JSON5), `build.lua`
scripts (valid `lde-build` usage, errors, garbage), `src/` entries (valid,
erroring, requiring missing modules, weird files/extensions), corrupt
`lde.lock` files, and `tests/` files — then runs `run`, `test`, `tree`,
`sync`, `install`, `update`, `outdated`, `add`, `remove`, `uninstall`,
`bundle`, and (rarely) `compile` against each.

Everything is hermetic: deps are local path/git deps only (no registry,
no network), `HOME` is isolated to the scratch dir, and `NO_COLOR` is set
so output classification is exact. Registry-touching commands (`publish`,
`upgrade`, bare `x`, `rocks:` installs) are excluded from generation.

## Output

- `.fuzz/results.csv` — one row per case: `seed,index,kind,note,cwd,exit,outcome,ms,args`.
- `.fuzz/findings.log` — every crash/raw-traceback/hang with the full
  command and output, ready to reproduce.
- Failed package cases keep their project dir under `.fuzz/pkg-N/` for
  inspection; passing cases are cleaned up.

Exit code is 0 when no findings, 1 when any crash / raw traceback / hang
(command cases only) is found.
