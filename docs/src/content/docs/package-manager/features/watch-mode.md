---
title: Watch Mode
order: 5
---

# Watch Mode

`lde run --watch` re-runs your project automatically whenever a file in `src/` changes.

## Usage

```sh
lde run --watch
```

You can also pass a script name or file path:

```sh
lde run --watch myscript
lde run --watch -- script args here
```

Errors during a re-run are printed and the watcher keeps running, so a broken edit won't kill your session.
