// PROTOTYPE: the same text + cursor-trail through the raw SDL_GPU API. We own the
// pipelines, the vertex buffer upload, the atlas upload and the render pass.
package render_bench

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"
import bench "../platform-bench/common"

Vert :: struct {
	pos, uv: [2]f32,
}

MAX_GLYPHS :: 60_000

Fx_Gpu :: struct {
	window:     ^sdl.Window,
	device:     ^sdl.GPUDevice,
	text_pipe:  ^sdl.GPUGraphicsPipeline,
	trail_pipe: ^sdl.GPUGraphicsPipeline,
	atlas:      ^sdl.GPUTexture,
	sampler:    ^sdl.GPUSampler,
	vbuf:       ^sdl.GPUBuffer,
	xfer:       ^sdl.GPUTransferBuffer,
	ts:         Text_State,
	u:          Trail_Uniforms,
	w, h:       i32,
}

gpu_shader :: proc(device: ^sdl.GPUDevice, entry: cstring, stage: sdl.GPUShaderStage, samplers, ubufs: u32) -> ^sdl.GPUShader {
	src := MSL_GPU_FX
	sh := sdl.CreateGPUShader(device, {
		code = raw_data(transmute([]u8)src), code_size = len(src), entrypoint = entry,
		format = {.MSL}, stage = stage, num_samplers = samplers, num_uniform_buffers = ubufs,
	})
	if sh == nil { fmt.eprintln("CreateGPUShader:", entry, sdl.GetError()); os.exit(1) }
	return sh
}

fx_gpu :: proc(window: ^sdl.Window, file: string, frames: int, vsync: bool) {
	s: Fx_Gpu
	s.window = window
	sdl.GetWindowSizeInPixels(window, &s.w, &s.h)
	s.device = sdl.CreateGPUDevice({.MSL}, false, nil)
	if s.device == nil { fmt.eprintln("CreateGPUDevice:", sdl.GetError()); os.exit(1) }
	_ = sdl.ClaimWindowForGPUDevice(s.device, window)
	_ = sdl.SetGPUSwapchainParameters(s.device, window, .SDR, vsync ? .VSYNC : .IMMEDIATE)
	fmt.printfln("gpu driver %s", sdl.GetGPUDeviceDriver(s.device))
	swap_fmt := sdl.GetGPUSwapchainTextureFormat(s.device, window)

	vtext := gpu_shader(s.device, "vtext", .VERTEX, 0, 1)
	ftext := gpu_shader(s.device, "ftext", .FRAGMENT, 1, 0)
	vfull := gpu_shader(s.device, "vfull", .VERTEX, 0, 0)
	ftrail := gpu_shader(s.device, "ftrail", .FRAGMENT, 0, 1)

	// Text: premultiplied-free alpha blend of the atlas coverage over the background.
	vb_desc := sdl.GPUVertexBufferDescription{slot = 0, pitch = size_of(Vert), input_rate = .VERTEX}
	attrs := [2]sdl.GPUVertexAttribute{
		{location = 0, buffer_slot = 0, format = .FLOAT2, offset = 0},
		{location = 1, buffer_slot = 0, format = .FLOAT2, offset = 8},
	}
	text_target := sdl.GPUColorTargetDescription{format = swap_fmt, blend_state = {
		enable_blend = true, color_blend_op = .ADD, alpha_blend_op = .ADD,
		src_color_blendfactor = .SRC_ALPHA, dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
		src_alpha_blendfactor = .ONE, dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
	}}
	s.text_pipe = sdl.CreateGPUGraphicsPipeline(s.device, {
		vertex_shader = vtext, fragment_shader = ftext, primitive_type = .TRIANGLELIST,
		vertex_input_state = {vertex_buffer_descriptions = &vb_desc, num_vertex_buffers = 1, vertex_attributes = &attrs[0], num_vertex_attributes = 2},
		target_info = {color_target_descriptions = &text_target, num_color_targets = 1},
	})

	// Trail: fullscreen triangle, added on top of whatever is already there.
	trail_target := sdl.GPUColorTargetDescription{format = swap_fmt, blend_state = {
		enable_blend = true, color_blend_op = .ADD, alpha_blend_op = .ADD,
		src_color_blendfactor = .ONE, dst_color_blendfactor = .ONE,
		src_alpha_blendfactor = .ONE, dst_alpha_blendfactor = .ONE,
	}}
	s.trail_pipe = sdl.CreateGPUGraphicsPipeline(s.device, {
		vertex_shader = vfull, fragment_shader = ftrail, primitive_type = .TRIANGLELIST,
		target_info = {color_target_descriptions = &trail_target, num_color_targets = 1},
	})
	if s.text_pipe == nil || s.trail_pipe == nil { fmt.eprintln("CreateGPUGraphicsPipeline:", sdl.GetError()); os.exit(1) }

	s.ts = text_state_load(window, file)
	f := &s.ts.font

	// Atlas: R8 coverage texture, uploaded once.
	s.atlas = sdl.CreateGPUTexture(s.device, {type = .D2, format = .R8_UNORM, usage = {.SAMPLER}, width = u32(f.atlas_w), height = u32(f.atlas_h), layer_count_or_depth = 1, num_levels = 1})
	s.sampler = sdl.CreateGPUSampler(s.device, {min_filter = .NEAREST, mag_filter = .NEAREST, address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE})
	atlas_bytes := u32(f.atlas_w * f.atlas_h)
	atlas_xfer := sdl.CreateGPUTransferBuffer(s.device, {usage = .UPLOAD, size = atlas_bytes})
	copy(([^]u8)(sdl.MapGPUTransferBuffer(s.device, atlas_xfer, false))[:atlas_bytes], f.atlas)
	sdl.UnmapGPUTransferBuffer(s.device, atlas_xfer)
	cmd := sdl.AcquireGPUCommandBuffer(s.device)
	cp := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(cp, {transfer_buffer = atlas_xfer, pixels_per_row = u32(f.atlas_w), rows_per_layer = u32(f.atlas_h)}, {texture = s.atlas, w = u32(f.atlas_w), h = u32(f.atlas_h), d = 1}, false)
	sdl.EndGPUCopyPass(cp)
	_ = sdl.SubmitGPUCommandBuffer(cmd)

	vbytes := u32(MAX_GLYPHS * 6 * size_of(Vert))
	s.vbuf = sdl.CreateGPUBuffer(s.device, {usage = {.VERTEX}, size = vbytes})
	s.xfer = sdl.CreateGPUTransferBuffer(s.device, {usage = .UPLOAD, size = vbytes})

	measure("fx-gpu", frames, &s, proc(frame: int, user: rawptr) {
		s := cast(^Fx_Gpu)user
		ev: sdl.Event
		for sdl.PollEvent(&ev) {}
		text := s.ts.data[s.ts.starts[(frame * 7) % len(s.ts.starts)]:]
		trail_update(&s.u, frame, f32(s.w), f32(s.h))

		verts := ([^]Vert)(sdl.MapGPUTransferBuffer(s.device, s.xfer, true))[:MAX_GLYPHS * 6]
		n := build_quads(verts, &s.ts.font, text, f32(s.w), f32(s.h))
		sdl.UnmapGPUTransferBuffer(s.device, s.xfer)

		cmd := sdl.AcquireGPUCommandBuffer(s.device)
		cp := sdl.BeginGPUCopyPass(cmd)
		sdl.UploadToGPUBuffer(cp, {transfer_buffer = s.xfer}, {buffer = s.vbuf, size = u32(n * size_of(Vert))}, true)
		sdl.EndGPUCopyPass(cp)

		swap: ^sdl.GPUTexture
		if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd, s.window, &swap, nil, nil) || swap == nil {
			_ = sdl.SubmitGPUCommandBuffer(cmd)
			return
		}
		target := sdl.GPUColorTargetInfo{texture = swap, clear_color = {0x1E / 255.0, 0x1E / 255.0, 0x2E / 255.0, 1}, load_op = .CLEAR, store_op = .STORE}
		pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)

		sdl.BindGPUGraphicsPipeline(pass, s.text_pipe)
		res := [2]f32{f32(s.w), f32(s.h)}
		sdl.PushGPUVertexUniformData(cmd, 0, &res, size_of(res))
		sdl.BindGPUVertexBuffers(pass, 0, &sdl.GPUBufferBinding{buffer = s.vbuf}, 1)
		sdl.BindGPUFragmentSamplers(pass, 0, &sdl.GPUTextureSamplerBinding{texture = s.atlas, sampler = s.sampler}, 1)
		sdl.DrawGPUPrimitives(pass, u32(n), 1, 0, 0)

		sdl.BindGPUGraphicsPipeline(pass, s.trail_pipe)
		sdl.PushGPUFragmentUniformData(cmd, 0, &s.u, size_of(s.u))
		sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)

		sdl.EndGPURenderPass(pass)
		_ = sdl.SubmitGPUCommandBuffer(cmd)
	})
	sdl.Quit()
}

