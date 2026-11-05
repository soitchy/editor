---
id: 009
title: Choose the platform layer
type: wayfinder:grilling
status: closed
assignee: jake.shepherd
blocked_by: [002]
parent: map.md
---

# Choose the platform layer

## Question

Which windowing/input/GPU layer does v1 build on (native per-OS, SDL3, other), weighing measured startup and load times against the cost of maintaining it across Windows, macOS, and Wayland?

## Resolution

v1 builds on **SDL3** for windowing, input, clipboard and present, on every OS. Native per-OS windows are not ruled out, but only as a later optimisation. Recorded in [ADR 0001](../../docs/adr/0001-sdl3-platform-layer.md).

- **Why:** measured SDL3 costs are small where they matter ([macOS](001-bench-platform-startup.md): +5-9ms; [Windows](016-bench-platform-windows.md): +17ms on the GPU path, +41ms on the CPU path on a managed machine). No option reaches 100ms, so native would not buy the target. SDL3 is the only vendored layer that covers Wayland, and one file replaces three platform layers for a solo maintainer.
- **Platform seam:** the editor core sees only window, events, clipboard and present, never `SDL_*` types, so a native swap later is about one file per OS.
- **Startup target restated:** "as close to the OS floor as we can get" (~130ms macOS, at least ~118ms Windows on the managed machine) instead of "well under 100ms". [Can macOS startup get under 100ms?](017-macos-startup-under-100ms.md) and [Re-measure Windows startup without endpoint security](018-bench-windows-clean-machine.md) may still move the floors.
- **Left open:** the present path (SDL surface vs SDL GPU) goes to the renderer decision, and Wayland startup numbers stay in the fog.
