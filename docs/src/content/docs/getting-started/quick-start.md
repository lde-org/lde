---
title: Quick Start
order: 3
---

# Quick Start

Get up and running with lde in under a minute.

## Create a new project

```sh
lde new myproject && cd myproject
```

## Add a package

For this example, we'll import the `path` library from lde itself.

```sh
lde add path --git https://github.com/codebycruz/lde
```

## Write your main file

Edit `src/init.lua` to look like this:

```lua
-- You'll get LuaLS typings from this!
local path = require("path")
print(path.join("hello", "world"))
```

## Run your project

```sh
lde run
# 'hello/world'
```

That's it. It's that simple. You just ran your project with a dependency from an entirely remote git repository stored in a monorepo, with all the heavy lifting done by lde!