// Same layout as build_geometry but six plain vertices per glyph and no index buffer.
build_quads :: proc(out: []Vert, f: ^bench.Font, text: []u8, w, h: f32) -> int {
	n := 0
	aw, ah := f32(f.atlas_w), f32(f.atlas_h)
	baseline := f.ascent + 8
	start := 0
	for start < len(text) && baseline < h {
		end := start
		for end < len(text) && text[end] != '\n' do end += 1
		pen := f32(8)
		for ch in text[start:end] {
			if pen >= w || n + 6 > len(out) do break
			code := int(ch)
			if code < bench.FIRST_CHAR || code >= bench.FIRST_CHAR + bench.NUM_CHARS do code = ' '
			bc := &f.chars[code - bench.FIRST_CHAR]
			if bc.x1 > bc.x0 {
				x0, y0 := pen + bc.xoff, baseline + bc.yoff
				x1, y1 := x0 + f32(bc.x1 - bc.x0), y0 + f32(bc.y1 - bc.y0)
				u0, v0, u1, v1 := f32(bc.x0) / aw, f32(bc.y0) / ah, f32(bc.x1) / aw, f32(bc.y1) / ah
				tl, tr, br, bl := Vert{{x0, y0}, {u0, v0}}, Vert{{x1, y0}, {u1, v0}}, Vert{{x1, y1}, {u1, v1}}, Vert{{x0, y1}, {u0, v1}}
				out[n], out[n + 1], out[n + 2], out[n + 3], out[n + 4], out[n + 5] = tl, tr, br, tl, br, bl
				n += 6
			}
			pen += bc.xadvance
		}
		baseline += f.line_h
		start = end + 1
	}
	return n
}
