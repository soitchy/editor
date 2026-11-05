// PROTOTYPE, throwaway. Answers ticket 019: which SDL3 present path can scroll
// a 100MB file at 144Hz? Three modes draw the same screen of text per frame:
//   surface:  CPU canvas -> window surface
//   texture:  CPU canvas -> SDL_Renderer streaming texture
//   geometry: glyph atlas texture + one SDL_RenderGeometry batch (GPU grid text)
// Reuses ../platform-bench/common for the font and CPU rasteriser.
package render_bench

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:sys/posix"
import "core:time"
import sdl "vendor:sdl3"
import bench "../platform-bench/common"

BUDGET_MS :: 1000.0 / 144.0

cpu_seconds :: proc() -> f64 {
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		ru: posix.rusage
		posix.getrusage(.SELF, &ru)
		return f64(ru.ru_utime.tv_sec) + f64(ru.ru_utime.tv_usec) / 1e6 + f64(ru.ru_stime.tv_sec) + f64(ru.ru_stime.tv_usec) / 1e6
	}
	return 0
}

ms :: proc(d: time.Duration) -> f64 { return f64(d) / 1e6 }

report :: proc(name: string, xs: []f64) {
	s := slice.clone(xs)
	slice.sort(s)
	n := len(s)
	fmt.printfln("  %-8s median %.2f  p99 %.2f  max %.2f ms", name, s[n / 2], s[n * 99 / 100], s[n - 1])
}

// Builds quads for the visible lines into `verts`/`idx`. Positions are render pixels.
build_geometry :: proc(verts: ^[dynamic]sdl.Vertex, idx: ^[dynamic]i32, f: ^bench.Font, text: []u8, w, h: f32) {
	clear(verts)
	clear(idx)
	col := sdl.FColor{0xCD / 255.0, 0xD6 / 255.0, 0xF4 / 255.0, 1}
	aw, ah := f32(f.atlas_w), f32(f.atlas_h)
	baseline := f.ascent + 8
	start := 0
	for start < len(text) && baseline < h {
		end := start
		for end < len(text) && text[end] != '\n' do end += 1
		pen := f32(8)
		for ch in text[start:end] {
			if pen >= w do break
			code := int(ch)
			if code < bench.FIRST_CHAR || code >= bench.FIRST_CHAR + bench.NUM_CHARS do code = ' '
			bc := &f.chars[code - bench.FIRST_CHAR]
			if bc.x1 > bc.x0 {
				x0 := pen + bc.xoff
				y0 := baseline + bc.yoff
				x1 := x0 + f32(bc.x1 - bc.x0)
				y1 := y0 + f32(bc.y1 - bc.y0)
				u0, v0 := f32(bc.x0) / aw, f32(bc.y0) / ah
				u1, v1 := f32(bc.x1) / aw, f32(bc.y1) / ah
				base := i32(len(verts))
				append(verts, sdl.Vertex{{x0, y0}, col, {u0, v0}}, sdl.Vertex{{x1, y0}, col, {u1, v0}}, sdl.Vertex{{x1, y1}, col, {u1, v1}}, sdl.Vertex{{x0, y1}, col, {u0, v1}})
				append(idx, base, base + 1, base + 2, base, base + 2, base + 3)
			}
			pen += bc.xadvance
		}
		baseline += f.line_h
		start = end + 1
	}
}

