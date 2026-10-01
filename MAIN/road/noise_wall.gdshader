shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Tall grey sound-barrier panels (RoadBarriers NOISE_WALL). UV = (distance
// along road, height), world units (~3.27 per metre) - seamless across
// chunks. Horizontal pressed ribs (shaded via the normal, no extra geometry),
// a vertical joint at every post, and a little grime and per-panel tint.
uniform vec3 base_color : source_color = vec3(0.58, 0.60, 0.62);
uniform float rib_spacing : hint_range(0.2, 4.0) = 1.6; // world units
uniform float rib_depth : hint_range(0.0, 1.0) = 0.55;
uniform float panel_length = 13.0; // set from RoadBarriers (post spacing)
uniform float panel_tint_variation : hint_range(0.0, 0.3) = 0.06;
uniform float joint_darkness : hint_range(0.0, 1.0) = 0.5;
uniform float grime_strength : hint_range(0.0, 1.0) = 0.25;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

void fragment() {
	float along = UV.x;
	float h = UV.y;
	// Rib profile: a rounded bump every rib_spacing; its slope tilts the normal.
	float r = fract(h / rib_spacing);
	float slope = cos(r * 6.28318);
	float px = fwidth(h / rib_spacing);
	float rib_fade = 1.0 - smoothstep(0.3, 0.8, px); // flatten once ribs are sub-pixel
	NORMAL_MAP = normalize(vec3(0.5, 0.5 + slope * rib_depth * 0.5 * rib_fade, 1.0));

	float panel = floor(along / panel_length);
	float in_panel = fract(along / panel_length) * panel_length;
	float joint = 1.0 - smoothstep(0.02, 0.1, min(in_panel, panel_length - in_panel));
	float tint = (hash21(vec2(panel, 3.0)) - 0.5) * panel_tint_variation;
	float grime = (1.0 - smoothstep(0.0, 4.0, h)) * grime_strength * (0.6 + value_noise(vec2(along * 0.3, h)) * 0.8);
	vec3 col = base_color + tint;
	col *= 1.0 - grime;
	col *= 1.0 - joint * joint_darkness;
	ALBEDO = clamp(col, vec3(0.0), vec3(1.0));
	METALLIC = 0.35;
	ROUGHNESS = 0.55;
}
