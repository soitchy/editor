---
id: 019
title: Choose the present path and text renderer
type: wayfinder:prototype
status: open
assignee: jake.shepherd
blocked_by: []
parent: map.md
---

# Choose the present path and text renderer

## Question

On SDL3, how do pixels reach the screen: the window surface (CPU canvas), `SDL_Renderer`, or the SDL GPU API with a glyph-atlas grid renderer? Prototype each drawing a full screen of text every frame while scrolling a 100MB file, and measure frame time against the 7ms budget (144Hz), idle CPU with redraw-on-event only, and startup cost. Also settle which rasterizer the prototype uses first (stb_truetype vs SDL3_ttf) and whether the own-IMGUI-plus-grid-renderer shape suggested by research fits.

## Context

[Choose the platform layer](009-choose-platform-layer.md) picked SDL3 and left the present path open. [IMGUI and text rendering options in Odin](002-imgui-text-rendering.md) suggested a small own IMGUI plus a dedicated grid renderer. The GPU path added ~73ms to Windows startup in [Run the platform benchmark on Windows](016-bench-platform-windows.md), but 144Hz scrolling may need it anyway.
