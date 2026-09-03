---
title: Watch Mode
order: 4
---

When working on a project, sometimes you want to see your changes apply instantly without having to `lde run` again.

![watch](/blog-assets/0.9.0/watch.gif)

You can use `lde --watch` to re-run your package automatically whenever any file in your source directory changes.

## Usage

```sh
lde run --watch
```

You can also pass a script name or file path:

```sh
lde run --watch myscript
lde run --watch -- script args here
```

> [!TIP]
> Errors during a re-run are printed and the watcher keeps running, so a broken edit won't kill your session.

This also works with running files, of course:

```sh
lde --watch myscript.lua
```