main :: proc() {
	mode := "geometry"
	file := ""
	frames := 600
	vsync := false
	for i := 1; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--mode": i += 1; mode = os.args[i]
		case "--file": i += 1; file = os.args[i]
		case "--frames": i += 1; frames, _ = strconv.parse_int(os.args[i])
		case "--vsync": vsync = true
		}
	}
	if file == "" { fmt.eprintln("usage: --mode surface|texture|geometry --file <path> [--frames N] [--vsync]"); os.exit(1) }

	_ = sdl.Init({.VIDEO})
	window := sdl.CreateWindow("render bench (PROTOTYPE)", bench.WINDOW_W, bench.WINDOW_H, sdl.WINDOW_HIGH_PIXEL_DENSITY)
	w, h: i32
	sdl.GetWindowSizeInPixels(window, &w, &h)

	_ = sdl.RaiseWindow(window)
	{
		x, y, ww, wh: i32
		sdl.GetWindowPosition(window, &x, &y)
		sdl.GetWindowSize(window, &ww, &wh)
		fmt.printfln("WINRECT %d,%d,%d,%d", x, y, ww, wh)
	}
	if mode == "fx-renderer" { fx_renderer(window, file, frames, vsync); return }
	if mode == "fx-gpu" { fx_gpu(window, file, frames, vsync); return }

	renderer: ^sdl.Renderer
	canvas_tex, atlas_tex: ^sdl.Texture
	if mode != "surface" {
		renderer = sdl.CreateRenderer(window, nil)
		sdl.SetRenderVSync(renderer, vsync ? 1 : 0)
		fmt.printfln("renderer %s, video %s", sdl.GetRendererName(renderer), sdl.GetCurrentVideoDriver())
	}

	font, _ := bench.font_load(15 * f32(w) / bench.WINDOW_W)
	canvas := bench.canvas_make(int(w), int(h))
	if mode == "texture" do canvas_tex = sdl.CreateTexture(renderer, .XRGB8888, .STREAMING, w, h)
	if mode == "geometry" {
		// Alpha-only atlas expanded to white RGBA so vertex colour tints it.
		rgba := make([]u32, font.atlas_w * font.atlas_h)
		for a, i in font.atlas do rgba[i] = u32(a) << 24 | 0x00FFFFFF
		atlas_tex = sdl.CreateTexture(renderer, .ARGB8888, .STATIC, i32(font.atlas_w), i32(font.atlas_h))
		sdl.UpdateTexture(atlas_tex, nil, raw_data(rgba), i32(font.atlas_w * 4))
		sdl.SetTextureBlendMode(atlas_tex, sdl.BLENDMODE_BLEND)
		sdl.SetTextureScaleMode(atlas_tex, .NEAREST)
	}

	data := bench.load_file(file)
	starts := make([dynamic]int, 0, 3_000_000)
	append(&starts, 0)
	for b, i in data do if b == '\n' && i + 1 < len(data) do append(&starts, i + 1)
	fmt.printfln("mode %s, vsync %v, %d lines, %dx%d px", mode, vsync, len(starts), w, h)

	verts: [dynamic]sdl.Vertex
	idx: [dynamic]i32
	draw_t, pres_t, total_t := make([]f64, frames), make([]f64, frames), make([]f64, frames)
	cpu0 := cpu_seconds()
	wall0 := time.now()
	for f in 0 ..< frames {
		ev: sdl.Event
		for sdl.PollEvent(&ev) do if ev.type == .QUIT do return
		text := data[starts[(f * 7) % len(starts)]:]
		t0 := time.now()
		switch mode {
		case "geometry": build_geometry(&verts, &idx, &font, text, f32(w), f32(h))
		case: bench.draw_text_screen(&canvas, &font, text)
		}
		t1 := time.now()
		switch mode {
		case "surface":
			dst := sdl.GetWindowSurface(window)
			src := sdl.CreateSurfaceFrom(w, h, .XRGB8888, raw_data(canvas.pixels), w * 4)
			sdl.BlitSurface(src, nil, dst, nil)
			sdl.DestroySurface(src)
			sdl.UpdateWindowSurface(window)
		case "texture":
			sdl.UpdateTexture(canvas_tex, nil, raw_data(canvas.pixels), w * 4)
			sdl.RenderTexture(renderer, canvas_tex, nil, nil)
			sdl.RenderPresent(renderer)
		case "geometry":
			sdl.SetRenderDrawColor(renderer, 0x1E, 0x1E, 0x2E, 0xFF)
			sdl.RenderClear(renderer)
			sdl.RenderGeometry(renderer, atlas_tex, raw_data(verts), i32(len(verts)), raw_data(idx), i32(len(idx)))
			sdl.RenderPresent(renderer)
		}
		t2 := time.now()
		draw_t[f], pres_t[f], total_t[f] = ms(time.diff(t0, t1)), ms(time.diff(t1, t2)), ms(time.diff(t0, t2))
	}
	wall := time.duration_seconds(time.since(wall0))
	cpu := cpu_seconds() - cpu0
	over := 0
	for t in total_t do if t > BUDGET_MS do over += 1
	fmt.printfln("%d frames in %.2fs = %.0f fps, cpu %.0f%%, %d frames over %.2fms budget", frames, wall, f64(frames) / wall, cpu / wall * 100, over, BUDGET_MS)
	report("build", draw_t)
	report("present", pres_t)
	report("total", total_t)

	// Idle: no events, no redraw. A blocking wait should cost ~0 CPU.
	cpu1 := cpu_seconds()
	ev: sdl.Event
	_ = sdl.WaitEventTimeout(&ev, 2000)
	fmt.printfln("idle 2s: cpu %.1f ms", (cpu_seconds() - cpu1) * 1000)
	sdl.Quit()
}

println_summary :: proc(label: string, frames: int, wall, cpu: f64, times: []f64) {
	fmt.printfln("%s: %d frames in %.2fs = %.0f fps, cpu %.0f%%", label, frames, wall, f64(frames) / wall, cpu / wall * 100)
	report("frame", times)
}

// Shared setup for the shader modes: font, file and a line index.
Text_State :: struct {
	font:   bench.Font,
	data:   []u8,
	starts: [dynamic]int,
}

text_state_load :: proc(window: ^sdl.Window, file: string) -> (s: Text_State) {
	w, h: i32
	sdl.GetWindowSizeInPixels(window, &w, &h)
	s.font, _ = bench.font_load(15 * f32(w) / bench.WINDOW_W)
	s.data = bench.load_file(file)
	s.starts = make([dynamic]int, 0, 3_000_000)
	append(&s.starts, 0)
	for b, i in s.data do if b == '\n' && i + 1 < len(s.data) do append(&s.starts, i + 1)
	return
}
