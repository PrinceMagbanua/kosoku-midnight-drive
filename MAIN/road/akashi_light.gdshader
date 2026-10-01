shader_type spatial;
render_mode skip_vertex_transform, unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// A point of light on the suspension bridge (the beads along the main cables,
// the red beacons on the tower tops - see road_suspension.gd). One camera-
// facing quad per light, drawn additively as a soft round dot.
//
// Same far-plane trick as akashi_landmark.gdshader (the dot is pulled toward
// the camera along its view ray past compress_start, so it isn't clipped and
// still hides behind the towers), plus a minimum on-screen size so a light a
// kilometre off is still a dot rather than a flickering sub-pixel.

uniform vec3 color : source_color = vec3(0.85, 0.95, 1.0);
uniform float energy = 5.0; // above 1 so the environment's glow picks it up
uniform float size = 3.0; // world units across
uniform float min_angle = 0.0025; // never smaller than this on screen (radians)
uniform float blink_period = 0.0; // seconds; 0 = steady

uniform float compress_start = 790.0;
uniform float compress_end = 836.0;
uniform float compress_scale = 2500.0;
uniform float fade_near = 3600.0;
uniform float fade_far = 5900.0;
// For lights that stand in for real ones the road chunks only show near the
// car: dark inside hide_near, full by hide_far. Both 0 = always on.
uniform float hide_near = 0.0;
uniform float hide_far = 0.0;

varying float strength;

void vertex() {
	vec3 center = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float dist = length(center);
	float span = max(size, dist * min_angle);
	float pull = 1.0;
	if (dist > compress_start) {
		float x = dist - compress_start;
		pull = (compress_start + (compress_end - compress_start) * x / (x + compress_scale)) / dist;
	}
	VERTEX = (center + vec3(VERTEX.xy * span, 0.0)) * pull;
	NORMAL = vec3(0.0, 0.0, 1.0);
	strength = 1.0 - smoothstep(fade_near, fade_far, dist);
	if (hide_far > 0.0) {
		strength *= smoothstep(hide_near, hide_far, dist);
	}
	if (blink_period > 0.0) {
		strength *= smoothstep(-0.2, 0.2, sin(TIME * TAU / blink_period));
	}
}

void fragment() {
	float r = clamp(1.0 - length(UV - vec2(0.5)) * 2.0, 0.0, 1.0);
	ALBEDO = color * energy * r * r * strength;
}
