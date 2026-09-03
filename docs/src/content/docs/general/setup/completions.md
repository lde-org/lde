---
title: Shell Completion
order: 1
---

lde ships tab-completions for bash, zsh, and fish

## Enable completions

Add the generated script to your shell's rc file:

```sh
# bash: add to ~/.bashrc
eval "$(lde completion bash)"

# zsh: add to ~/.zshrc
eval "$(lde completion zsh)"

# fish: add to config.fish
lde completion fish | source
```

You can also print the script to inspect it:

```sh
lde completion bash
```
