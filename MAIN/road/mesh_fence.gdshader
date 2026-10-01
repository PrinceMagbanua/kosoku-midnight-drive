shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// See-through wire mesh panel above the concrete parapet (RoadBarriers
// MESH_FENCE). UV = (distance along road, height), world units (~3.27 per
// metre), so the grid never seams across chunks. Wires are drawn where the
// fragment sits near a grid line; far away (grid smaller than a pixel) it
// fades to a flat faint tint instead of shimmering moire.
uniform vec3 wire_color : source_color = vec3(0.78, 0.80, 0.82);
uniform float cell_size : hint_range(0.05, 2.0) = 0.33; // one diamond, world units
uniform float wire_width : hint_range(0.01, 0.5) = 0.12; // fraction of a cell
uniform float wire_alpha : hint_range(0.0, 1.0) = 0.9;
uniform float far_alpha : hint_range(0.0, 1.0) = 0.22; // flat coverage once the grid is sub-pixel

void fragment() {
	// Diamond (chain-link) grid: two diagonal line families.
	vec2 p = UV / cell_size;
	vec2 q = vec2(p.x + p.y, p.x - p.y) * 0.5;
	vec2 dist = abs(fract(q) - 0.5);
	float line = 1.0 - smoothstep(0.5 - wire_width, 0.5 - wire_width * 0.4, max(dist.x, dist.y));
	float px = length(fwidth(p));
	float far_t = smoothstep(0.25, 0.8, px);
	ALBEDO = wire_color;
	METALLIC = 0.5;
	ROUGHNESS = 0.45;
	ALPHA = mix(line * wire_alpha, far_alpha, far_t);
}
