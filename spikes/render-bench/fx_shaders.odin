// PROTOTYPE shared bits for the shader-effect modes: a cursor-trail uniform
// block, the path the fake cursor follows, and the MSL source.
package render_bench

import "core:math"
import "core:time"

TRAIL_N :: 8

// Matches `struct U` in the MSL below: float2 + float + int is 16 bytes, then float4[8].
Trail_Uniforms :: struct {
	res:  [2]f32,
	time: f32,
	n:    i32,
	pts:  [TRAIL_N][4]f32,
}

// Moves a fake cursor on a Lissajous path and keeps the last TRAIL_N positions,
// one sample every 2 frames, newest first.
trail_update :: proc(u: ^Trail_Uniforms, frame: int, w, h: f32) {
	t := f32(frame) / 120
	if frame % 2 == 0 {
		copy(u.pts[1:], u.pts[:TRAIL_N - 1])
		u.pts[0] = {w * 0.5 + w * 0.3 * math.sin(t * 1.9), h * 0.5 + h * 0.25 * math.sin(t * 2.7 + 1), 0, 0}
		u.n = min(u.n + 1, TRAIL_N)
	}
	u.res = {w, h}
	u.time = t
}

// Distance from p to the segment a-b, then an exponential glow along the whole trail.
MSL_TRAIL_FN :: `
struct U { float2 res; float time; int n; float4 pts[8]; };

float seg(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h);
}

float3 trail(constant U& u, float2 p) {
    float glow = 0.0;
    for (int i = 0; i + 1 < u.n; i++) {
        float d = seg(p, u.pts[i].xy, u.pts[i + 1].xy);
        glow += (1.0 - float(i) / float(u.n)) * exp(-d / 14.0);
    }
    return float3(0.54, 0.71, 0.98) * glow * 0.8;
}
`

// Fragment shader for SDL_Renderer's GPU render state: SDL feeds it colour+uv and
// binds the texture being drawn at texture(0).
MSL_RENDERER_FX :: `#include <metal_stdlib>
using namespace metal;
` + MSL_TRAIL_FN + `
struct In { float4 color [[user(locn0)]]; float2 uv [[user(locn1)]]; };

fragment float4 main0(In in [[stage_in]], constant U& u [[buffer(0)]],
                      texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
    float4 base = tex.sample(smp, in.uv) * in.color;
    return float4(base.rgb + trail(u, in.uv * u.res), 1.0);
}
`

// Everything the raw SDL_GPU path needs: text quads, then a fullscreen trail pass.
MSL_GPU_FX :: `#include <metal_stdlib>
using namespace metal;
` + MSL_TRAIL_FN + `
struct VIn  { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
struct VOut { float4 pos [[position]]; float2 uv; };
struct VU   { float2 res; };

vertex VOut vtext(VIn in [[stage_in]], constant VU& vu [[buffer(0)]]) {
    VOut o;
    o.pos = float4(in.pos.x / vu.res.x * 2.0 - 1.0, 1.0 - in.pos.y / vu.res.y * 2.0, 0.0, 1.0);
    o.uv = in.uv;
    return o;
}

fragment float4 ftext(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler smp [[sampler(0)]]) {
    float a = atlas.sample(smp, in.uv).r;
    return float4(0.804, 0.839, 0.957, a);
}

struct FOut { float4 pos [[position]]; };

vertex FOut vfull(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

fragment float4 ftrail(FOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    return float4(trail(u, in.pos.xy), 1.0);
}
`

// Calls `step` once per frame and prints fps and CPU use. `step` does build + present.
measure :: proc(label: string, frames: int, user: rawptr, step: proc(frame: int, user: rawptr)) {
	cpu0 := cpu_seconds()
	t0 := time.now()
	times := make([]f64, frames)
	for f in 0 ..< frames {
		a := time.now()
		step(f, user)
		times[f] = ms(time.diff(a, time.now()))
	}
	wall := time.duration_seconds(time.since(t0))
	cpu := cpu_seconds() - cpu0
	println_summary(label, frames, wall, cpu, times)
}
