---
id: 019
title: Choose the present path and text renderer
type: wayfinder:prototype
status: closed
assignee: jake.shepherd
blocked_by: []
parent: map.md
---

# Choose the present path and text renderer

## Question

On SDL3, how do pixels reach the screen: the window surface (CPU canvas), `SDL_Renderer`, or the SDL GPU API with a glyph-atlas grid renderer? Prototype each drawing a full screen of text every frame while scrolling a 100MB file, and measure frame time against the 7ms budget (144Hz), idle CPU with redraw-on-event only, and startup cost. Also settle which rasterizer the prototype uses first (stb_truetype vs SDL3_ttf) and whether the own-IMGUI-plus-grid-renderer shape suggested by research fits.

## Context

[Choose the platform layer](009-choose-platform-layer.md) picked SDL3 and left the present path open. [IMGUI and text rendering options in Odin](002-imgui-text-rendering.md) suggested a small own IMGUI plus a dedicated grid renderer. The GPU path added ~73ms to Windows startup in [Run the platform benchmark on Windows](016-bench-platform-windows.md), but 144Hz scrolling may need it anyway.

## Resolution

v1 draws with the **raw SDL GPU API** (own pipelines, glyph atlas, vertex buffer, render pass), not `SDL_Renderer`. Recorded in [ADR 0002](../../docs/adr/0002-sdl-gpu-renderer.md). Prototype: branch `prototype/present-path`, `spikes/render-bench/` (not merged).

Measured on macOS (Apple M5, 2560×1600 pixels, 120Hz display, scrolling the 100MB file; every path hit the 120fps display cap, so CPU cost is what separates them):

| Path | CPU build/frame | CPU use |
|---|---:|---:|
| window surface (CPU canvas) | 1.6ms | 61% |
| `SDL_Renderer` texture (CPU canvas) | 1.8ms | 47% |
| `SDL_Renderer` geometry (glyph atlas) | 0.12ms | 12% |
| `SDL_Renderer` + custom shader (cursor trail) | | 12% |
| raw SDL GPU + text pipeline + trail pass | | 8% |

- **CPU canvas paths are out:** 4-5ms of CPU per frame against a 6.9ms budget at 144Hz.
- **Custom shaders work on both GPU paths, but `SDL_Renderer` only gives a fragment-shader post-process**, and it runs on SDL's GPU backend, so the shader toolchain cost is identical. Typing effects that move glyphs need a vertex shader, so the GPU API wins. Cost: ~175 lines against ~71.
- **Idle CPU is ~0** on every path when blocking on events.
- **Open:** the shader build step (author once, ship MSL/SPIR-V/DXIL), and Windows and Wayland numbers. The prototype only ran on macOS with MSL.
