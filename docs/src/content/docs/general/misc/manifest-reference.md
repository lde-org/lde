---
title: Manifest Reference
order: 0
---

Every lde package is described by an `lde.json` file at the package's root. It is the source of truth for your package's dependencies, features, and registry metadata.

It is a plain JSON object you can edit by hand, or use via the command line helpers with commands like `lde add` and `lde remove`.

When first resolving dependencies, lde looks at your `lde.json` and generates a [lockfile](/docs/package-manager/features/lockfile), which is invalidated if the `lde.json` file changes via its hash.

> [!TIP]
> Only `dependencies`, `devDependencies`, and `features` feed into the hash, so metadata edits never invalidate the lockfile.

## Schema

A [JSON Schema](https://json-schema.org) for the manifest is provided, which you can find at this URL:

```text
https://raw.githubusercontent.com/lde-org/lde/master/schemas/lde.schema.json
```

Point your editor at it for autocompletion and validation while editing `lde.json`.

### VSCode

Add the following to your project's VSCode settings:

```json .vscode/settings.json
{
	"json.schemas": [
		{
			"fileMatch": ["lde.json"],
			"url": "https://raw.githubusercontent.com/lde-org/lde/master/schemas/lde.schema.json"
		}
	]
}
```

### Zed

Add the following to your project's Zed settings:

```json .zed/settings.json
{
	"lsp": {
		"json-language-server": {
			"settings": {
				"json": {
					"schemas": [
						{
							"fileMatch": ["lde.json"],
							"url": "https://raw.githubusercontent.com/lde-org/lde/master/schemas/lde.schema.json"
						}
					]
				}
			}
		}
	}
}
```

### Inline `$schema`

VS Code, Zed, and most other JSON tooling also honor a `$schema` key directly in the manifest, which needs no editor configuration:

```json lde.json
{
	"$schema": "https://raw.githubusercontent.com/lde-org/lde/master/schemas/lde.schema.json",
	"name": "my-package",
	"version": "0.1.0"
}
```

## Example

```json lde.json
{
	"name": "my-package",
	"version": "0.1.0",
	"description": "A small example package",
	"authors": ["Ada Lovelace"],
	"engine": "lde",
	"bin": "src/main.lua",
	"scripts": {
		"dev": "lde run ./src/dev.lua"
	},
	"dependencies": {
		"hood": { "git": "https://github.com/codebycruz/hood" },
		"ansi": { "path": "../ansi" },
		"json": { "version": "1.0.0" },
		"luafilesystem": { "luarocks": "luafilesystem" },
		"tools": { "archive": "https://example.com/tools.tar.gz" },
		"winapi": { "git": "https://github.com/codebycruz/winapi", "optional": true }
	},
	"devDependencies": {
		"test-utils": { "path": "../test-utils" }
	},
	"features": {
		"windows": ["winapi"]
	}
}
```

## Fields

### `name` (required)

The name of your package. Must be lowercase and may contain letters, digits, `-` and `_`, and may be namespaced as `ns/name` for [registry namespaces](/docs/registry/guides/namespaces):

```json
{
	"name": "my-package"
}
```

```json
{
	"name": "nexus/json"
}
```

lde uses the name to place the built package at `target/<name>`, and `lde publish` reads it to register the package on the [registry](/docs/registry/getting-started/introduction).

### `version` (required)

The version of your package, as three dot-separated numeric parts ([semver](https://semver.org)):

```json
{
	"version": "1.2.3"
}
```

`lde publish` uses it to register the version on the registry, and you bump it whenever you publish an update.

### `description`

A short, human-readable description of what the package does:

```json
{
	"description": "A fast JSON parser for Lua"
}
```

It is included in the metadata that `lde publish` pre-fills for registry pull requests.

### `authors`

A list of the package's authors:

```json
{
	"authors": ["Ada Lovelace", "Alan Turing"]
}
```

### `bin`

The entry point of your package, relative to the package root. Defaults to `src/init.lua` when omitted, which is what `lde run` executes when called without a file argument:

```json
{
	"bin": "src/main.lua"
}
```

> [!TIP]
> Teal and Moonscript entry points are supported and compiled before running.

## `engine`

The interpreter used to run your package. Defaults to `lde`:

> [!WARNING]
> This is experimental and currently does not function. In the future, better support with a version manager may exist.

```json
{
	"engine": "luajit"
}
```

| Value    | Meaning                                                                                                 |
| -------- | ------------------------------------------------------------------------------------------------------- |
| `lde`    | The lde runtime                                                                                         |
| `luajit` | A bare `luajit` binary on your PATH                                                                     |
| `lua`    | A bare `lua` binary on your PATH                                                                        |

### `scripts`

Named shell commands for the package, run from the package root:

```json
{
	"scripts": {
		"dev": "lde run ./src/dev.lua",
		"check": "luacheck src"
	}
}
```

Run them with `lde run <name>` (extra arguments after `--` are appended to the command).

> [!TIP]
> You can also simply `lde <name>` to run a script without `run`.

Commands run through `cmd.exe` on Windows and `/bin/sh` everywhere else. See [package scripts](/docs/general/features/package-scripts) for more.

### `dependencies`

A map from require name to dependency spec. The key is the name you `require()` in code, so you can alias a package by choosing a different key. Each value describes where the dependency comes from — exactly one source field per spec:

#### `path` dependencies

```json
{
	"dependencies": {
		"ansi": { "path": "../ansi" }
	}
}
```

A path relative to your package directory. Path dependencies are how sibling packages in a monorepo refer to each other. lde installs them into `target/` straight from the source tree (as symlinks where possible) rather than downloading them.

#### `git` dependencies

```json
{
	"dependencies": {
		"hood": { "git": "https://github.com/codebycruz/hood" }
	}
}
```

A git repository URL. `lde add <name> --git <url>` resolves the ref up front and records the pinned commit in `lde.lock`, so installs are reproducible. You can pin explicitly or follow a branch:

```json
{
	"dependencies": {
		"hood": { "git": "https://github.com/codebycruz/hood", "commit": "abc123" },
		"hood-dev": { "git": "https://github.com/codebycruz/hood", "branch": "next" }
	}
}
```

> [!TIP]
> Regardless, the git dependency will be pinned to a commit by the lockfile.

#### `version` / registry dependencies

```json
{
	"dependencies": {
		"json": { "version": "1.0.0" }
	}
}
```

A package from the [lde registry](/docs/registry/getting-started/introduction), keyed by version. The version may be an exact version or a range; `lde add <name>@<version>` resolves it up front and writes the concrete version here, and installs resolve the newest matching version.

#### `luarocks` dependencies

```json
{
	"dependencies": {
		"luafilesystem": { "luarocks": "luafilesystem" }
	}
}
```

A package from luarocks.org. An optional `version` field constrains which rock is installed:

```json
{
	"dependencies": {
		"luasocket": { "luarocks": "luasocket", "version": ">= 3.0" }
	}
}
```

#### `archive` dependencies

You can specify a URL to a raw archive file, being a tarball or zip file.

```json
{
	"dependencies": {
		"tools": { "archive": "https://example.com/tools.tar.gz" }
	}
}
```

This will be downloaded and extracted.

#### Shared options

Every dependency spec accepts these optional fields:

| Field      | Description                                                                              |
| ---------- | ---------------------------------------------------------------------------------------- |
| `optional` | If `true`, the dependency is only installed when enabled by a feature (see [features](#features)). |
| `features` | Feature flags to enable for this dependency. See [optional dependencies](/docs/package-manager/features/optional-dependencies). |
| `package`  | The actual package name at the source, when it differs from the require key (aliasing).  |
| `rockspec` | Path to a `.rockspec` file relative to the dependency directory, for rockspec-based dependencies. |

`package` is how git dependencies point at a specific package inside a monorepo repository, and how local/registry/archive dependencies resolve under an alias:

```json
{
	"dependencies": {
		"parser": {
			"git": "https://github.com/example/monorepo",
			"package": "json-parser"
		}
	}
}
```

### `devDependencies`

Same shape as [`dependencies`](#dependencies), but only needed to develop the package itself. Ie for running tests, preprocessing, etc.

```json
{
	"devDependencies": {
		"test-utils": { "path": "../test-utils" }
	}
}
```

> [!NOTE]
> Dev dependencies are never installed when another package depends on yours, and `lde --production` skips them.

### `features`

Named groups of optional dependencies. A group lists the dependency keys to enable when its flag is active:

```json
{
	"dependencies": {
		"winapi": { "git": "https://github.com/codebycruz/winapi", "optional": true },
		"luaposix": { "luarocks": "luaposix", "optional": true }
	},
	"features": {
		"windows": ["winapi"],
		"linux": ["luaposix"],
		"macos": ["luaposix"]
	}
}
```

lde activates `windows`, `linux` or `macos` automatically based on the operating system, so optional dependencies can be gated by platform with no extra configuration. Custom feature names can be defined for anything else. See [optional dependencies](/docs/package-manager/features/optional-dependencies) for the full picture.
