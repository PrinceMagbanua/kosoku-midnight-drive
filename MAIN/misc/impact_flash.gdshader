shader_type canvas_item;

// White vignette instead of a flat full-screen wash - transparent in the
// center, brightening toward the screen edges, so it reads as an impact
// without blotting out the whole view (or the HUD sitting on top of it).
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec4 vignette_color : source_color = vec4(0.78, 0.74, 0.68, 1.0);
uniform float inner_radius : hint_range(0.0, 1.0) = 0.2;
uniform float outer_radius : hint_range(0.0, 2.0) = 0.95;

void fragment() {
	vec2 centered = UV - vec2(0.5);
	// Slight aspect correction so the vignette reads as a ring, not an oval,
	// on this project's 1024x600 default aspect.
	centered.y *= 0.6;
	float dist = length(centered);
	float vig = smoothstep(inner_radius, outer_radius, dist);
	COLOR = vec4(vignette_color.rgb, vig * intensity * vignette_color.a);
}
