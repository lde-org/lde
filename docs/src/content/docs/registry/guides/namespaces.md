---
title: Namespaces
order: 1
---

By default, the lde registry simply hosts all packages under their own names.

Anybody can take any package name, as long as it is not already taken by another package.

This has issues, however:
1. Name squatting: People could take over useful package names and leave them dormant from well intended use.
2. Typo squatting: Taking over package names similar to existing ones to try and deceive users into using the wrong package.

> [!NOTE]
> For example, you have a package named `nexus`. Now, it has a useful json parser you want to share as `nexus-json` and do so. Well, someone just decided to publish `nexus-xml` and now people think you made it and wrongfully trust it!

## Namespaces

This is where namespaces come in. A namespace is a way to group related packages together under a common prefix. For example, `nexus-json` and `nexus-xml` could both be under the namespace `nexus`.

### Usage

To use a namespace, adjust your `lde.json` `"name"` field to include the prefix and a slash:

```json
{
  "name": "nexus/json",
}
```

Upon first publish, if the namespace isn't already registered, the PR will request the creation and assignment to you.

### Creating Namespaces

You can also create a namespace without first creating a package via submitting an issue.

To do this, use the [claim](/registry/claim) page, which will fill out an issue for you to submit.

A moderator will have to approve the namespace, but once approved, you'll be able to publish packages under that namespace without issue.
