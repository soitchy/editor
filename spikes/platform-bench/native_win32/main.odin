// Native Win32 spike. Two present paths for the same CPU canvas:
//   default:  GDI, StretchDIBits into the window DC, then DwmFlush
//   --gpu:    D3D11 + DXGI flip swapchain, canvas copied into the back buffer
//             with UpdateSubresource (no shaders), mirroring the macOS spike.
package native_win32

import "base:runtime"
import "core:os"
import win "core:sys/windows"
import d3d "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"
import bench "../common"

hwnd: win.HWND
quit: bool

swapchain: ^dxgi.ISwapChain
device: ^d3d.IDevice
ctx: ^d3d.IDeviceContext
backbuffer: ^d3d.ITexture2D

wnd_proc :: proc "system" (h: win.HWND, msg: win.UINT, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT {
	switch msg {
	case win.WM_DESTROY:
		quit = true
		win.PostQuitMessage(0)
		return 0
	}
	return win.DefWindowProcW(h, msg, wp, lp)
}

gpu_init :: proc(w, h: int) -> bool {
	desc := dxgi.SWAP_CHAIN_DESC{
		BufferDesc   = {Width = u32(w), Height = u32(h), Format = .B8G8R8A8_UNORM},
		SampleDesc   = {Count = 1},
		BufferUsage  = {.RENDER_TARGET_OUTPUT},
		BufferCount  = 2,
		OutputWindow = hwnd,
		Windowed     = true,
		SwapEffect   = .FLIP_DISCARD,
	}
	levels := [1]d3d.FEATURE_LEVEL{._11_0}
	hr := d3d.CreateDeviceAndSwapChain(nil, .HARDWARE, nil, {.BGRA_SUPPORT}, &levels[0], 1, d3d.SDK_VERSION, &desc, &swapchain, &device, nil, &ctx)
	if hr != 0 do return false
	hr = swapchain->GetBuffer(0, d3d.ITexture2D_UUID, (^rawptr)(&backbuffer))
	return hr == 0
}

present :: proc(c: ^bench.Canvas) {
	if swapchain != nil {
		// FLIP_DISCARD leaves buffer 0 as the current back buffer after each Present.
		ctx->UpdateSubresource(backbuffer, 0, nil, raw_data(c.pixels), u32(c.w * 4), 0)
		swapchain->Present(0, {})
	} else {
		bmi := win.BITMAPINFO{
			bmiHeader = {
				biSize        = size_of(win.BITMAPINFOHEADER),
				biWidth       = i32(c.w),
				biHeight      = -i32(c.h), // top-down
				biPlanes      = 1,
				biBitCount    = 32,
				biCompression = win.BI_RGB,
			},
		}
		dc := win.GetDC(hwnd)
		win.StretchDIBits(dc, 0, 0, i32(c.w), i32(c.h), 0, 0, i32(c.w), i32(c.h), raw_data(c.pixels), &bmi, win.DIB_RGB_COLORS, win.SRCCOPY)
		win.ReleaseDC(hwnd, dc)
	}
	// Block until the compositor has picked the frame up: the closest cheap
	// stand-in for "visible" on both paths.
	win.DwmFlush()
}

pump :: proc() {
	msg: win.MSG
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}

main :: proc() {
	bench.mark("main")
	args := bench.parse_args()
	gpu := false
	for a in os.args do if a == "--gpu" do gpu = true

	win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	class_name: win.LPCWSTR = "platform_bench"
	wc := win.WNDCLASSEXW{
		cbSize        = size_of(win.WNDCLASSEXW),
		style         = win.CS_OWNDC,
		lpfnWndProc   = wnd_proc,
		hInstance     = instance,
		lpszClassName = class_name,
	}
	win.RegisterClassExW(&wc)

	style := win.WS_OVERLAPPEDWINDOW
	hwnd = win.CreateWindowExW(0, class_name, "platform bench (Win32)", style, win.CW_USEDEFAULT, win.CW_USEDEFAULT, bench.WINDOW_W, bench.WINDOW_H, nil, nil, instance, nil)
	// Resize so the client area is WINDOW_W x WINDOW_H logical pixels at this DPI.
	dpi := win.GetDpiForWindow(hwnd)
	scale := f32(dpi) / 96
	r := win.RECT{0, 0, i32(bench.WINDOW_W * scale), i32(bench.WINDOW_H * scale)}
	win.AdjustWindowRectExForDpi(&r, style, false, 0, dpi)
	win.SetWindowPos(hwnd, nil, 0, 0, r.right - r.left, r.bottom - r.top, win.SWP_NOMOVE | win.SWP_NOZORDER)
	win.ShowWindow(hwnd, win.SW_SHOW)

	client: win.RECT
	win.GetClientRect(hwnd, &client)
	w, h := int(client.right), int(client.bottom)
	if gpu && !gpu_init(w, h) {
		runtime.print_string("D3D11 init failed\n")
		os.exit(1)
	}
	bench.info("present", "d3d11" if gpu else "gdi")
	pump()
	bench.mark("window")

	font, ok := bench.font_load(15 * scale)
	if !ok do os.exit(1)
	canvas := bench.canvas_make(w, h)
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

	msg: win.MSG
	for args.stay && !quit && win.GetMessageW(&msg, nil, 0, 0) > 0 {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}
