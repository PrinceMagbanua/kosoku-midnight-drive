shader_type spatial;
render_mode unshaded;

// Glowing fittings (tunnel lamps, emergency light boxes, signs). Colour comes
// from the MultiMesh instance colour; `energy` pushes it past 1.0 so the
// Environment's glow picks it up as bloom.
uniform float energy = 4.0;

void fragment() {
	ALBEDO = COLOR.rgb * energy;
}
