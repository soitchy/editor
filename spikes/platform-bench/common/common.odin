// Shared by every platform spike so the only thing that differs between them is
// the window/present path. Text is rasterised on the CPU with stb_truetype into a
// BGRA canvas; each spike just gets those pixels on screen.
package bench_common

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import stbtt "vendor:stb/truetype"

// 0xAARRGGBB, which is B,G,R,A in memory on little-endian: matches Metal
// BGRA8Unorm, a 32bpp Win32 DIB, and SDL XRGB8888.
BG :: u32(0xFF1E1E2E)
FG :: u32(0xFFCDD6F4)

WINDOW_W :: 1280 // logical points
WINDOW_H :: 800

Canvas :: struct {
	pixels: []u32,
	w, h:   int,
}

FIRST_CHAR :: 32
NUM_CHARS :: 96

Font :: struct {
	chars:      [NUM_CHARS]stbtt.bakedchar,
	atlas:      []u8,
	atlas_w:    int,
	atlas_h:    int,
	line_h:     f32,
	ascent:     f32,
}

Args :: struct {
	file: string, // load and show this after the first frame
	stay: bool,   // keep the window open instead of exiting
}

parse_args :: proc() -> (a: Args) {
	for i := 1; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--file": if i + 1 < len(os.args) { i += 1; a.file = os.args[i] }
		case "--stay": a.stay = true
		}
	}
	return
}

// Prints `MARK <label> <unix_ns>` so the harness, which records wall-clock time
// just before spawning, can work out time-since-spawn for each stage.
mark :: proc(label: string) {
	fmt.printfln("MARK %s %d", label, time.to_unix_nanoseconds(time.now()))
}

// Writes `INFO <key> <value>` for facts the harness reports but does not time.
info :: proc(key: string, value: any) {
	fmt.printfln("INFO %s %v", key, value)
}

default_font_path :: proc() -> (path: string, index: int) {
	when ODIN_OS == .Darwin {
		return "/System/Library/Fonts/Menlo.ttc", 0
	} else when ODIN_OS == .Windows {
		return "C:\\Windows\\Fonts\\consola.ttf", 0
	} else {
		return "/usr/share/fonts/TTF/DejaVuSansMono.ttf", 0
	}
}

// Loads the system monospace font and bakes printable ASCII at `px` pixels.
// Counted as part of startup: the real editor has to do this before frame one.
font_load :: proc(px: f32) -> (f: Font, ok: bool) {
	path, index := default_font_path()
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("font: cannot read %s: %v", path, err)
		return
	}
	offset := stbtt.GetFontOffsetForIndex(raw_data(data), i32(index))

	info: stbtt.fontinfo
	if !stbtt.InitFont(&info, raw_data(data), offset) do return
	ascent, descent, gap: i32
	stbtt.GetFontVMetrics(&info, &ascent, &descent, &gap)
	scale := stbtt.ScaleForPixelHeight(&info, px)
	f.ascent = f32(ascent) * scale
	f.line_h = f32(ascent - descent + gap) * scale

	f.atlas_w, f.atlas_h = 1024, 1024
	f.atlas = make([]u8, f.atlas_w * f.atlas_h)
	res := stbtt.BakeFontBitmap(raw_data(data), offset, px, raw_data(f.atlas), i32(f.atlas_w), i32(f.atlas_h), FIRST_CHAR, NUM_CHARS, &f.chars[0])
	return f, res != 0
}

canvas_make :: proc(w, h: int) -> Canvas {
	return Canvas{pixels = make([]u32, w * h), w = w, h = h}
}

canvas_clear :: proc(c: ^Canvas) {
	for &p in c.pixels do p = BG
}

blend :: #force_inline proc(dst: u32, cov: u8) -> u32 {
	a := u32(cov)
	ia := 255 - a
	r := (((FG >> 16) & 0xFF) * a + ((dst >> 16) & 0xFF) * ia) / 255
	g := (((FG >> 8) & 0xFF) * a + ((dst >> 8) & 0xFF) * ia) / 255
	b := ((FG & 0xFF) * a + (dst & 0xFF) * ia) / 255
	return 0xFF000000 | r << 16 | g << 8 | b
}

// Draws one line starting at pixel (x, baseline). Non-ASCII bytes and tabs draw
// as a space-width gap; good enough for a timing spike.
draw_line :: proc(c: ^Canvas, f: ^Font, x: f32, baseline: f32, text: []u8) {
	pen := x
	for ch in text {
		if pen >= f32(c.w) do break
		code := int(ch)
		if code < FIRST_CHAR || code >= FIRST_CHAR + NUM_CHARS do code = ' '
		bc := &f.chars[code - FIRST_CHAR]
		gx := int(pen + bc.xoff)
		gy := int(baseline + bc.yoff)
		for yy in 0 ..< int(bc.y1) - int(bc.y0) {
			py := gy + yy
			if py < 0 || py >= c.h do continue
			src := f.atlas[(int(bc.y0) + yy) * f.atlas_w + int(bc.x0):]
			for xx in 0 ..< int(bc.x1) - int(bc.x0) {
				px := gx + xx
				if px < 0 || px >= c.w do continue
				cov := src[xx]
				if cov == 0 do continue
				dst := &c.pixels[py * c.w + px]
				dst^ = blend(dst^, cov)
			}
		}
		pen += bc.xadvance
	}
}

// Fills the canvas with as many lines of `text` as fit, from the top.
draw_text_screen :: proc(c: ^Canvas, f: ^Font, text: []u8) {
	canvas_clear(c)
	baseline := f.ascent + 8
	start := 0
	for start < len(text) && baseline < f32(c.h) {
		end := start
		for end < len(text) && text[end] != '\n' do end += 1
		draw_line(c, f, 8, baseline, text[start:end])
		baseline += f.line_h
		start = end + 1
	}
}

SPLASH :: `Platform bench: first frame with text.
The quick brown fox jumps over the lazy dog. 0123456789 ()[]{}<>=+-*/
Selection first. Multicursor. Keyboard driven.`

// Opens the file and shows its first screen. Returns the whole contents so
// the caller can time indexing too. Read in full here because that is what a
// piece table's original buffer needs; the editor itself may stream instead.
load_file :: proc(path: string) -> []u8 {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("load: cannot read %s: %v", path, err)
		return nil
	}
	return data
}

// Counts lines across the whole file: a stand-in for building a line index,
// reported separately so it can be weighed against "first screen" time.
count_lines :: proc(data: []u8) -> int {
	return strings.count(string(data), "\n")
}
