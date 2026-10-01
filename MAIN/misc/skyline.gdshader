shader_type spatial;
// Distant horizon silhouette on an open cylinder band (see skyline.gd).
// mode 0 = mountain ridges, mode 1 = city blocks with lit windows. Everything
// is procedural and there is no texture. Pixels above the silhouette are
// discarded (alpha-scissor style), so the band stays in the opaque pass: one
// draw call, and hidden sky behind it costs nothing. Unshaded, but scene fog
// still applies, so it fades into the haze.
render_mode unshaded, cull_disabled, shadows_disabled;

uniform int mode = 0;
uniform vec3 base_color : source_color = vec3(0.035, 0.04, 0.06);
// Mesh-centre height above the horizon (skyline.gd sets this), so heights below
// are in world units measured from the horizon line.
uniform float horizon_offset = 0.0;

group_uniforms mountains;
uniform float ridge_min = 40.0;
uniform float ridge_max = 190.0;
uniform float ridge_repeats = 7.0; // big peaks around the full circle (whole number keeps it seamless)
uniform float ridge_roughness = 0.45; // how much each finer octave adds

group_uniforms;

// The city's uniforms (group "city") and its building/window functions - shared
// with sea.gdshader, which mirrors the lit windows in the water.
#include "res://MAIN/misc/skyline_city.gdshaderinc"

varying vec3 local_pos;

float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }

// 1D value noise that wraps every `period` cells, so it has no seam around the circle.
float wrap_noise(float x, float period) {
	float i = floor(x);
	float f = fract(x);
	float a = hash11(mod(i, period));
	float b = hash11(mod(i + 1.0, period));
	return mix(a, b, f * f * (3.0 - 2.0 * f));
}

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	// Angle is computed per pixel, not in the vertex shader, so the wrap
	// from 1 back to 0 never interpolates across a triangle.
	float u = atan(local_pos.z, local_pos.x) / TAU + 0.5;
	float h = local_pos.y + horizon_offset;
	vec3 col = base_color;

	if (mode == 0) {
		float n = 0.0;
		float amp = 1.0;
		float total = 0.0;
		float freq = ridge_repeats;
		for (int o = 0; o < 4; o++) {
			n += wrap_noise(u * freq, freq) * amp;
			total += amp;
			amp *= ridge_roughness;
			freq *= 2.0;
		}
		float ridge = mix(ridge_min, ridge_max, n / total);
		if (h > ridge) discard;
		// Slightly lighter toward the peaks so layered ridges read as shapes.
		col *= mix(0.7, 1.15, clamp(h / ridge_max, 0.0, 1.0));
	} else {
		if (h > city_top(u)) discard;
		if (city_window_lit(u, h)) col = window_color;
	}
	ALBEDO = col;
}
