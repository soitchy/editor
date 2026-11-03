---
id: 002
title: IMGUI and text rendering options in Odin
type: wayfinder:research
status: closed
assignee: jake.shepherd
blocked_by: []
parent: map.md
---

# IMGUI and text rendering options in Odin

## Question

What IMGUI options fit an Odin editor (microui, Dear ImGui bindings, Clay, rolling our own), and how is text rendered: glyph rasterization (stb_truetype, FreeType, DirectWrite/CoreText), glyph atlases, shaping/ligature needs? Which pair best with SDL3, sokol, or native windows?

## Resolution

Findings: branch `research/imgui-text-rendering`, file `research/imgui-text-rendering.md`. Sources are primary: Odin's source tree, upstream repos and headers, Microsoft docs.

- **Platform:** SDL3 is the only option in Odin's vendor tree covering Windows, macOS and Wayland-only Linux, and it prefers Wayland by default. **sokol's Linux window layer is X11-only**, and its Linux high-DPI support is marked TODO.
- **UI:**
  - `vendor:microui` is pure Odin with fixed arrays and zero heap use.
  - Clay does layout only, in one arena, with official Odin bindings.
  - Dear ImGui needs a C++ build and does no shaping.
- **Shaping:** `vendor:kb_text_shape` ships with Odin: OpenType shapers, takes our allocator, Zlib licence, so HarfBuzz isn't needed. Programming-font ligatures are untested.
- **Rasterizing:**
  - stb_truetype has no hinting and no ClearType.
  - Odin has no DirectWrite bindings, so we'd write them; it does ship CoreText bindings.
  - SDL3_ttf (FreeType + HarfBuzz) gives LCD and SDF text out of the box.
- **LCD text:** SDL3's GPU API has no dual-source blending, but a grid renderer knows each cell's background, so it can blend in the shader.
- **The researcher suggests:**
  - SDL3.
  - A small own IMGUI modelled on microui for the UI chrome, plus a dedicated grid renderer for text.
  - kb_text_shape with an ASCII fast path and per-line cache.
  - stb_truetype first, then DirectWrite/CoreText, with a preallocated atlas.
- **Not yet measured:** SDL3 vs raw Win32 cold start, font ligatures, Wayland IME.
