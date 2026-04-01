---
title: Optional Dependencies & Features
order: 2
---

# Optional Dependencies & Features

lde supports optional dependencies that are only installed when a specific feature flag is enabled. This is useful for platform-specific dependencies or add-ons that not every user of your package needs.

## Marking a dependency as optional

Add `"optional": true` to any dependency in your `lde.json`:

```json
"dependencies": {
  "winapi": { "git": "https://github.com/example/winapi", "optional": true }
}
```

Optional dependencies are never installed unless a feature that includes them is active.

## Defining features

Features are named groups of optional dependencies. You define them under the `"features"` key in `lde.json`, where each key is a feature name and the value is a list of dependency names to enable:

```json
"dependencies": {
  "winapi": { "git": "https://github.com/example/winapi", "optional": true },
  "luaposix": { "luarocks": "luaposix", "optional": true }
},
"features": {
  "windows": ["winapi"],
  "linux": ["luaposix"],
  "macos": ["luaposix"]
}
```

## Built-in OS features

lde automatically activates one of the following feature flags based on the current operating system:

| Feature flag | Platform       |
| ------------ | -------------- |
| `windows`    | Windows        |
| `linux`      | Linux          |
| `macos`      | macOS          |

This means you can gate dependencies by OS without any extra configuration — just name your feature `"windows"`, `"linux"`, or `"macos"` and lde will activate the right one automatically.
