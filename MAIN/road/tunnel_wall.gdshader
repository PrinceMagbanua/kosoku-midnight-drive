shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Tunnel interior (RoadTunnel). UV = (distance along road, height above the
// road), world units (~3.27 per metre), seamless across chunks. `mode` 0 =
// the white tiled lower walls, 1 = the grey concrete arch, 2 = the concrete
// walkway/curb. The lamp rows are far too many for real lights on the
// Compatibility renderer, so their light on the walls is faked here as
// emission: a bright band just under the lamp line fading down the tiles,
// with a gentle pulse per lamp, all multiplied by the lamp colour. Real
// lights (headlights, TunnelRig's few moving omnis) still add on top.
uniform int mode = 0;
uniform vec3 tile_color : source_color = vec3(0.86, 0.85, 0.80);
uniform vec3 arch_color : source_color = vec3(0.30, 0.29, 0.28);
uniform vec3 walk_color : source_color = vec3(0.45, 0.44, 0.42);
uniform float tile_height = 0.8; // world units per tile row
uniform float tile_length = 2.0;
uniform float joint_darkness : hint_range(0.0, 1.0) = 0.35;
uniform float grime_height = 4.0; // road spray darkens the bottom of the tiles
uniform float grime_strength : hint_range(0.0, 1.0) = 0.45;
uniform vec3 lamp_color : source_color = vec3(1.0, 0.55, 0.2);
uniform float lamp_line_height = 14.0; // where the lamps sit (set from RoadTunnel)
uniform float lamp_spacing = 13.0;
uniform float glow_base = 0.18; // everywhere
uniform float glow_band = 0.9; // extra near the lamp line
uniform float glow_band_falloff = 9.0; // world units
uniform float arch_glow = 0.12;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

void fragment() {
	float along = UV.x;
	float h = UV.y;
	float grime_n = value_noise(vec2(along * 0.15, h * 0.8));
	float pulse = 0.85 + 0.15 * cos(fract(along / lamp_spacing) * 6.28318);
	vec3 col;
	float glow;
	if (mode == 0) {
		float row = floor(h / tile_height);
		float off = mod(row, 2.0) * 0.5; // running bond
		vec2 t = vec2(fract(along / tile_length + off), fract(h / tile_height));
		float px = fwidth(along / tile_length);
		float joint = (1.0 - smoothstep(0.0, 0.04, min(t.y, 1.0 - t.y)))
			+ (1.0 - smoothstep(0.0, 0.015, min(t.x, 1.0 - t.x))) * 0.6;
		joint *= 1.0 - smoothstep(0.2, 0.6, px);
		float tint = (hash21(vec2(floor(along / tile_length + off), row)) - 0.5) * 0.04;
		col = tile_color + tint;
		col *= 1.0 - clamp(joint, 0.0, 1.0) * joint_darkness;
		col *= 1.0 - (1.0 - smoothstep(0.0, grime_height, h)) * grime_strength * (0.5 + grime_n);
		float below = max(lamp_line_height - h, 0.0);
		glow = glow_base + glow_band * exp(-below / glow_band_falloff);
		ROUGHNESS = 0.25; // glazed tiles catch headlights
		SPECULAR = 0.6;
	} else if (mode == 1) {
		col = arch_color * (0.8 + grime_n * 0.4);
		glow = arch_glow;
		ROUGHNESS = 0.9;
	} else {
		col = walk_color * (0.8 + grime_n * 0.3);
		glow = glow_base * 1.4;
		ROUGHNESS = 0.9;
	}
	ALBEDO = clamp(col, vec3(0.0), vec3(1.0));
	EMISSION = ALBEDO * lamp_color * glow * pulse;
}
