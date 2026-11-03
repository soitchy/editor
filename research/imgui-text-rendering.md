# IMGUI options and text rendering for an Odin editor

Research ticket: which immediate-mode UI and which text stack fit the editor in `MISSION.txt`? The editor is Odin, Helix-style modal editing, a 144 Hz frame (about 7 ms), cold start well under 100 ms, few heap allocations, Windows first, then macOS and Wayland-only Linux.

Researched 2026-11-03 from primary sources: official repos, the Odin source tree, vendor headers, and OS API docs. Claims marked **(inference)** are my reasoning, not something a source states.

---

## TL;DR

1. **UI layer: write our own small IMGUI for editor chrome, with vendored `microui` as the starting point or reference.** The text view itself should be a dedicated grid renderer, not IMGUI widgets. Dear ImGui and Clay can work but fit worse (see the matrix below).
2. **Shaping: `vendor:kb_text_shape`.** It already ships with Odin, it is Zlib-licensed, it takes an explicit allocator, and it supports all OpenType shapers. That is enough for programming-font ligatures without HarfBuzz's C++ build.
3. **Rasterization:** start with `vendor:stb/truetype`, which is pure C, already in Odin, and fast to set up. Behind a small interface, plan for **DirectWrite on Windows** (ClearType and hinting) and **CoreText on macOS**. Odin already ships CoreText bindings in `core:sys/darwin`. On Linux, FreeType is the realistic quality path. SDL3_ttf bundles FreeType and HarfBuzz if we want that shortcut.
4. **Glyph atlas: one dynamic atlas** keyed by (font, glyph id, size, subpixel x-offset), uploaded through dirty rectangles. Draw the visible text as a **cell grid** (refterm style) or as instanced quads.
5. **Platform layer: SDL3.** It is in `vendor:sdl3`, prefers Wayland by default, and has a clear DPI model. **sokol_app is ruled out:** its Linux backend is X11-only and high-DPI on Linux is marked TODO. Native per-OS windows are the later option if SDL3's startup cost or IME handling disappoints.
6. **LCD/subpixel AA is optional and costly.** macOS turned it off by default in Mojave. **SDL_GPU has no dual-source blend factors**, so LCD text on SDL_GPU would have to be blended in the shader against a known background colour. That is easy for a monospace grid with known cell background colours.

---

## 1. IMGUI options

### 1.1 microui (Odin vendor, pure-Odin port)

