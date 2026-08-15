---
title: Shell Completion
order: 2
---

# Shell Completion

lde ships tab-completion for bash, zsh, and fish. Completions cover commands, flags, and file paths.

## Enable completions

Add the generated script to your shell's rc file:

```sh
# bash — add to ~/.bashrc
eval "$(lde completion bash)"

# zsh — add to ~/.zshrc
eval "$(lde completion zsh)"

# fish — add to config.fish
lde completion fish | source
```

You can also print the script to inspect it:

```sh
lde completion bash
```

## What completes

- **Commands** — type `lde <TAB>` to see every command and alias.
- **Scripts** — inside a project, `lde <TAB>` also suggests your `lde.json` script names (e.g. `dev`), and `lde run <TAB>` suggests them alongside files.
- **Flags** — type a command followed by `<TAB>` to see its flags (e.g. `lde run <TAB>`), plus the global flags like `-C` and `--help`.
- **Sub-commands** — `lde help <TAB>` and `lde completion <TAB>` complete command names.
- **Files and directories** — options that take a path (like `-C` and `--outfile`) complete paths directly, and everything typed after `--` is treated as positional and completes as files.
