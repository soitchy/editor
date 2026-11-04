---
id: 016
title: Run the platform benchmark on Windows
type: wayfinder:task
status: closed
assignee: jake.shepherd
blocked_by: []
parent: map.md
---

# Run the platform benchmark on Windows

## Question

On the Windows dev machine, how do native Win32 (GDI and D3D11) and SDL3 (surface and GPU) compare on cold start → first frame with text, and on 100MB file load → first frame? Follow the Windows checklist in [`spikes/platform-bench/README.md`](../../spikes/platform-bench/README.md) and record the machine and all four outputs.

## Context

[Benchmark startup and file load: native Win32 vs SDL3](001-bench-platform-startup.md) measured macOS only: SDL3 was 5–9ms behind native, and AppKit setup took most of the time. Windows is the first platform, so its numbers decide [Choose the platform layer](009-choose-platform-layer.md). The Win32 spike has only been type-checked from macOS.

## Resolution

Measured on an i9-10900 / Radeon Pro W5500 / Windows 11 Enterprise 26100, a managed machine running CrowdStrike Falcon, Tanium and Defendpoint, so treat these as an upper bound. Method, full table and notes: [`spikes/platform-bench/README.md`](../../spikes/platform-bench/README.md).

Medians in ms since spawn, 20 runs, 100MB file read from the page cache:

| | native GDI | native D3D11 | SDL3 surface | SDL3 GPU (D3D11) |
|---|---:|---:|---:|---:|
| first frame with text | 118 | 215 | 159 | 232 |
| first frame of 100MB file | 167 | 282 | 213 | 283 |

- Every option misses the 100ms target on this machine; native GDI is closest. ~58ms is spent before `main` is reached (macOS: ~11ms), probably the security software.
- SDL3 surface is +41ms over native GDI. Creating a D3D11 device and swapchain costs ~90-130ms on either layer, so the GPU paths are ~100ms slower than the CPU paths; the native-vs-SDL3 gap on the GPU path is only +17ms.
- Reading 100MB from cache takes 38-52ms here (macOS ~11ms), so file load is slower but still does not differ much between layers.
- The Win32 spike ran as written. A clean-machine number is tracked in [Re-measure Windows startup without endpoint security](018-bench-windows-clean-machine.md).
