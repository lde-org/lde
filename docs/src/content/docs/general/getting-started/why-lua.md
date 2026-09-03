---
title: Why Lua?
order: 6
---

1. Lua is incredibly simple. It has been chosen for this reason by platforms like Roblox and educational environments for decades, for this reason.
2. LuaJIT is incredibly fast. Large companies bet on it in the background for its performance and use it in production at Cloudflare and other AAA companies.

## Why not Lua?

Due to its focus on simplicity, certain things have not been prioritized, like a rich standard library the equivalent of Python's, or an easy to use package manager as seen with JavaScript's npm, or even system language's like Rust's Cargo.

This has led to lua being overtaken significantly by other languages due to their richer development experience.

**The goal for lde is to fix this.**

## Why lde?

I believe that LuaJIT has vast potential. Its ffi library allowed me to create [Vulkan bindings](https://github.com/bycruz/vkapi) and my own renderer with performance on-par with, if not surpassing, one written in C or Rust.

I think a language that is this powerful, while this accessible, can make a huge difference in terms of productivity and reliability at scale.
