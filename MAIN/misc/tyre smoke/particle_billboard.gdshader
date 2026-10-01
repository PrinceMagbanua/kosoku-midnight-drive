// NOTE: Shader automatically converted from Godot Engine 3.5.1.stable's SpatialMaterial.
// Extracted from smoke.tscn's inline shader (unchanged) so wheel_spray.gd's
// rain-mist particles can share it instead of duplicating the code.

shader_type spatial;
// unshaded: lit, the billboard quads' normals don't follow the view-facing
// rotation in vertex() below, so the smoke picked up almost no light and
// rendered near-black (worse at night / with low ambient). Smoke should read
// as white/grey regardless of scene lighting, same as spray.tscn's unshaded
// StandardMaterial3D. (texture_normal/normal_scale are now unused.)
render_mode blend_mix,depth_draw_opaque,cull_back,unshaded;
uniform vec4 albedo : source_color;
uniform sampler2D texture_albedo : hint_default_white;
uniform int particles_anim_h_frames;
uniform int particles_anim_v_frames;
uniform bool particles_anim_loop;
uniform sampler2D texture_normal : hint_normal;
uniform float normal_scale : hint_range(-16,16);


void vertex() {
	mat4 mat_world = mat4(normalize(INV_VIEW_MATRIX[0])*length(MODEL_MATRIX[0]),normalize(INV_VIEW_MATRIX[1])*length(MODEL_MATRIX[0]),normalize(INV_VIEW_MATRIX[2])*length(MODEL_MATRIX[2]),MODEL_MATRIX[3]);
	mat_world = mat_world * mat4( vec4(cos(INSTANCE_CUSTOM.x),-sin(INSTANCE_CUSTOM.x), 0.0, 0.0), vec4(sin(INSTANCE_CUSTOM.x), cos(INSTANCE_CUSTOM.x), 0.0, 0.0),vec4(0.0, 0.0, 1.0, 0.0),vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat_world;
	float h_frames = float(particles_anim_h_frames);
	float v_frames = float(particles_anim_v_frames);
	float particle_total_frames = float(particles_anim_h_frames * particles_anim_v_frames);
	float particle_frame = floor(INSTANCE_CUSTOM.z * float(particle_total_frames));
	if (!particles_anim_loop) {
		particle_frame = clamp(particle_frame, 0.0, particle_total_frames - 1.0);
	} else {
		particle_frame = mod(particle_frame, particle_total_frames);
	}	UV /= vec2(h_frames, v_frames);
	UV += vec2(mod(particle_frame, h_frames) / h_frames, floor((particle_frame + 0.5) / h_frames) / v_frames);
}




void fragment() {
	vec2 base_uv = UV;
	vec4 albedo_tex = texture(texture_albedo,base_uv)*COLOR;
	ALBEDO = albedo.rgb * albedo_tex.rgb;
	ALPHA = albedo_tex.a;
}
