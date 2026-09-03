---
title: Using Neovim
order: 2
---

Neovim by default only resolves modules from the `lua/` directories on its `runtimepath`. All that is needed to support lde is to point it at a `target/` directory.

## Making your Neovim config an lde package

Make your nvim config an lde package: `lde new` inside `~/.config/nvim`, then add whatever dependencies you want.

```sh
cd ~/.config/nvim
lde add rocks:luafilesystem
```

Just create your `nvim/init.lua` so that it sets up path requires your package (running the main entrypoint)

```lua ~/.config/nvim/init.lua
local config = vim.fn.stdpath("config")
vim.system({ "lde", "-C", config, "sync" }):wait()

local target = config .. "/target"
package.path = package.path .. ";" .. target .. "/?.lua;" .. target .. "/?/init.lua"
package.cpath = package.cpath .. ";" .. target .. "/?.so"
require("yourpackage")
```

Then you can treat your `./src/init.lua` as your real config.

```lua src/init.lua
local lfs = require("lfs") -- pure-Lua or native, both work

vim.g.neovim_config = lfs.currentdir()
```

Since `src/init.lua` only runs inside Neovim, keep the pure logic (anything that doesn't touch `vim.*`) in separate modules that `lde test` can exercise, and leave the `vim.*` wiring in the entry.

## Writing a Neovim plugin as an lde package

Simply write your code as any other lde package. To publish it as a normal nvim plugin, generate the conventional `lua/<name>.lua` entry with `lde bundle`:

```sh
lde bundle --outfile lua/myplugin.lua
```

`lde bundle` inlines your modules and dependencies into one self-contained file, so users install the repo with their plugin manager of choice and just `require("myplugin")`.

```json lde.json
{
  "name": "myplugin",
  "scripts": {
    "build": "lde bundle --outfile lua/myplugin.lua"
  }
}
```
