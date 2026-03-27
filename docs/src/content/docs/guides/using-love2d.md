---
title: Using LÖVE
order: 3
---

# Using LÖVE

Love2d requires dependencies slightly differently than traditional lua by default, which makes it harder to integrate with projects like luarocks. But it is quite easy to use with lde!

## Using LDE from a LÖVE project

Simply add this to your `main.lua`

```lua
package.path = package.path .. ";./target/?.lua;./target/?/init.lua"
```

This will make it so love2d resolves modules from the `./target` directory, which is where LDE installs dependencies to. Happy hacking!

## Using LÖVE in an LDE project

Since love2d has its entrypoint as `main.lua`, you can do the same as the above, except afterwards, require your own entrypoint as a module, like so:

```lua
package.path = package.path .. ";./target/?.lua;./target/?/init.lua"
require("yourproject")
```

This will set up your require paths and call into your `./src/init.lua`, so you can write as if you're just writing a normal lde project, while using love2d!
