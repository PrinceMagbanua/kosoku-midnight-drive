shader_type spatial;
render_mode skip_vertex_transform, cull_back;

// The suspension bridge's big pieces (towers, cables, anchorages, piers - see
// road_suspension.gd). They are far taller than the view is deep (the
// skyline band at 840 units / the far plane at 1000, about 260-300 m), so
// drawn normally a tower would snap into view already filling a fifth of the
// screen.
//
// Instead every vertex beyond compress_start is pulled toward the camera
// along its own view ray, into the thin shell between compress_start and
// compress_end. Moving a point along its view ray does not move it on screen,
// so the bridge looks exactly the same - it just stops being clipped, and
// nearer pieces still draw in front of farther ones. compress_end sits just
// inside the skyline band so the towers stand in front of the horizon city.
// The values come from road_suspension.gd (COMPRESS_*), which explains why
// the shell is so thin.
//
// How far away it becomes visible is fade_near..fade_far (true distance): a
// screen-door fade, so it stays in the opaque pass and needs no sorting.
// Back faces must stay culled - depth in the shell is too coarse to keep a
// leg's far side behind its near side.

uniform vec3 albedo : source_color = vec3(0.68, 0.74, 0.64);
uniform float roughness : hint_range(0.0, 1.0) = 0.6;

uniform float compress_start = 790.0;
uniform float compress_end = 836.0;
uniform float compress_scale = 2500.0; // bigger = the shell fills up more slowly
uniform float fade_near = 2300.0; // fully visible inside this distance
uniform float fade_far = 3900.0; // gone beyond this one

// Fake floodlighting: strongest at uplight_base_y (the deck), fading over
// uplight_height above it; faces looking along uplight_axis (the road) catch
// the most. Energy 0 = off.
uniform vec3 uplight_color : source_color = vec3(1.0, 0.93, 0.8);
uniform float uplight_energy = 0.0;
uniform float uplight_base_y = 0.0;
uniform float uplight_height = 400.0;
uniform vec3 uplight_axis = vec3(0.0, 0.0, 1.0);

const float BAYER[16] = float[16](
	0.0, 8.0, 2.0, 10.0,
	12.0, 4.0, 14.0, 6.0,
	3.0, 11.0, 1.0, 9.0,
	15.0, 7.0, 13.0, 5.0);

varying float true_dist;
varying float world_y;

void vertex() {
	vec3 v = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	NORMAL = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
	world_y = (INV_VIEW_MATRIX * vec4(v, 1.0)).y;
	true_dist = length(v);
	if (true_dist > compress_start) {
		float x = true_dist - compress_start;
		float d = compress_start + (compress_end - compress_start) * x / (x + compress_scale);
		v *= d / true_dist;
	}
	VERTEX = v;
}

void fragment() {
	float fade = 1.0 - smoothstep(fade_near, fade_far, true_dist);
	int cell = (int(FRAGCOORD.y) % 4) * 4 + int(FRAGCOORD.x) % 4;
	if (fade < (BAYER[cell] + 0.5) / 16.0) {
		discard;
	}
	ALBEDO = albedo;
	ROUGHNESS = roughness;
	if (uplight_energy > 0.0) {
		float rel = (world_y - uplight_base_y) / uplight_height;
		float glow = rel < 0.0 ? 0.3 : mix(1.0, 0.2, clamp(rel, 0.0, 1.0));
		vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		float form = 0.55 + 0.45 * abs(dot(n, uplight_axis));
		EMISSION = albedo * uplight_color * uplight_energy * glow * form;
	}
}
