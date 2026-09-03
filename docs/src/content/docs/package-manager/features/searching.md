---
title: Searching for Packages
order: 5
---

`lde search` finds packages by name and description across the [lde registry](https://github.com/lde-org/registry) and [luarocks](https://luarocks.org/).

```bash
lde search json
```

```
Found 76 packages matching 'json':
🪨 json-logic-lua (0.5.0-1)
🪨 json-lua (0.1-4)
🪨 json-rock (2.0-4)
...
```

## Results

- Packages from lde's registry are shown and prioritized.
- Luarocks packages are shown as a fallback and marked with a rock emoji (🪨) to distinguish them.
- By default the first **10 results** are shown, but you can pass `--all` to show all results.

## Interactive installs

When you run `lde search` in a terminal, it allows you to select a package using arrow keys to navigate up and down results.  

**Pressing enter will do one of two things:**
1. If you are inside of an existing lde project, it will `lde add` it to your dependencies.
2. If you are not inside of an existing lde project, it will `lde install` it as a global tool.

You exit the prompt by pressing `q` or `esc`.

## Luarocks-only search

`lde search rocks:<query>` searches luarocks only:

```bash
lde search rocks:json
```

## The rock emoji

Emoji need a terminal font with emoji glyphs. lde disables the 🪨 marker when
the terminal reports `TERM=dumb`/`TERM=linux`, when the locale isn't UTF-8, or
when `NO_EMOJI` is set (any value except `0`) — rock rows then show a plain `R`
marker instead.
