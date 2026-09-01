---
title: Custom Registry
order: 7
---

# Custom Registry

By default, lde uses the [official registry](https://github.com/lde-org/registry). You can point lde at a different registry by editing `~/.lde/config.json`.

## Configuration

Create or edit `~/.lde/config.json`:

```json
{
  "registry": "https://github.com/your-org/your-registry"
}
```

The registry must follow the same structure as the [official registry](https://github.com/lde-org/registry): a `packages/` directory containing JSON portfiles.

## Hosting a private registry

Fork or clone the [official registry](https://github.com/lde-org/registry) as a starting point, add your own package portfiles under `packages/`, and push it to any GitHub repository. Then point your config at it.

All `lde add`, `lde update`, and `lde publish` commands will use your configured registry.

> [!NOTE]
> In the future, registry scopes will allow you to configure a custom registry at the namespace level, so you won't need to replace the global registry to use private packages alongside public ones.
