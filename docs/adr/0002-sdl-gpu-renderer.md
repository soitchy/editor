# Draw with the raw SDL GPU API

v1 renders with the SDL GPU API: our own pipelines, a glyph atlas and a vertex buffer, with text drawn as one batch per frame. Not `SDL_Renderer`, and not a CPU canvas.

## Why

- CPU canvas paths spent 4-5ms of CPU per frame at 2560×1600 on an M5, most of a 144Hz budget. A GPU glyph batch spent about 1ms.
- Custom shaders for cursor trails and typing effects are a goal. `SDL_Renderer` can take a custom fragment shader, but only as a post-process on SDL's GPU backend. Effects that move glyphs need a vertex shader, which only the GPU API gives.
- The shader toolchain cost is the same either way, so `SDL_Renderer` would only have saved about 100 lines of setup, at the price of a likely rewrite.

## Consequences

- Shaders must be authored once and shipped for each backend (MSL, SPIR-V, DXIL). The build step is not designed yet; SDL's own examples keep HLSL source and precompiled outputs.
- The prototype ran on macOS with MSL only. Windows and Wayland are unmeasured.
- Prototype code lives on branch `prototype/present-path`, not main.
