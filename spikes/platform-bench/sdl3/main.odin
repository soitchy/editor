// SDL3 spike. Two present paths for the same CPU canvas:
//   default:  window surface (SDL_GetWindowSurface + SDL_UpdateWindowSurface)
//   --gpu:    SDL_Renderer with a streaming texture (Metal / D3D11 / Vulkan),
//             closer to what the editor would do once it draws with the GPU.
package sdl3_spike

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"
import bench "../common"

window: ^sdl.Window
renderer: ^sdl.Renderer
texture: ^sdl.Texture

present :: proc(c: ^bench.Canvas) {
	if renderer != nil {
		sdl.UpdateTexture(texture, nil, raw_data(c.pixels), i32(c.w * 4))
		sdl.RenderTexture(renderer, texture, nil, nil)
		sdl.RenderPresent(renderer)
		return
	}
	dst := sdl.GetWindowSurface(window)
	src := sdl.CreateSurfaceFrom(i32(c.w), i32(c.h), .XRGB8888, raw_data(c.pixels), i32(c.w * 4))
	sdl.BlitSurface(src, nil, dst, nil)
	sdl.DestroySurface(src)
	sdl.UpdateWindowSurface(window)
}

pump :: proc() -> (quit: bool) {
	ev: sdl.Event
	for sdl.PollEvent(&ev) {
		if ev.type == .QUIT do quit = true
	}
	return
}

main :: proc() {
	bench.mark("main")
	args := bench.parse_args()
	gpu := false
	for a in os.args do if a == "--gpu" do gpu = true

	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("SDL_Init:", sdl.GetError())
		os.exit(1)
	}
	bench.mark("sdl_init")

	window = sdl.CreateWindow("platform bench (SDL3)", bench.WINDOW_W, bench.WINDOW_H, sdl.WINDOW_HIGH_PIXEL_DENSITY | sdl.WINDOW_RESIZABLE)
	if window == nil {
		fmt.eprintln("SDL_CreateWindow:", sdl.GetError())
		os.exit(1)
	}
	if gpu {
		renderer = sdl.CreateRenderer(window, nil)
		bench.info("renderer", sdl.GetRendererName(renderer))
	}
	w, h: i32
	sdl.GetWindowSizeInPixels(window, &w, &h)
	if gpu {
		texture = sdl.CreateTexture(renderer, .XRGB8888, .STREAMING, w, h)
	}
	bench.info("video_driver", sdl.GetCurrentVideoDriver())
	pump()
	bench.mark("window")

	scale := f32(w) / bench.WINDOW_W
	font, ok := bench.font_load(15 * scale)
	if !ok do os.exit(1)
	canvas := bench.canvas_make(int(w), int(h))
	bench.mark("font")

	bench.draw_text_screen(&canvas, &font, transmute([]u8)string(bench.SPLASH))
	present(&canvas)
	bench.mark("first_frame")

	if args.file != "" {
		bench.mark("load_start")
		data := bench.load_file(args.file)
		bench.mark("file_read")
		bench.draw_text_screen(&canvas, &font, data)
		present(&canvas)
		bench.mark("file_frame")
		bench.info("lines", bench.count_lines(data))
		bench.mark("line_index")
	}

	ev: sdl.Event
	for args.stay {
		if sdl.WaitEvent(&ev) && ev.type == .QUIT do break
	}
	sdl.Quit()
}
