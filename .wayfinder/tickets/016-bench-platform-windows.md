---
id: 016
title: Run the platform benchmark on Windows
type: wayfinder:task
status: open
assignee:
blocked_by: []
parent: map.md
---

# Run the platform benchmark on Windows

## Question

On the Windows dev machine, how do native Win32 (GDI and D3D11) and SDL3 (surface and GPU) compare on cold start → first frame with text, and on 100MB file load → first frame? Follow the Windows checklist in [`spikes/platform-bench/README.md`](../../spikes/platform-bench/README.md) and record the machine and all four outputs.

## Context

[Benchmark startup and file load: native Win32 vs SDL3](001-bench-platform-startup.md) measured macOS only: SDL3 was 5–9ms behind native, and AppKit setup took most of the time. Windows is the first platform, so its numbers decide [Choose the platform layer](009-choose-platform-layer.md). The Win32 spike has only been type-checked from macOS.
