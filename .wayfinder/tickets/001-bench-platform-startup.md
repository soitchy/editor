---
id: 001
title: "Benchmark startup and file load: native Win32 vs SDL3"
type: wayfinder:task
status: closed
assignee: jake.shepherd
blocked_by: []
parent: map.md
---

# Benchmark startup and file load: native Win32 vs SDL3

## Question

Build minimal Odin spikes (native Win32, SDL3) that open a window and render a first frame of text, then load and display a large file (~100MB). Measure on Windows: cold start → first frame with text, and file load → first frame of its content. Record numbers, method, and rough code size/maintenance burden of each spike so the platform choice can weigh startup against ease of maintenance.

## Context

sokol was dropped from this benchmark: [IMGUI and text rendering options in Odin](002-imgui-text-rendering.md) found its Linux window layer is X11-only, which conflicts with the Wayland-only Linux target.

## Resolution

Measured on macOS (Apple M5) at your request. Windows numbers moved to [Run the platform benchmark on Windows](016-bench-platform-windows.md). Spikes, method, full table and how to run them: [`spikes/platform-bench/README.md`](../../spikes/platform-bench/README.md).

Medians in ms since spawn, 20 runs, 100MB file read from the page cache:

| | native (AppKit+Metal) | SDL3 surface | SDL3 GPU (Metal) |
|---|---:|---:|---:|
| first frame with text | 131 | 140 | 136 |
| first frame of 100MB file | 148 | 154 | 150 |

- On macOS, SDL3 costs only 5–9ms more than native. AppKit setup takes ~90ms either way (`NSApplication` ~62ms, `NSWindow` ~31ms), so every option misses the "well under 100ms" target (~130ms).
- The first launch of a newly built binary costs ~250ms more (macOS checks it). Users pay this once per install.
- File load is the same on every layer: ~11ms to read 100MB from cache, ~4ms to the first screen, ~13ms to scan every newline. A cold disk read was not measured.
- Maintenance: SDL3 adds a 2.5MB dylib (2.8MB DLL) and one ~94-line file that covers every OS. Native is ~90–150 lines per OS, and no Wayland spike was written.
- The Win32 spike (GDI, plus D3D11 via `--gpu`) type-checks for Windows but has never run.
