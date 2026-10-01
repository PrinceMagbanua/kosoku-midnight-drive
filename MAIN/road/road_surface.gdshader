shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Adds procedural cracks, streaks, and gravel speckle on top of the road
// ribbon's existing per-vertex color (lane/shoulder/grass/sidewalk), with no
// texture assets. UV.x is the continuous distance-along-road value (see
// road_generator.gd's _build_ribbon_mesh) - not 0-1 - so all noise below is
// seamless across streamed chunks. UV.y is the raw signed lateral world
// offset, compared against these two to know which band a fragment is in.
uniform float road_half_width;
uniform float shoulder_half_width;
// The sidewalk strip sits between these two - it keeps its plain look.
uniform float grass_half_width;
uniform float sidewalk_half_width;

uniform float crack_scale : hint_range(0.05, 2.0) = 0.35;
uniform float crack_darkness : hint_range(0.0, 1.0) = 0.35;
uniform float streak_scale : hint_range(0.001, 0.2) = 0.02;
uniform float streak_strength : hint_range(0.0, 1.0) = 0.18;
uniform float gravel_scale : hint_range(1.0, 40.0) = 9.0;
uniform float gravel_strength : hint_range(0.0, 1.0) = 0.5;

// Off-road ground (barrier outward, minus the sidewalk). COLOR.a is the urban
// amount from road_generator.gd (0 = forest grass, 1 = city concrete).
// UV is in world units (~3.27 per metre).
// Grass: big lighter/darker/drier patches + fine blade speckle.
uniform float grass_patch_scale : hint_range(0.005, 0.5) = 0.04;
uniform float grass_patch_strength : hint_range(0.0, 1.0) = 0.35;
uniform vec3 grass_dry_color : source_color = vec3(0.30, 0.30, 0.13);
uniform float grass_dry_amount : hint_range(0.0, 1.0) = 0.35;
uniform float grass_blade_scale : hint_range(0.5, 20.0) = 4.0;
uniform float grass_blade_strength : hint_range(0.0, 0.5) = 0.08;
// City: dirty concrete lot - stains, grit, slab joints, patchy cracks.
uniform float urban_stain_scale : hint_range(0.005, 0.5) = 0.06;
uniform float urban_stain_strength : hint_range(0.0, 0.5) = 0.07;
uniform float urban_grit_scale : hint_range(0.5, 30.0) = 7.0;
uniform float urban_grit_strength : hint_range(0.0, 0.5) = 0.06;
uniform float urban_slab_size : hint_range(2.0, 40.0) = 10.0;
uniform float urban_joint_darkness : hint_range(0.0, 1.0) = 0.35;
uniform float urban_slab_tint_variation : hint_range(0.0, 0.2) = 0.03;
uniform float urban_crack_scale : hint_range(0.05, 2.0) = 0.25;
uniform float urban_crack_darkness : hint_range(0.0, 1.0) = 0.3;

// Lane closure paint (RoadLayout): UV2 = (lane edge, hatch edge) as signed
// laterals. Between the two - the closing lane's area - gets diagonal white
// hatching, with a solid edge line along the lane edge.
uniform vec3 paint_color : source_color = vec3(0.85, 0.85, 0.8);
uniform float hatch_period : hint_range(1.0, 40.0) = 9.0; // world units between stripes
uniform float hatch_fill : hint_range(0.0, 1.0) = 0.35;
uniform float edge_line_width = 0.5;

// Inside tunnels (the tunnel-lit copy of this material, see RoadGenerator):
// fake sodium lighting added as emission so the road reads lit by the lamp
// rows without hundreds of real lights. 0 everywhere else.
uniform float tunnel_glow = 0.0;
uniform vec3 tunnel_light_color : source_color = vec3(1.0, 0.6, 0.25);
uniform float lamp_spacing = 13.0;

varying vec2 v_uv;
varying vec2 v_hatch;

