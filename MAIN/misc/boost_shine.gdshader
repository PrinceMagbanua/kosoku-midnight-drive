shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;

// Boost "shine": a bright band that runs over the car from nose to tail.
// Set as material_overlay on the car's meshes by boost_burst.gd for the length
// of one sweep. The band is placed in WORLD space along the car's forward
// axis (car_origin / car_forward, updated every frame), so it lines up across
// every mesh of the car whatever their own transforms are.

uniform vec3 car_origin;
uniform vec3 car_forward = vec3(0.0, 0.0, 1.0);
// Band centre, world units along car_forward from car_origin (+ = nose).
uniform float sweep = 0.0;
// Band half-width, world units.
uniform float width = 1.2;
uniform vec4 color : source_color = vec4(0.75, 0.95, 1.0, 1.0);
uniform float strength = 1.0;

varying float along;

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	along = dot(world_pos - car_origin, car_forward);
}

void fragment() {
	float band = 1.0 - smoothstep(0.0, width, abs(along - sweep));
	// Brighter on faces seen edge-on, so it reads as a glint running over the body.
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	ALBEDO = color.rgb * (0.6 + rim * 1.4);
	ALPHA = band * band * strength * color.a;
}
