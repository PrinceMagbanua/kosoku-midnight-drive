shader_type canvas_item;

// Film grain for the MENU/GARAGE showcase (MenuShowcase.tscn > GrainRect).
// Same grain as speed_blur.gdshader's (keep the two in step) - that pass sits
// at canvas layer -10 under the showcase, so the showcase needs its own.
// Drawn after the preview SubViewportContainer on the same layer, so it grains
// the 3D preview but not the menu/garage UI on the layers above it.
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_nearest;

// grain_amount: overall strength (0 = off).
uniform float grain_amount : hint_range(0.0, 0.3) = 0.06;
// grain_size: size of one grain speck in screen pixels.
uniform float grain_size : hint_range(1.0, 4.0) = 1.5;
// grain_fps: how often the grain pattern changes.
uniform float grain_fps : hint_range(1.0, 60.0) = 24.0;

float grain_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec3 col = texture(screen_tex, SCREEN_UV).rgb;
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	float frame = floor(TIME * grain_fps);
	vec2 cell = floor(FRAGCOORD.xy / grain_size);
	float n = grain_hash(cell + frame * vec2(17.13, 41.71)) - 0.5;
	col += n * grain_amount * (1.0 - 0.7 * luma);
	COLOR = vec4(col, 1.0);
}
