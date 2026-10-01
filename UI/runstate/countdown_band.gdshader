shader_type canvas_item;

// Start-light band: a coloured gradient strongest at the very top edge of the
// rect, fading to nothing toward its bottom, with the left/right ends
// softened so it doesn't read as a hard bar.

uniform vec4 band_color : source_color = vec4(1.0, 0.12, 0.08, 1.0);
uniform float intensity : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	float fade = pow(1.0 - UV.y, 1.8);
	float sides = smoothstep(0.0, 0.14, UV.x) * smoothstep(0.0, 0.14, 1.0 - UV.x);
	COLOR = vec4(band_color.rgb, fade * mix(0.5, 1.0, sides) * intensity);
}
