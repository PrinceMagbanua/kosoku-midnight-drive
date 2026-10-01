shader_type spatial;

// Inverted-hull outline (Borderlands-style ink line) - see car_outlines.gd.
// Drawn on a duplicate of each car mesh whose NORMAL has been re-baked as a
// smoothed, per-position average (so hard-edged voxel/low-poly corners don't
// split open), pushed out along that normal, with front faces culled - only
// the "shell" peeking out past the real mesh's silhouette stays visible.
//
// The push happens in SCREEN space (sideways only, depth untouched), not
// along the 3D normal: a 3D push also moves the shell toward/away from the
// camera, which is what made black blotches poke through neighbouring parts
// (bumpers, mirrors, spoilers) and made the line fat on some meshes and thin
// on others. Sideways-only keeps the shell's depth behind the real surface.
render_mode unshaded, cull_front;

uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
// Line thickness in pixels, set live by car_outlines.gd (slider).
uniform float outline_px = 2.4;
// Closer than this (world units from the camera) the line stays exactly
// outline_px wide; further away it thins in proportion, down to min_scale,
// so distant traffic doesn't turn into solid black blobs.
uniform float ref_distance = 15.0;
uniform float min_scale = 0.35;

void vertex() {
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	vec3 view_n = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
	// Normal's direction on screen, in pixels (aspect-correct).
	vec2 dir = (PROJECTION_MATRIX * vec4(view_n, 0.0)).xy * VIEWPORT_SIZE;
	float len = length(dir);
	dir = len > 1e-5 ? dir / len : vec2(0.0);
	float scale = clamp(ref_distance / max(clip.w, 1e-3), min_scale, 1.0);
	// UV.x = per-vertex corner multiplier baked by car_outlines.gd, so
	// corners reach out as far as the flat faces around them.
	float px = outline_px * scale * UV.x;
	// pixels -> clip space (NDC spans 2 units across the viewport; * w
	// undoes the perspective divide).
	clip.xy += dir * px * 2.0 / VIEWPORT_SIZE * clip.w;
	POSITION = clip;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
