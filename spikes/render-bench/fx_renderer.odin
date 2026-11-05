// PROTOTYPE: cursor-trail shader through SDL_Renderer's GPU render state.
// Text is drawn as one glyph-atlas batch into an offscreen target, then the
// target is drawn fullscreen with a custom fragment shader that adds the trail.
package render_bench

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"
import bench "../platform-bench/common"

Fx_Renderer :: struct {
	renderer: ^sdl.Renderer,
	target:   ^sdl.Texture,
	atlas:    ^sdl.Texture,
	state:    ^sdl.GPURenderState,
	ts:       Text_State,
	verts:    [dynamic]sdl.Vertex,
	idx:      [dynamic]i32,
	u:        Trail_Uniforms,
	w, h:     i32,
}

fx_renderer :: proc(window: ^sdl.Window, file: string, frames: int, vsync: bool) {
	s: Fx_Renderer
	sdl.GetWindowSizeInPixels(window, &s.w, &s.h)
	s.renderer = sdl.CreateRenderer(window, "gpu")
	if s.renderer == nil { fmt.eprintln("CreateRenderer(gpu):", sdl.GetError()); os.exit(1) }
	sdl.SetRenderVSync(s.renderer, vsync ? 1 : 0)
	device := sdl.GetGPURendererDevice(s.renderer)
	fmt.printfln("renderer %s, shader formats %v", sdl.GetRendererName(s.renderer), sdl.GetGPUShaderFormats(device))

	src := MSL_RENDERER_FX
	shader := sdl.CreateGPUShader(device, {
		code = raw_data(transmute([]u8)src), code_size = len(src), entrypoint = "main0",
		format = {.MSL}, stage = .FRAGMENT, num_samplers = 1, num_uniform_buffers = 1,
	})
	if shader == nil { fmt.eprintln("CreateGPUShader:", sdl.GetError()); os.exit(1) }
	s.state = sdl.CreateGPURenderState(s.renderer, {fragment_shader = shader})
	if s.state == nil { fmt.eprintln("CreateGPURenderState:", sdl.GetError()); os.exit(1) }

	s.target = sdl.CreateTexture(s.renderer, .ARGB8888, .TARGET, s.w, s.h)
	s.ts = text_state_load(window, file)
	rgba := make([]u32, s.ts.font.atlas_w * s.ts.font.atlas_h)
	for a, i in s.ts.font.atlas do rgba[i] = u32(a) << 24 | 0x00FFFFFF
	s.atlas = sdl.CreateTexture(s.renderer, .ARGB8888, .STATIC, i32(s.ts.font.atlas_w), i32(s.ts.font.atlas_h))
	sdl.UpdateTexture(s.atlas, nil, raw_data(rgba), i32(s.ts.font.atlas_w * 4))
	sdl.SetTextureBlendMode(s.atlas, sdl.BLENDMODE_BLEND)
	sdl.SetTextureScaleMode(s.atlas, .NEAREST)

	measure("fx-renderer", frames, &s, proc(f: int, user: rawptr) {
		s := cast(^Fx_Renderer)user
		ev: sdl.Event
		for sdl.PollEvent(&ev) {}
		text := s.ts.data[s.ts.starts[(f * 7) % len(s.ts.starts)]:]
		build_geometry(&s.verts, &s.idx, &s.ts.font, text, f32(s.w), f32(s.h))
		trail_update(&s.u, f, f32(s.w), f32(s.h))

		sdl.SetRenderTarget(s.renderer, s.target)
		sdl.SetRenderDrawColor(s.renderer, 0x1E, 0x1E, 0x2E, 0xFF)
		sdl.RenderClear(s.renderer)
		sdl.RenderGeometry(s.renderer, s.atlas, raw_data(s.verts), i32(len(s.verts)), raw_data(s.idx), i32(len(s.idx)))
		sdl.SetRenderTarget(s.renderer, nil)

		_ = sdl.SetGPURenderState(s.renderer, s.state)
		_ = sdl.SetGPURenderStateFragmentUniforms(s.state, 0, &s.u, size_of(s.u))
		sdl.RenderTexture(s.renderer, s.target, nil, nil)
		_ = sdl.SetGPURenderState(s.renderer, nil)
		sdl.RenderPresent(s.renderer)
	})
	sdl.Quit()
}
