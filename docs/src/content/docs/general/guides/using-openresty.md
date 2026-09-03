---
title: Using OpenResty
order: 1
---

All that is needed to support lde's managed dependencies is to add the `target/` directory of your lde project to `lua_package_path` in `nginx.conf` (the equivalent of setting package.path in lua)

```nginx
http {
    lua_package_path '/srv/myapp/target/?.lua;/srv/myapp/target/?/init.lua;;';
}
```

The trailing `;;` keeps OpenResty's built-in module paths. Now require lde deps from any `*_by_lua` block:

```lua
content_by_lua_block {
    local json = require("json")
    ngx.say(json.encode({ hello = "world" }))
}
```

This works wherever `require` is available: preload modules in `init_by_lua_block`, handle requests in `content_by_lua_block`, and so on.

## Full Example

```lua src/init.lua
local json = require("json")

local M = {}

---@return string
function M.payload()
	return json.encode({ hello = "openresty", via = "lde deps" })
end

return M
```

Then wire nginx up to it:

```nginx nginx.conf
http {
    lua_package_path '/srv/myapp/target/?.lua;/srv/myapp/target/?/init.lua;;';

    server {
        location / {
            content_by_lua_block {
                local app = require("myapp")  -- your package name
                ngx.say(app.payload())
            }
        }
    }
}
```

> [!WARNING]
> There may be issues with packages that use native dependencies, as they'll be built against lde's LuaJIT version which is newer than OpenResty's LuaJIT.
