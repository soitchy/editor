// Native macOS spike: NSWindow + CAMetalLayer. The CPU canvas is copied
// straight into the drawable's texture (no shaders, no pipeline), so this
// measures AppKit + Metal device/layer setup and one present.
package native_macos

import "core:os"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"
import bench "../common"

device: ^MTL.Device
queue: ^MTL.CommandQueue
layer: ^CA.MetalLayer

present :: proc(c: ^bench.Canvas) {
	drawable := layer->nextDrawable()
	tex := drawable->texture()
	region := MTL.Region{origin = {0, 0, 0}, size = {NS.Integer(c.w), NS.Integer(c.h), 1}}
	tex->replaceRegionWithLevel(region, 0, 0, raw_data(c.pixels), NS.UInteger(c.w * 4), 0)
	cb := queue->commandBuffer()
	cb->presentDrawable(drawable)
	cb->commit()
	cb->waitUntilCompleted()
}

pump :: proc(app: ^NS.Application) {
	for {
		ev := app->nextEventMatchingMask(NS.EventMaskAny, nil, NS.DefaultRunLoopMode, true)
		if ev == nil do break
		app->sendEvent(ev)
	}
}

main :: proc() {
	bench.mark("main")
	args := bench.parse_args()

	app := NS.Application.sharedApplication()
	app->setActivationPolicy(.Regular)
	app->finishLaunching()
	bench.mark("app")

	rect := NS.Rect{{100, 100}, {bench.WINDOW_W, bench.WINDOW_H}}
	window := NS.Window.alloc()->initWithContentRect(rect, NS.WindowStyleMaskTitled | NS.WindowStyleMaskClosable | NS.WindowStyleMaskResizable, .Buffered, false)
	scale := window->backingScaleFactor()
	bench.mark("nswindow")

	device = MTL.CreateSystemDefaultDevice()
	queue = device->newCommandQueue()
	bench.mark("metal")
	layer = CA.MetalLayer.layer()
	layer->setDevice(device)
	layer->setPixelFormat(.BGRA8Unorm)
	layer->setFramebufferOnly(false) // allow replaceRegion on the drawable
	w, h := int(bench.WINDOW_W * scale), int(bench.WINDOW_H * scale)
	layer->setDrawableSize({NS.Float(w), NS.Float(h)})

	view := window->contentView()
	view->setWantsLayer(true)
	view->setLayer(layer)
	window->makeKeyAndOrderFront(nil)
	bench.mark("order_front")
	app->activate()
	pump(app)
	bench.mark("window")

	font, ok := bench.font_load(15 * f32(scale))
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

	for args.stay { // quit with Ctrl-C
		ev := app->nextEventMatchingMask(NS.EventMaskAny, NS.Date.distantFuture(), NS.DefaultRunLoopMode, true)
		if ev != nil do app->sendEvent(ev)
	}
}
