shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx, cull_back;

// Night sea under the bridges (RoadBridge.make_sea): one big plane that
// follows the camera. Dark water, two scrolling ripple layers perturbing the
// normal, a moon path from the directional moonlight (it's very dim, so the
// strengths below make up for it) - a WIDE soft sheen so the path reaches far
// across the water, with twinkling sparkles scattered through it - and a
// fresnel sheen toward a horizon tint as a soft base glow, with the far
// city's lit windows mirrored over it (see city_reflection). Fades into the
// scene fog like everything else.
uniform vec3 deep_color : source_color = vec3(0.006, 0.012, 0.022);
uniform vec3 horizon_tint : source_color = vec3(0.10, 0.09, 0.10);
uniform float horizon_strength : hint_range(0.0, 4.0) = 1.2;
uniform float fresnel_power : hint_range(1.0, 8.0) = 3.0;
uniform float wave_scale = 0.02; // 1 / world units
uniform float wave_speed = 0.35;
uniform float normal_strength : hint_range(0.0, 1.0) = 0.35;
// Moon path: broad soft sheen (how wide = sheen_sharpness, lower is wider)...
uniform float sheen_strength = 30.0;
uniform float sheen_sharpness = 18.0;
// ...plus small sparkles through it (sparkle_density = share of the water that glints).
uniform float sparkle_strength = 160.0;
uniform float sparkle_sharpness = 60.0;
uniform float sparkle_density : hint_range(0.0, 1.0) = 0.12;
uniform float sparkle_scale = 1.2; // 1 / world units
// Shore cut (RoadBridge.update_sea): water only where dot(xy, world.xz) >= z
// for both planes - one across the road at each end of the bridge, so the sea
// never shows through land that drops below it before / after the bridge.
uniform vec3 clip_a = vec3(0.0, 0.0, -1e9);
uniform vec3 clip_b = vec3(0.0, 0.0, -1e9);

// Mirror of the distant city's lit windows (skyline.gd / skyline.gdshader).
// Each water pixel's view ray is reflected off flat water and followed out to
// the skyline band - a cylinder of skyline_radius around the camera with its
// horizon at camera height - and the shared city function says whether it
// lands on a lit window. The part above the horizon is stretched toward the
// viewer (the long streaks lights make on water) and the ripples wobble and
// break it up.
group_uniforms reflection;
uniform float reflect_strength : hint_range(0.0, 4.0) = 0.8;
uniform float reflect_stretch : hint_range(1.0, 8.0) = 2.5; // how much longer the streaks are than the buildings
uniform float reflect_wobble : hint_range(0.0, 1.0) = 0.35; // ripple distortion / break-up
uniform float reflect_fade = 140.0; // world units of reflected height over which it fades out
// Set by skyline.gd: the city band's radius, and 0 while the skyline is hidden.
uniform float skyline_radius = 840.0;
uniform float skyline_visible = 1.0;
group_uniforms;

// The city's own uniforms (copied from the skyline's material by skyline.gd)
// and city_window_lit().
#include "res://MAIN/misc/skyline_city.gdshaderinc"

varying vec3 v_world;
varying float v_sparkle;

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

float waves(vec2 p) {
	float t = TIME * wave_speed;
	return value_noise(p + vec2(t, t * 0.6)) * 0.6 + value_noise(p * 2.3 - vec2(t * 0.8, -t)) * 0.4;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// Light from the skyline's windows mirrored at the water pixel `world_pos`, seen
// from `cam_pos`. `ripple_a/b` are two samples of the wave height there (0..1),
// `fres` the water's fresnel term. (Built-ins and varyings are passed in -
// custom functions can't read them.)
vec3 city_reflection(vec3 world_pos, vec3 cam_pos, float ripple_a, float ripple_b, float fres) {
	vec3 to_frag = world_pos - cam_pos;
	if (skyline_visible < 0.5 || reflect_strength <= 0.0 || to_frag.y >= 0.0) {
		return vec3(0.0);
	}
	// The view ray mirrored in flat water, followed to the skyline cylinder.
	vec3 r = normalize(vec3(to_frag.x, -to_frag.y, to_frag.z));
	vec2 o = to_frag.xz;
	vec2 d = r.xz;
	float a = dot(d, d);
	float b = dot(o, d);
	float c = dot(o, o) - skyline_radius * skyline_radius;
	float disc = b * b - a * c;
	if (a < 1e-6 || c >= 0.0 || disc <= 0.0) {
		return vec3(0.0); // looking straight down, or water beyond the band
	}
	float t = (-b + sqrt(disc)) / a;
	vec2 hit = o + d * t;
	float rise = r.y * t; // height above the water where the mirrored ray meets the band
	// Height above the horizon (camera level), as the skyline measures it. Below
	// the horizon it's a true mirror; above it the image is stretched into streaks.
	float h = rise + to_frag.y;
	if (h > 0.0) {
		h /= reflect_stretch;
	}
	float u = atan(hit.y, hit.x) / TAU + 0.5;
	u += (ripple_a - 0.5) * 0.006 * reflect_wobble;
	h += (ripple_b - 0.5) * window_row_height * 2.0 * reflect_wobble;
	if (!city_window_lit(u, h)) {
		return vec3(0.0);
	}
	// Ripples cut the streaks into shimmering dashes.
	float dash = smoothstep(0.3, 0.7, waves(world_pos.xz * wave_scale * 6.0));
	float shimmer = mix(1.0, dash, clamp(reflect_wobble * 1.5, 0.0, 1.0));
	float fade = exp(-rise / max(reflect_fade, 1.0));
	return window_color * reflect_strength * fade * shimmer * mix(0.3, 1.0, fres);
}

void fragment() {
	if (dot(clip_a.xy, v_world.xz) < clip_a.z || dot(clip_b.xy, v_world.xz) < clip_b.z) {
		discard;
	}
	vec2 p = v_world.xz * wave_scale;
	float e = 0.05;
	float h0 = waves(p);
	float hx = waves(p + vec2(e, 0.0));
	float hz = waves(p + vec2(0.0, e));
	vec3 n_world = normalize(vec3((h0 - hx) / e * normal_strength, 1.0, (h0 - hz) / e * normal_strength));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), fresnel_power);
	// Twinkle mask: fine noise that shifts with the waves.
	float sp = value_noise(v_world.xz * sparkle_scale + vec2(TIME * 1.7, -TIME * 1.1));
	v_sparkle = smoothstep(1.0 - sparkle_density, 1.0, sp);
	ALBEDO = deep_color;
	ROUGHNESS = 0.12;
	SPECULAR = 0.5;
	EMISSION = horizon_tint * fres * horizon_strength + city_reflection(v_world, CAMERA_POSITION_WORLD, h0, hx, fres);
}

void light() {
	DIFFUSE_LIGHT += ALBEDO * clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI;
	if (LIGHT_IS_DIRECTIONAL) {
		vec3 r = reflect(-LIGHT, NORMAL);
		float rv = max(dot(r, VIEW), 0.0);
		float sheen = pow(rv, sheen_sharpness) * sheen_strength;
		float sparkle = pow(rv, sparkle_sharpness) * sparkle_strength * v_sparkle;
		SPECULAR_LIGHT += LIGHT_COLOR * (sheen + sparkle) * ATTENUATION;
	}
}
