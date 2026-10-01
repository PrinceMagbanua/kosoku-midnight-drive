shader_type spatial;
render_mode ambient_light_disabled;

// Yellow retroreflective barrier delineator (see road_generator.gd's
// _build_delineators). Ambient/sky light is disabled and no scene light is
// used, so it sits dark until the PLAYER's headlight beam covers it - then it
// flares via emission (not limited by the real-light budget and well above
// 1.0 HDR, so bloom picks it up). The headlight pose is pushed in every frame
// by road_generator.gd's _update_delineator_headlight().
uniform vec3 albedo_color : source_color = vec3(1.0, 0.78, 0.05);
uniform vec3 headlight_pos = vec3(0.0);
uniform vec3 headlight_dir = vec3(0.0, 0.0, 1.0);
uniform bool headlight_on = true;
// Flare zone: inside cone_half_angle_deg of the beam axis it's full strength,
// fading out over another cone_softness_deg.
uniform float cone_half_angle_deg : hint_range(1.0, 89.0) = 30.0;
uniform float cone_softness_deg : hint_range(0.0, 45.0) = 8.0;
uniform float max_range = 400.0; // world units; fades out over the last 40%
uniform float flare_energy : hint_range(0.0, 64.0) = 12.0;
uniform vec3 flare_color : source_color = vec3(1.0, 0.8, 0.1);

void fragment() {
	ALBEDO = albedo_color;
	ROUGHNESS = 0.6;

	if (headlight_on) {
		vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec3 offset = world_pos - headlight_pos;
		float dist = length(offset);
		vec3 to_frag = offset / max(dist, 0.0001);
		float inner = radians(cone_half_angle_deg);
		float outer = radians(cone_half_angle_deg + cone_softness_deg);
		float cone = smoothstep(cos(outer), cos(inner), dot(to_frag, normalize(headlight_dir)));
		float facing = max(dot(world_normal, -to_frag), 0.0);
		float fade = 1.0 - smoothstep(max_range * 0.6, max_range, dist);
		EMISSION = flare_color * flare_energy * cone * facing * fade;
	}
}
