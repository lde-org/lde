---
title: Using LÖVE
order: 0
---

# Using LÖVE

Love2d requires dependencies slightly differently than traditional lua by default, which makes it harder to integrate with projects like luarocks. But it is quite easy to use with lde!

## Using lde from a LÖVE project

Simply add this to your `main.lua`

```lua
package.path = package.path .. ";./target/?.lua;./target/?/init.lua"
```

This will make it so love2d resolves modules from the `./target` directory, which is where lde installs dependencies to. Yep. That's it!

## Using LÖVE in an lde project

Since love2d has its entrypoint as `main.lua`, you can do the same as the above, except afterwards, require your own entrypoint as a module, like so:

```lua
package.path = package.path .. ";./target/?.lua;./target/?/init.lua"
require("yourproject")
```

This will set up your require paths and call into your `./src/init.lua`, so you can write as if you're just writing a normal lde project, while using love2d!

## Convenience Script

You can add a package script to make a convenient `lde dev` script:

```json
{
  "name": "mypackage",
  "scripts": {
    "dev": "lde sync && love ."
  }
}
```
