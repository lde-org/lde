---
title: Project Structure
order: 2
---

# Project Structure

The structure of an lde project is very simple, but it is enforced.

Your entrypoint _must_ be `/src/init.lua`, and dependencies resolve purely in a file tree order.

This is very important so that packages can be easily resolved via package.path and so simple cases can resolve to lightweight symlinking.

```
myproject/
├── lde.json # Configuration
├── .luarc.json # This is what gives your editor types
├── .gitignore
├── src/
│   └── init.lua # Your entrypoint
└── tests/
    └── test.lua # Can have multiple files, name doesn't matter
```
