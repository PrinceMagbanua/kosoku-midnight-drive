shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Procedural weathered concrete for the roadside barrier walls - sibling to
// road_surface.gdshader, same no-texture-asset approach. UV.x is the
// continuous distance-along-road value (see road_generator.gd's
// _build_fence) so the pattern is seamless across streamed chunks; UV.y is
// height above the ground, both in world units.
uniform vec3 base_color : source_color = vec3(0.56, 0.56, 0.54);
// Precast barriers come in separate slabs - thin dark joint every panel_length,
// and each slab gets its own slight random tint so the wall isn't uniform.
uniform float panel_length : hint_range(2.0, 60.0) = 13.0;
uniform float panel_tint_variation : hint_range(0.0, 0.3) = 0.08;
uniform float joint_darkness : hint_range(0.0, 1.0) = 0.55;
// Large soft blotches (water stains, patchy weathering).
uniform float stain_scale : hint_range(0.01, 1.0) = 0.12;
uniform float stain_strength : hint_range(0.0, 0.5) = 0.14;
// Fine pores/speckle of the concrete aggregate.
uniform float speckle_scale : hint_range(1.0, 60.0) = 18.0;
uniform float speckle_strength : hint_range(0.0, 0.5) = 0.12;
// Road grime splashed up the bottom of the wall.
uniform float grime_height : hint_range(0.0, 4.0) = 1.4;
uniform float grime_darkness : hint_range(0.0, 1.0) = 0.4;
// Hairline cracks + chips.
uniform float crack_scale : hint_range(0.05, 2.0) = 0.5;
uniform float crack_darkness : hint_range(0.0, 1.0) = 0.3;

varying vec2 v_uv;

void vertex() {
	v_uv = UV;
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	return value_noise(p) * 0.55 + value_noise(p * 2.1 + 3.7) * 0.3 + value_noise(p * 4.3 + 9.1) * 0.15;
}

float cell_edge_noise(vec2 p) {
	vec2 base_cell = floor(p);
	float min_dist = 1.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 neighbor = vec2(float(x), float(y));
			vec2 jitter = vec2(hash21(base_cell + neighbor), hash21(base_cell + neighbor + vec2(7.3, 2.1)));
			vec2 point_pos = neighbor + jitter - fract(p);
			min_dist = min(min_dist, length(point_pos));
		}
	}
	return min_dist;
}

void fragment() {
	float along = v_uv.x;
	float h = v_uv.y;

	float panel = floor(along / panel_length);
	float panel_tint = (hash21(vec2(panel, 17.0)) - 0.5) * panel_tint_variation;
	float in_panel = fract(along / panel_length) * panel_length;
	float joint = 1.0 - smoothstep(0.03, 0.12, min(in_panel, panel_length - in_panel));

	float stains = (fbm(vec2(along, h * 2.0) * stain_scale) - 0.5) * stain_strength;
	float speckle = (value_noise(vec2(along, h) * speckle_scale) - 0.5) * speckle_strength;
	float grime_noise = fbm(vec2(along * 0.4, h * 1.5));
	float grime = (1.0 - smoothstep(0.0, grime_height * (0.6 + grime_noise * 0.8), h)) * grime_darkness;
	float cracks = (1.0 - smoothstep(0.0, 0.04, cell_edge_noise(vec2(along, h * 1.6) * crack_scale)))
		* step(0.55, value_noise(vec2(along, h) * 0.2)); // only in some patches, not a full web

	vec3 col = base_color + panel_tint + stains + speckle;
	col *= 1.0 - grime;
	col *= 1.0 - cracks * crack_darkness;
	col *= 1.0 - joint * joint_darkness;

	ALBEDO = clamp(col, vec3(0.0), vec3(1.0));
	ROUGHNESS = clamp(0.9 + speckle * 0.5, 0.0, 1.0);
	AO = clamp(1.0 - joint * 0.6 - cracks * 0.4 - grime * 0.3, 0.0, 1.0);
	AO_LIGHT_AFFECT = 0.5;
}
