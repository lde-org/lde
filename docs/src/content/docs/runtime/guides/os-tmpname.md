---
title: os.tmpname() Override
order: 3
---

# os.tmpname() Override

LDE overrides `os.tmpname()` with a safe cross-platform replacement in both the runtime and compiled binaries.

This is needed for Termux/Android, where the default `os.tmpname()` returns paths that don't exist.

The replacement generates paths under the system temp directory (`TMPDIR` / `TEMP` / `TMP`) in the form:

```
<tmpdir>/lde_<timestamp>_<counter>.tmp
```

The override is active in:

- `lde run` / `lde test` — applied for the duration of script execution, then restored.
- `lde compile` — patched into the compiled binary so it is always in effect.
