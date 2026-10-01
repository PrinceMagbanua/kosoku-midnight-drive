shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Drifting smoke/haze puffs on the road ahead (road_haze.gd). Billboarded
// here in the vertex shader so the script only touches a puff's transform
// when it recycles it - no per-frame CPU work per puff. Fades out both far
// away (no pop-in when a puff is recycled to the far end) and up close (a
// huge quad filling the screen is the only real cost - overdraw - so it's
// already gone by the time the car drives through it).
uniform sampler2D puff_texture : source_color, hint_default_white, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.55, 0.58, 0.65, 1.0);
uniform float opacity : hint_range(0.0, 1.0) = 0.1;
uniform float near_fade_start = 6.0;
uniform float near_fade_end = 40.0;
uniform float far_fade_start = 300.0;
uniform float far_fade_end = 450.0;

varying float v_fade;

void vertex() {
	float s = length(MODEL_MATRIX[0].xyz);
	float seed = float(INSTANCE_ID) * 1.713;
	float t = TIME * 0.06 + seed;
	vec3 center = MODEL_MATRIX[3].xyz + vec3(sin(t), sin(t * 0.7) * 0.2, cos(t * 0.8)) * s * 0.12;

	float a = seed * 2.4 + TIME * 0.03 * (mod(seed, 2.0) - 1.0);
	VERTEX.xy = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * VERTEX.xy;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(INV_VIEW_MATRIX[0].xyz * s, 0.0),
		vec4(INV_VIEW_MATRIX[1].xyz * s, 0.0),
		vec4(INV_VIEW_MATRIX[2].xyz * s, 0.0),
		vec4(center, 1.0));

	float d = distance(center, CAMERA_POSITION_WORLD);
	v_fade = smoothstep(near_fade_start, near_fade_end, d) * (1.0 - smoothstep(far_fade_start, far_fade_end, d));
}

void fragment() {
	ALBEDO = tint.rgb;
	ALPHA = texture(puff_texture, UV).a * opacity * v_fade;
}
