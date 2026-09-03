---
title: Optional Dependencies
order: 2
---

lde supports optional dependencies that are only installed when a specific feature flag is enabled. This is useful for platform-specific dependencies or add-ons that not every user of your package needs.

## Adding Optional Dependencies

Add an `"optional"` field to any dependency in your `lde.json`:

```json
"dependencies": {
  "winapi": { "git": "https://github.com/example/winapi", "optional": true }
}
```

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

## Built-in features

lde automatically activates one of the following feature flags based on the current operating system:

| Feature flag | Platform       |
| ------------ | -------------- |
| `windows`    | Windows        |
| `linux`      | Linux          |
| `macos`      | macOS          |

This means you can gate dependencies by OS without any extra configuration: just name your feature `"windows"`, `"linux"`, or `"macos"` and lde will activate the right one automatically.

## Enabling Features

The features you define are for your own package. When you depend on a package that defines features of its own, you opt into them per dependency by adding a `"features"` key to its entry in your `lde.json`:

```json
"dependencies": {
  "my-package": {
    "git": "https://github.com/example/my-package",
    "features": ["windows", "sdl2"]
  }
}
```