void vertex() {
	v_uv = UV;
	v_hatch = UV2;
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

// Worley/cell noise - distance to the nearest jittered cell point. Cracks are
// where that distance is small, i.e. right at a cell edge.
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
	float abs_y = abs(v_uv.y);
	// 1 on paved road+shoulder, fading to 0 by the grass band - avoids a hard
	// seam and means cracks/streaks never appear on grass/sidewalk.
	float paved = 1.0 - smoothstep(shoulder_half_width - 0.15, shoulder_half_width + 0.15, abs_y);
	// Gravel is concentrated on the shoulder strip specifically (between the
	// road edge and the shoulder's outer edge), not the travel lanes.
	float on_shoulder = smoothstep(road_half_width - 0.1, road_half_width + 0.3, abs_y) * paved;

	float cracks = 1.0 - smoothstep(0.0, 0.06, cell_edge_noise(v_uv * crack_scale));
	float crack_amount = cracks * crack_darkness * paved;

	// Stretched heavily along the travel direction (UV.x) so noise reads as
	// tire streaks rather than blobs.
	float streaks = value_noise(vec2(v_uv.x * streak_scale, v_uv.y * streak_scale * 12.0));
	float streak_amount = (streaks - 0.5) * streak_strength * paved;

	float gravel = value_noise(v_uv * gravel_scale);
	float gravel_amount = (gravel - 0.5) * gravel_strength * on_shoulder;

	vec3 base = COLOR.rgb;
	base *= 1.0 - crack_amount;
	base += streak_amount;
	base += gravel_amount * 0.5;

	// --- off-road ground --------------------------------------------------
	float on_sidewalk = smoothstep(grass_half_width - 0.2, grass_half_width + 0.2, abs_y)
		* (1.0 - smoothstep(sidewalk_half_width - 0.2, sidewalk_half_width + 0.2, abs_y));
	float ground = (1.0 - paved) * (1.0 - on_sidewalk);
	float urban = COLOR.a;
	// Fine detail fades out where it would be smaller than a pixel (the
	// terrain runs hundreds of metres out) so it doesn't shimmer.
	float px = length(fwidth(v_uv));
	float blade_fade = 1.0 - smoothstep(0.3, 1.0, px * grass_blade_scale);
	float grit_fade = 1.0 - smoothstep(0.3, 1.0, px * urban_grit_scale);
	float joint_fade = 1.0 - smoothstep(0.02, 0.1, px / urban_slab_size);

	// Grass.
	float patches = fbm(v_uv * grass_patch_scale);
	float dry = smoothstep(0.45, 0.8, fbm(v_uv * grass_patch_scale * 0.6 + 21.7));
	vec3 grass = base * (1.0 + (patches - 0.5) * 2.0 * grass_patch_strength);
	grass = mix(grass, grass_dry_color * (0.7 + patches * 0.6), dry * grass_dry_amount);
	grass += (value_noise(v_uv * grass_blade_scale) - 0.5) * grass_blade_strength * blade_fade;

	// City concrete.
	vec2 slab = floor(v_uv / urban_slab_size);
	vec2 in_slab = fract(v_uv / urban_slab_size) * urban_slab_size;
	vec2 edge = min(in_slab, urban_slab_size - in_slab);
	float joint = (1.0 - smoothstep(0.05, 0.2, min(edge.x, edge.y))) * joint_fade;
	float slab_tint = (hash21(slab + 3.1) - 0.5) * urban_slab_tint_variation;
	float stains = (fbm(v_uv * urban_stain_scale) - 0.5) * urban_stain_strength;
	float grit = (value_noise(v_uv * urban_grit_scale) - 0.5) * urban_grit_strength * grit_fade;
	float u_cracks = (1.0 - smoothstep(0.0, 0.05, cell_edge_noise(v_uv * urban_crack_scale)))
		* step(0.6, value_noise(v_uv * 0.03)); // only in some patches, not a full web
	vec3 city = base + slab_tint + stains + grit;
	city *= 1.0 - u_cracks * urban_crack_darkness;
	city *= 1.0 - joint * urban_joint_darkness;

	base = mix(base, mix(grass, city, urban), ground);

	// --- closing lane hatch -------------------------------------------------
	float hatch_w = v_hatch.y - v_hatch.x;
	if (hatch_w > 0.05) {
		float y = v_uv.y;
		float inside = step(v_hatch.x, y) * step(y, v_hatch.y);
		float stripe = step(fract((v_uv.x - y * 1.5) / hatch_period), hatch_fill);
		float edge = step(v_hatch.x, y) * step(y, v_hatch.x + edge_line_width);
		float fade_in = smoothstep(0.05, 1.0, hatch_w);
		float paint = max(stripe * inside, edge) * fade_in;
		base = mix(base, paint_color, paint * 0.9);
	}

	if (tunnel_glow > 0.0) {
		float along = fract(v_uv.x / lamp_spacing);
		float pulse = 0.9 + 0.1 * cos(along * 6.28318);
		EMISSION = base * tunnel_light_color * tunnel_glow * pulse;
	}
	float ground_ao = mix(1.0 - dry * 0.1, 1.0 - joint * 0.5 - u_cracks * 0.3, urban) * ground + (1.0 - ground);

	ALBEDO = clamp(base, vec3(0.0), vec3(1.0));
	ROUGHNESS = clamp(0.95 + gravel_amount * 0.3 - crack_amount * 0.1, 0.0, 1.0);
	AO = clamp((1.0 - abs(gravel_amount) * 0.6 - crack_amount * 0.4) * ground_ao, 0.0, 1.0);
	AO_LIGHT_AFFECT = 0.6;
}
