shader_type canvas_item;

// Radial/zoom speed blur - Godot 4's newer Compositor/CompositorEffect
// full-screen post system doesn't work under this project's gl_compatibility
// renderer, so this uses the older canvas_item + hint_screen_texture
// approach instead (a full-screen ColorRect reading the backbuffer).
// Also doubles as the crash desaturation pass (`saturation`), since it's
// already the one full-screen rect sampling the 3D world under the UI.
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float saturation : hint_range(0.0, 1.0) = 1.0;
// Camera shake (camera_shake.gd, through speed_blur.gd's set_shake): the whole
// 3D image is shifted by `shake`, in fractions of the screen HEIGHT on both
// axes, so the car and the world move together like a shaken camera (moving
// the Camera3D itself shifts near things more than far ones, which reads as
// the car vibrating). `shake_margin` is the largest shift possible right now -
// the image is zoomed in by that much so the edges never pull in pixels from
// off screen.
uniform vec2 shake = vec2(0.0);
uniform float shake_margin = 0.0;

// Tunables (inspector: SpeedBlur.tscn > Rect > Material).
// Distance below is measured in "screen-shaped" units: 0 at the centre,
// 1 at the middle of every screen edge, ~1.41 in the corners - so the
// clear zone is an ellipse matching the screen and the blur peaks at the
// edges on all four sides, not just left/right.
// max_zoom: streak length at the screen edge at full intensity.
uniform float max_zoom : hint_range(0.0, 0.4) = 0.12;
// clear_radius: inside this the image stays perfectly sharp.
uniform float clear_radius : hint_range(0.0, 1.0) = 0.3;
// falloff: 1 = blur grows evenly toward the edges, 2-3 = stays gentle
// longer then gets extreme near the edges.
uniform float falloff : hint_range(0.5, 4.0) = 1.0;
// tunnel_shrink: how much the clear zone tightens at full intensity
// (0 = fixed size, 0.5 = half the radius at top speed / nitro).
uniform float tunnel_shrink : hint_range(0.0, 1.0) = 0.35;

// Film grain - always on (not tied to speed), applied last so it also sits
// on top of the crash black-and-white. Monochrome, strongest in the darks
// and midtones and faded out in bright areas, like real film stock.
// grain_amount: overall strength (0 = off).
uniform float grain_amount : hint_range(0.0, 0.3) = 0.06;
// grain_size: size of one grain speck in screen pixels.
uniform float grain_size : hint_range(1.0, 4.0) = 1.5;
// grain_fps: how often the grain pattern changes - ~24 feels filmic,
// higher looks more like fine video noise.
uniform float grain_fps : hint_range(1.0, 60.0) = 24.0;

const int SAMPLES = 14;

float grain_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec2 center = vec2(0.5, 0.5);
	vec2 dir = SCREEN_UV - center;

	float r = length(dir / 0.5);
	float clear = clear_radius * (1.0 - tunnel_shrink * intensity);
	float m = pow(max(r - clear, 0.0) / max(1.0 - clear, 0.001), falloff);
	float zoom = intensity * max_zoom * m;

	// Per-pixel jitter (interleaved gradient noise) spreads the samples so
	// long streaks read as smooth motion instead of stepped ghost copies.
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	// Shake: same pixel distance on both axes (x is scaled by height / width).
	vec2 shake_uv = shake * vec2(SCREEN_PIXEL_SIZE.x / SCREEN_PIXEL_SIZE.y, 1.0);
	float keep = 1.0 - 2.0 * shake_margin;
	vec4 sum = vec4(0.0);
	for (int i = 0; i < SAMPLES; i++) {
		float t = (float(i) + jitter) / float(SAMPLES);
		sum += texture(screen_tex, center + shake_uv + dir * keep * (1.0 - zoom * t));
	}
	vec3 col = sum.rgb / float(SAMPLES);
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(luma), col, saturation);

	float frame = floor(TIME * grain_fps);
	vec2 cell = floor(FRAGCOORD.xy / grain_size);
	float n = grain_hash(cell + frame * vec2(17.13, 41.71)) - 0.5;
	col += n * grain_amount * (1.0 - 0.7 * luma);

	COLOR = vec4(col, 1.0);
}
