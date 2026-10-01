// The distant city's buildings and lit windows, as a function of where you
// look: `u` = 0..1 around the full circle, `h` = height above the horizon in
// world units. Shared by skyline.gdshader (draws the city band) and
// sea.gdshader (mirrors its lights in the water), so the reflection always
// matches the buildings window for window. skyline.gd copies the city
// material's values for these uniforms onto the sea material.

group_uniforms city;
uniform float building_count = 140.0; // around the full circle (whole number)
uniform float building_min = 15.0;
uniform float building_max = 95.0;
uniform float building_gap_chance = 0.25; // fraction of slots left empty
uniform vec3 window_color : source_color = vec3(1.0, 0.72, 0.38);
uniform float window_lit_chance = 0.12;
uniform float window_columns = 4.0; // per building
uniform float window_row_height = 6.0; // world units per floor
group_uniforms;

float city_hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }
float city_hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

// Roofline height at `u`; hugely negative where the slot is empty.
float city_top(float u) {
	float cell = floor(u * building_count);
	float r = city_hash11(cell + 17.0);
	return (r < building_gap_chance) ? -1e6 : mix(building_min, building_max, pow(city_hash11(cell), 2.0));
}

// True where (u, h) is inside a lit window.
bool city_window_lit(float u, float h) {
	float x = u * building_count;
	float cell = floor(x);
	float top = city_top(u);
	float fx = fract(x) * window_columns;
	float fy = h / window_row_height;
	vec2 win = vec2(fract(fx), fract(fy));
	bool in_window = win.x > 0.3 && win.x < 0.7 && win.y > 0.35 && win.y < 0.7;
	bool lit = city_hash21(vec2(cell * 8.0 + floor(fx), floor(fy))) < window_lit_chance;
	// Keep the roofline and the building's side edges dark.
	bool inside = fract(x) > 0.06 && fract(x) < 0.94 && h < top - window_row_height * 0.6 && h > 2.0;
	return in_window && lit && inside;
}
