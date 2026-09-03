---
title: "fetch(url)"
order: 0
---

You can fetch the contents of a URL using the `fetch` function.

```lua
local response = build:fetch("https://example.com")
```

This returns a single string containing the response body, and will throw an error if the request fails.

> [!TIP]
> This is useful for fetching tarballs to build.