- `vendor:microui` is "an Odin-native source port" of rxi's microui, not a C binding. [microui.odin](https://github.com/odin-lang/Odin/blob/master/vendor/microui/microui.odin)
- It does not render text itself. The host supplies `text_width(font, str)` and `text_height(font)` callbacks, and `Font` is a `distinct rawptr`. The output is a command list of `Jump`, `Clip`, `Rect`, `Text`, and `Icon` commands. [same file](https://github.com/odin-lang/Odin/blob/master/vendor/microui/microui.odin)
- All state lives in fixed arrays inside `Context`, sized by `#config` constants. Defaults include `COMMAND_LIST_SIZE = 256 KiB`, `CONTAINER_POOL_SIZE = 48`, `ID_STACK_SIZE = 32`, `MAX_TEXT_STORE = 1024`, and `MAX_WIDTHS = 16`. The core does no heap allocation. [same file](https://github.com/odin-lang/Odin/blob/master/vendor/microui/microui.odin)
- **Fit:** excellent for allocation and startup goals, and trivially small. The widget set is basic: windows, buttons, sliders, textbox, tree nodes. The layout model is simple rows. **(inference)** It suits a palette, statusline, picker, and popups. It also makes good reference code if we roll our own.

### 1.2 Dear ImGui (C++ through bindings)

- Odin bindings listed by the ImGui wiki: [`L-4/odin-imgui`](https://gitlab.com/L-4/odin-imgui), plus [`alektron/imgui-odin-backends`](https://github.com/alektron/imgui-odin-backends), which has backends written in Odin. C APIs for binding generators come from [dear_bindings](https://github.com/dearimgui/dear_bindings) and [cimgui](https://github.com/cimgui/cimgui). [Bindings wiki](https://github.com/ocornut/imgui/wiki/Bindings)
- I could not confirm from primary sources which ImGui version the L-4 binding tracks. The GitLab README did not render for fetching. An older GitHub wrapper, [Beefster09/odin-imgui](https://github.com/Beefster09/odin-imgui), is pinned to v1.82 and is out of date.
- Fonts in 1.92+: glyphs load on demand, and the atlas starts at 512x128 and grows. Backends need `ImGuiBackendFlags_HasTextures`. The default rasterizer is stb_truetype, which the docs say "is not ideal for fonts rendered at small sizes". The optional `imgui_freetype` adds hinting. DPI is handled through `style.FontScaleDpi` and `style.ScaleAllSizes()`. [docs/FONTS.md](https://github.com/ocornut/imgui/blob/master/docs/FONTS.md)
- No shaping or ligatures; FONTS.md describes per-codepoint glyph lookup. No LCD AA path is documented.
- sokol-odin ships ImGui bridge bindings, but you build Dear ImGui (C++) yourself. [sokol-odin](https://github.com/floooh/sokol-odin)
- **Fit:** the most mature widget set and great for debug tooling. Against it: a C++ toolchain dependency, an opinionated text pipeline we would bypass for the editor view, the heap-allocating ImVector/ImGuiStorage internals **(inference from ImGui's design)**, and a heavier style than "minimal UI".

### 1.3 Clay (C, layout engine with official Odin bindings)

- A "high performance 2D UI layout library". It does layout only and outputs sorted render commands: rects, text, images, borders, scissor. It handles hover through `SetPointerState`/`Hovered()`, has scroll containers, and wraps text by word, newline, or not at all. [clay README](https://github.com/nicbarker/clay)
- Memory: one static arena from `Clay_MinMemorySize()`, with no malloc or free. The README cites about 3.5 MB for 8192 elements. It claims "microsecond layout performance". Zlib licence. [clay README](https://github.com/nicbarker/clay)
- Official Odin bindings live in-repo at [`bindings/odin`](https://github.com/nicbarker/clay/tree/main/bindings/odin). Measure-text is a `proc "c"` callback, and strings are not NUL-terminated. [Odin README](https://github.com/nicbarker/clay/blob/main/bindings/odin/README.md)
- **Fit:** good for flexbox-style chrome such as split panes, a file tree, and popups, with arena allocation that matches the mission. It is a layout engine, not widgets. Focus, text input, and keyboard navigation would still be ours. It also brings a C dependency. **(inference)** Most of the editor's per-frame cost is the text view, which Clay would not handle anyway.

### 1.4 Rolling our own

- **(inference)** The editor's UI is mostly one huge custom widget (the buffer view) plus a handful of overlays: statusline, picker, command palette, completion, and diagnostics. Helix's UI is keyboard-driven, so mouse-heavy widgets matter less. A small Odin IMGUI over a frame arena (`context.temp_allocator`) with IDs, a hot/active pair, a layout stack, and a command buffer is a few hundred lines. microui's source is a direct template.
- This keeps the text pipeline unified: chrome and buffer share the same atlas and shaper.

### 1.5 Comparison matrix

| Option | Language / dependency | Allocation | Text pipeline | Editor fit |
|---|---|---|---|---|
| microui (vendor) | Pure Odin, in tree | Fixed arrays, none | Host-provided | Good chrome, tiny |
| Dear ImGui | C++ via binding | Heap (internal) | Own atlas, stb/FreeType, no shaping | Strong for debug UI, heavy for product |
| Clay | C + official Odin binding | Single arena | Host-provided measure | Layout only |
| Roll own | Pure Odin | Frame arena | Ours | Best control; most work |

---

## 2. Text rendering

### 2.1 Rasterizers

**stb_truetype** (`vendor:stb/truetype`) [header](https://github.com/nothings/stb/blob/master/stb_truetype.h)
- v1.26, no hinting (hinting is listed under "Todo"), and no ClearType-style AA ("cleartype-style AA?" is also a Todo). It supports subpixel *positioning* (`MakeGlyphBitmapSubpixel`, prefilter oversampling) and stresses that this matters because text is "anti-aliased, not hinted". It has SDF output (`GetGlyphSDF`, "expect it to be slow"), `kern` plus basic GPOS kerning, and CFF/Type 2 outlines.
- "NO SECURITY GUARANTEE -- DO NOT USE THIS ON UNTRUSTED FONT FILES". Acceptable for user-chosen fonts.
- Odin's own `vendor:fontstash` port uses stb_truetype, with a skyline atlas that doubles on overflow, dirty-rect uploads, grayscale only, and kerning but no shaping. [fontstash.odin](https://github.com/odin-lang/Odin/blob/master/vendor/fontstash/fontstash.odin) It is a useful reference implementation of an Odin glyph atlas.

**FreeType.** Not in Odin's vendor tree; the [vendor listing](https://github.com/odin-lang/Odin/tree/master/vendor) has no `freetype`. It is available bundled inside SDL3_ttf (below), or as a separate C dependency. It gives hinting, LCD filtering, and the best quality on Linux.

**DirectWrite (Windows).** `IDWriteGlyphRunAnalysis::CreateAlphaTexture` produces either 1-byte "bi-level" or 3-bytes-per-pixel ClearType alpha textures, and `GetAlphaBlendParams` provides the ClearType blend parameters. [MS Learn](https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nn-dwrite-idwriteglyphrunanalysis) Odin has no DirectWrite bindings in `vendor:directx`, which contains d3d11, d3d12, d3d_common, d3d_compiler, dxc, and dxgi. [vendor/directx](https://github.com/odin-lang/Odin/tree/master/vendor/directx) We would hand-write the COM vtables. That is moderate work, and only the factory, font face, and glyph-run analysis interfaces are needed. refterm uses DirectWrite for rasterization and caches glyphs because DirectWrite glyph generation is "extremely slow". [refterm](https://github.com/cmuratori/refterm)

**CoreText (macOS).** Odin ships `core:sys/darwin/CoreText` and `CoreGraphics` bindings. [core/sys/darwin](https://github.com/odin-lang/Odin/tree/master/core/sys/darwin) I did not check how complete they are. Mojave disabled subpixel AA by default; see §2.5.

**SDL3_ttf** (`vendor:sdl3/ttf`). A wrapper over FreeType and HarfBuzz (plus PlutoSVG for colour emoji), currently v3.3.0. [SDL_ttf](https://github.com/libsdl-org/SDL_ttf), [SDL_ttf.h](https://github.com/libsdl-org/SDL_ttf/blob/main/include/SDL3_ttf/SDL_ttf.h) It provides:
- a GPU text engine (`TTF_CreateGPUTextEngine(SDL_GPUDevice*)`) that returns atlas draw sequences, with a configurable atlas size
- LCD rendering (`TTF_RenderText_LCD`, `TTF_HINTING_LIGHT_SUBPIXEL`) to surfaces
- SDF output (`TTF_SetFontSDF`)
- HarfBuzz script, direction, and language settings

Odin binds all three entry points. It links `SDL3_ttf.lib` on Windows and `system:SDL3_ttf` elsewhere. [sdl3_ttf.odin](https://github.com/odin-lang/Odin/blob/master/vendor/sdl3/ttf/sdl3_ttf.odin)
- **(inference)** This is the fastest route to good quality on all three OSes. The costs are an extra DLL at startup and SDL_ttf owning the allocation and caching policy. Shipping it on Windows would mean shipping `SDL3_ttf.dll`, since Odin's vendor directory bundles only `SDL3.dll`/`SDL3.lib`.

### 2.2 Shaping and ligatures

**kb_text_shape** (`vendor:kb_text_shape`) [upstream](https://github.com/JimmyLefevre/kb), [header](https://github.com/JimmyLefevre/kb/blob/main/kb_text_shape.h), [Odin doc.odin](https://github.com/odin-lang/Odin/blob/master/vendor/kb_text_shape/doc.odin)
- Single-header C. It does "ICU-like" segmentation (direction, line, script, word, grapheme) and "Harfbuzz-like" OpenType shaping. It does not rasterize, lay out paragraphs, or select fonts. Zlib licence.
- The header states "All OpenType shapers are supported". It is v2.28g and adds variable fonts. Known gaps: Indic1-model fonts, Traditional Arabic Windows 3.1 fonts, and dictionary word-breaking (for example CJK). It deliberately tries "less hard than Harfbuzz" to be compatible with every font.
- Allocation: allocator callbacks, fixed-memory variants for context, scratchpad, and glyph storage, and size queries. Scratch use during shaping is "very unpredictable", so the scratchpad may grow. The Odin binding passes an Odin allocator via `AllocatorFromOdinAllocator`. Feature toggles by tag (`ShapePushFeature`) let `calt`/`liga` be switched on and off.
- **(inference)** Programming ligatures (Fira Code, JetBrains Mono, Cascadia) are implemented as GSUB `calt` lookups, so a general OpenType shaper should handle them. Not tested here; worth a quick spike.

**HarfBuzz.** The reference shaper. It is a C++ build dependency, though SDL3_ttf bundles it.

**Editor-specific shaping advice (inference):**
- Shape per *line segment* (per run of the same style and script), and cache results keyed by line content hash plus style. Most frames re-render unchanged lines.
- ASCII fast path: for pure-ASCII runs with ligatures off, skip shaping and map codepoints straight to glyph ids. That is the common case in code.
- Ligatures break the "one char = one cell" assumption. The cursor and selection must map clusters to cells; kb returns cluster info per glyph. Helix-style selection over a ligature should split visually or disable the ligature under the cursor.

### 2.3 Glyph atlas

- The pattern in fontstash, ImGui 1.92, and SDL_ttf is the same: rasterize on demand into an atlas, pack it with a skyline, grow on overflow, and upload only dirty rectangles. [fontstash.odin](https://github.com/odin-lang/Odin/blob/master/vendor/fontstash/fontstash.odin), [FONTS.md](https://github.com/ocornut/imgui/blob/master/docs/FONTS.md)
- **(inference)** For an editor, the key is (font face, glyph id rather than codepoint since shaping produces glyph ids, pixel size, subpixel x bucket from 0 to 3). Preallocate a 2048² R8 atlas, or RGB8 for LCD, at startup. That keeps steady-state allocation at zero. On overflow, evict by LRU or clear and rebuild, not grow without bound. `vendor:stb/rect_pack` is available for packing.

### 2.4 Monospace grid and large line counts

- refterm's approach: a `StructuredBuffer` with one `TerminalCell` per cell, holding a packed glyph-atlas coordinate, foreground colour plus flags, and background colour. A single pixel or compute shader computes `cell = (pixel - margin) / cellSize` and reads the atlas texel directly with no sampler. The glyph alpha blends foreground over background in the shader. Underline and strikethrough are done in the shader. [refterm.hlsl](https://github.com/cmuratori/refterm/blob/main/refterm.hlsl)
- refterm's README calls itself a "modern *minimum* speed" for a terminal and claims to be "several orders of magnitude faster than Windows Terminal". [refterm](https://github.com/cmuratori/refterm)
- **(inference)** A 4K screen at about 14 px cells is roughly 270 × 75, around 20k cells. Uploading a 12-byte-per-cell buffer (about 240 KB) each frame is trivial, and one draw call covers the text view. Wide or multi-cell glyphs (ligatures, CJK, emoji) need either multi-cell atlas entries, as refterm supports, or an overlay pass of instanced quads. Selections, cursors, and diagnostics squiggles are per-cell background or flag bits, which also suits Helix's multi-selection view.
- An alternative is instanced quads, one per glyph, with a vertex buffer built per frame from the frame arena. That is more flexible for proportional UI text, and the same atlas serves both.

### 2.5 Subpixel / LCD AA

- **macOS:** Mojave disabled text subpixel AA by default. [WebKit r239306](https://trac.webkit.org/r239306) I found no official Apple statement. **(inference)** Grayscale AA plus Retina density is the macOS norm, so skip LCD there.
- **GPU blending:** correct LCD compositing over arbitrary backgrounds needs per-channel alpha, meaning dual-source blending. D3D11 has `D3D11_BLEND_SRC1_COLOR`/`INV_SRC1_COLOR` ("supports dual-source color blending"). [D3D11_BLEND](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/ne-d3d11-d3d11_blend) **SDL_GPU's `SDL_GPUBlendFactor` has no SRC1 factors.** [SDL_gpu.h](https://github.com/libsdl-org/SDL/blob/main/include/SDL3/SDL_gpu.h)
- **Workaround (inference):** in a grid renderer the cell background is known in the shader, as in refterm, so the per-channel lerp `bg*(1-a_rgb) + fg*a_rgb` can be done in the shader and written opaque. No hardware blending is needed. Text over translucent overlays would fall back to grayscale.
- **Linux:** Wayland's `wl_output` advertises a subpixel layout. **(inference)** With FreeType this is doable, but it adds a lot of complexity for little gain on HiDPI panels. Ship grayscale first.

### 2.6 DPI scaling

- **SDL3 model:** use `SDL_WINDOW_HIGH_PIXEL_DENSITY`; read `SDL_GetWindowDisplayScale()` (content scale × pixel density) and `SDL_GetWindowSizeInPixels()`; react to `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED` and `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED`. Windows and X11 use physical-pixel coordinates, while macOS and Wayland use logical coordinates. [README-highdpi](https://github.com/libsdl-org/SDL/blob/main/docs/README-highdpi.md)
- **Wayland fractional scaling:** `wp_fractional_scale_v1.preferred_scale` comes in 120ths, used with `wp_viewporter` and buffer scale 1. [protocol](https://wayland.app/protocols/fractional-scale-v1) SDL warns that 1:1 scaling (`SDL_VIDEO_WAYLAND_SCALE_TO_DISPLAY`) may be buggy for odd window sizes or scales that are not quarter steps. [README-wayland](https://github.com/libsdl-org/SDL/blob/main/docs/README-wayland.md)
- **(inference)** Rasterize glyphs at the *physical* pixel size (`pt × display_scale`). Do not scale an atlas made at 1x. When the scale changes, flush the atlas and rebuild it. Snap cell sizes to whole physical pixels so the grid stays crisp.

---

## 3. Platform / graphics pairing

| Option | Windows | macOS | Wayland | Notes |
|---|---|---|---|---|
| **SDL3** (`vendor:sdl3`) | yes (DLL bundled in Odin) | yes | **Wayland preferred by default** | SDL_GPU (Vulkan/D3D12/Metal), SDL3_ttf bound; no dual-source blend. [README-wayland](https://github.com/libsdl-org/SDL/blob/main/docs/README-wayland.md), [vendor/sdl3](https://github.com/odin-lang/Odin/tree/master/vendor/sdl3) |
| **sokol** ([sokol-odin](https://github.com/floooh/sokol-odin)) | D3D11 | Metal | **No.** sokol_app is X11-only; Linux high-DPI "TODO" | Lightweight; the ImGui bridge needs a C++ build. [sokol_app.h](https://github.com/floooh/sokol/blob/master/sokol_app.h). A Wayland PR (#425) exists only in forks. |
| **Native per-OS** | Win32 + D3D11 (`core:sys/windows`, `vendor:directx`) | AppKit + Metal (`vendor:darwin`) | Hand-written Wayland client (no Odin vendor bindings) | Fastest startup and full control (dual-source blend, DirectWrite/CoreText); Wayland is the biggest cost |

Notes:
- Wayland window decorations under GNOME depend on libdecor through SDL; without it, windows have no decorations. Toplevel windows cannot position themselves. [README-wayland](https://github.com/libsdl-org/SDL/blob/main/docs/README-wayland.md)
- **(inference)** Recommended path: SDL3 for windowing, input, and IME on all three OSes. For rendering, either SDL_GPU, or our own thin D3D11/Metal/Vulkan layer on SDL's window handle if we want dual-source blending or D3D11's lower init cost. Keep the platform layer behind an Odin interface so a native Win32 backend can replace SDL on Windows if cold start measures badly. Cold start was not measured here; it needs a spike.

---

## 4. Recommendation (supported by the above)

1. **Platform:** SDL3. It is the only off-the-shelf option in Odin's tree covering Windows, macOS, and Wayland-only Linux. sokol is disqualified by the lack of Wayland.
2. **UI:** our own IMGUI, modelled on `vendor:microui` and using the frame arena, for chrome. The text view is a dedicated grid renderer. Add Dear ImGui only as an optional debug overlay, if ever.
3. **Text:** `kb_text_shape` for shaping, plus an ASCII fast path and a line-level shape cache. Rasterize with stb_truetype first, behind an interface, then DirectWrite on Windows and CoreText on macOS for platform-native quality. On Linux, choose between stb and FreeType or SDL3_ttf once quality is measured.
4. **Atlas and draw:** a preallocated R8 atlas (RGB8 when LCD is on) keyed by glyph id, size, and subpixel bucket. Draw the grid with refterm-style per-cell buffers. Do LCD blending in the shader against the known cell background, because SDL_GPU lacks dual-source blending.

## Open questions / spikes

- Measure cold start of SDL3 init plus SDL_GPU device creation against raw Win32 + D3D11. The budget is under 100 ms.
- Check that kb_text_shape produces `calt` ligatures for Fira Code, JetBrains Mono, and Cascadia, and measure its shaping cost per line.
- Check how complete `core:sys/darwin/CoreText` is.
- Check which Dear ImGui version `L-4/odin-imgui` tracks, if we want it for debug UI.
- IME on Wayland via SDL3 (text-input-v3) was not covered by the sources fetched.
