---
title: Timing Builds
order: 4
---

You can get a timings report of what takes the largest amount of time to build in your programs with `lde <sync/run> --timings`.

![timings](/docs-assets/timings.png)

> This is an example output from running it on lde itself.

## JSON Report

Additionally, you can pass `--json` to generate a JSON machine readable report.

This is useful for LLMs or other tools.
