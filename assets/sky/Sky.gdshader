shader_type sky;

uniform vec3 zenith_tint : source_color = vec3(0.01, 0.02, 0.05);
uniform vec3 horizon_tint : source_color = vec3(0.05, 0.08, 0.18);
uniform float horizon_softness : hint_range(0.0, 1.0) = 0.25;
uniform vec3 horizon_glow_tint : source_color = vec3(0.35, 0.25, 0.45);
uniform float horizon_glow_strength : hint_range(0.0, 2.0) = 0.4;

uniform vec3 moon_tint : source_color = vec3(1.0, 0.98, 0.9);
uniform float moon_radius : hint_range(0.005, 0.3) = 0.115;
uniform float moon_softness : hint_range(0.0, 0.05) = 0.002;

uniform float moon_phase : hint_range(0.0, 1.0) = 0.3;

uniform float moon_phase_rotation : hint_range(0.0, 360.0) = 190.0;
uniform float moon_terminator_softness : hint_range(0.001, 0.3) = 0.04;
uniform float moon_earthshine : hint_range(0.0, 0.3) = 0.05;
uniform vec3 moon_glow_tint : source_color = vec3(0.6, 0.7, 1.0);
uniform float moon_glow_strength : hint_range(0.0, 2.0) = 0.35;
uniform float moon_glow_radius : hint_range(0.01, 1.0) = 0.25;

uniform float star_density : hint_range(10.0, 400.0) = 140.0;
uniform float star_coverage : hint_range(0.0, 0.2) = 0.2;
uniform float star_size : hint_range(0.01, 0.5) = 0.20;
uniform float star_brightness : hint_range(0.0, 3.0) = 1.0;
uniform float star_twinkle_speed : hint_range(0.0, 10.0) = 2.0;
uniform vec3 star_color_cool : source_color = vec3(0.75, 0.85, 1.0);
uniform vec3 star_color_warm : source_color = vec3(1.0, 0.9, 0.75);

uniform float galaxy_strength : hint_range(0.0, 1.0) = 0.25;
uniform vec3 galaxy_tint : source_color = vec3(0.45, 0.35, 0.6);
uniform vec3 galaxy_pole = vec3(0.25, 0.95, 0.15);
uniform float galaxy_width : hint_range(0.02, 1.0) = 0.22;

uniform vec3 cloud_tint : source_color = vec3(0.063, 0.071, 0.106);
uniform float cloud_contour : hint_range(0.0, 1.0) = 0.07;
uniform float cloud_zoom : hint_range(0.1, 10.0) = 2.2;
uniform float cloud_drift : hint_range(0.0, 0.5) = 0.05;
uniform int cloud_layer_count : hint_range(1, 6) = 6;
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.35;
uniform float cloud_opacity : hint_range(0.0, 1.0) = 0.6;

uint pcg_step(uint v) {
	v = v * 747796405u + 2891336453u;
	uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
	return (w >> 22u) ^ w;
}

float cell_random(vec2 cell) {
	uvec2 c = uvec2(ivec2(cell));
	uint mixed = pcg_step(c.x + pcg_step(c.y));
	return float(mixed) / 4294967295.0;
}

float lattice_noise(vec2 pos) {
	vec2 cell_id = floor(pos);
	vec2 local = fract(pos);

	vec2 t2 = local * local;
	vec2 t3 = t2 * local;
	vec2 curve = 10.0 * t3 - 15.0 * t3 * local + 6.0 * t3 * t2;

	float a = cell_random(cell_id + vec2(0.0, 0.0));
	float b = cell_random(cell_id + vec2(1.0, 0.0));
	float c = cell_random(cell_id + vec2(0.0, 1.0));
	float d = cell_random(cell_id + vec2(1.0, 1.0));

	float bottom = mix(a, b, curve.x);
	float top = mix(c, d, curve.x);
	return mix(bottom, top, curve.y);
}

float cloud_pattern(vec2 pos, int layers) {
	float accum = 0.0;
	float amp = 0.5;
	vec2 p = pos;
	for (int i = 0; i < layers; i++) {
		accum += amp * lattice_noise(p);
		p = p * 2.0;
		amp = amp * 0.5;
	}
	return accum;
}

