---
title: Experimenting with busted ported to lpm
author: David Cruz
published: 2026-02-22
description: Exploring a port of busted, Lua's most popular test runner, to run natively as an lpm tool and what it revealed about lpm's current limitations with luarocks packages.
---

[busted](https://lunarmodules.github.io/busted/) is the most popular test runner for lua by far. As a test of lpm's capabilities, I've made it my goal to port it over to lpm over time.

Previously, I was satisfied with porting over just the core of busted, no runner itself. This time, I got the runner working, and ported it as an lpm tool you can use quite easily.

Just run this:

```sh
lpm install --git https://github.com/codebycruz/busted
busted
```

![busted running via lpm](https://i.imgur.com/W3w84Db.png)

This is also what motivated some fixes to lpm around running packages that use an external Lua engine, which are included in [v0.6.2](/blog/lpm-0.6.2).

## The future of busted for lpm

As much as it'd be cool to simply use a ported version of busted, it's not really sustainable since we have to ensure every single dependency is ported over and up to date. Additionally, versioning it would be a nightmare.

That's why I've accepted it, lpm needs to get support for running luarocks packages natively.

You can track the issue for this here: https://github.com/lde-org/lde/issues/53

## What about lpm-test?

Supporting busted isn't particularly about the project itself but more for making the switch to lpm actually feasible for real world projects.

I will always maintain and recommend `lpm-test` as the built-in test runner for lpm, the same as how nodejs can have its built-in test runner and people can still choose to use `jest` instead.