float hash1(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

vec3 star_layer(vec3 dir, float altitude) {
	vec3 p = dir * star_density;
	vec3 cell = floor(p);
	vec3 local = fract(p);

	float h = hash1(cell);
	if (h > star_coverage) {
		return vec3(0.0);
	}

	vec3 star_pos = vec3(
		hash1(cell + vec3(1.0, 0.0, 0.0)),
		hash1(cell + vec3(0.0, 1.0, 0.0)),
		hash1(cell + vec3(0.0, 0.0, 1.0))
	);
	float d = length(local - star_pos);

	float size_rand = hash1(cell + vec3(2.0, 3.0, 4.0));
	float size = mix(star_size * 0.3, star_size, size_rand);
	float star = smoothstep(size, 0.0, d);

	float twinkle_phase = h * TAU * 4.0;
	float tw = 0.5 + 0.5 * sin(TIME * star_twinkle_speed + twinkle_phase);
	star *= mix(0.5, 1.0, tw);

	float color_seed = hash1(cell + vec3(5.0, 6.0, 7.0));
	vec3 col = mix(star_color_cool, star_color_warm, color_seed);

	float horizon_fade = smoothstep(-0.05, 0.25, altitude);
	return col * star * star_brightness * horizon_fade;
}

vec3 galaxy_band(vec3 dir) {
	vec3 pole = normalize(galaxy_pole);
	float d = dot(dir, pole);
	float band = exp(-(d * d) / (galaxy_width * galaxy_width));
	float turbulence = lattice_noise(dir.xz * 3.0 + dir.y * 2.0);
	band *= mix(0.5, 1.2, turbulence);
	return galaxy_tint * band * galaxy_strength;
}

void sky() {
	vec3 up_axis = vec3(0.0, 1.0, 0.0);
	float altitude = dot(EYEDIR, up_axis);

	float band = smoothstep(-horizon_softness, horizon_softness, altitude);
	vec3 result = mix(horizon_tint, zenith_tint, band);

	float horizon_factor = exp(-abs(altitude) * 4.0);
	result += horizon_glow_tint * horizon_factor * horizon_glow_strength;

	result += galaxy_band(EYEDIR) * smoothstep(-0.05, 0.2, altitude);

	result += star_layer(EYEDIR, altitude);

	vec3 moon_dir = normalize(LIGHT0_DIRECTION);
	vec3 arbitrary = (abs(moon_dir.y) < 0.99) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 right = normalize(cross(arbitrary, moon_dir));
	vec3 up_m = cross(moon_dir, right);

	vec3 delta = EYEDIR - moon_dir;
	float to_moon = length(delta);
	float u = dot(delta, right) / max(moon_radius, 0.0001);
	float v = dot(delta, up_m) / max(moon_radius, 0.0001);
	float r2 = u * u + v * v;

	float phase_angle = mix(PI, 0.0, clamp(moon_phase, 0.0, 1.0));
	float rot = radians(moon_phase_rotation);
	vec3 phase_light_local = vec3(sin(phase_angle) * cos(rot), sin(phase_angle) * sin(rot), cos(phase_angle));

	float nz = sqrt(max(0.0, 1.0 - clamp(r2, 0.0, 1.0)));
	vec3 normal_local = normalize(vec3(u, v, nz));
	float lambert = dot(normal_local, phase_light_local);
	float shade = smoothstep(-moon_terminator_softness, moon_terminator_softness, lambert);
	vec3 moon_lit_color = mix(moon_tint * moon_earthshine, moon_tint, shade);

	float moon_disc_mask = smoothstep(moon_radius, moon_radius - moon_softness, to_moon);

	float moon_glow_amount = exp(-pow(to_moon / max(moon_glow_radius, 0.0001), 2.0))
			* moon_glow_strength * mix(0.15, 1.0, moon_phase);
	result += moon_glow_tint * moon_glow_amount;

	result = mix(result, moon_lit_color, moon_disc_mask);

	if (altitude > -0.1) {
		vec2 sky_plane = EYEDIR.xz / (altitude + 0.3);
		sky_plane += TIME * cloud_drift;
		sky_plane *= cloud_zoom;

		float density = cloud_pattern(sky_plane, cloud_layer_count);
		float threshold = mix(0.7, 0.15, cloud_coverage);
		float shape = smoothstep(threshold, threshold + cloud_contour, density);
		shape *= smoothstep(-0.1, 0.3, altitude);

		float moon_influence = exp(-to_moon * 3.0);
		vec3 lit_cloud = cloud_tint * (1.0 + moon_influence * 0.6);

		result = mix(result, lit_cloud, shape * cloud_opacity);
	}

	COLOR = result;
}
