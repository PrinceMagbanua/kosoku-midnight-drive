class_name WarpStreaks
extends RefCounted

## "Going to the speed of light" streaks: elongated bright boxes spawned in a
## ring around the car and shot backward past it. Shared by nitro_boost.gd
## (held boost), boost_burst.gd (the quick near-miss / slipstream burst) and
## slipstream_fx.gd (the faint draft flow).
##
## `local_coords = false` so, unlike a naive child emitter, existing streaks
## don't get dragged around when the car turns/rolls; only new spawn
## positions/directions track the emitter's current transform each frame.
##
## The emitter's material is its `material_override` (a StandardMaterial3D) -
## callers fade `albedo_color.a` to bring the effect in and out.

static func build(amount := 40, lifetime := 0.35) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.mesh = BoxMesh.new()
	(p.mesh as BoxMesh).size = Vector3(0.03, 0.03, 1.4) * RoadMetrics.UNIT_SCALE
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	p.emission_ring_radius = 2.2 * RoadMetrics.UNIT_SCALE
	p.emission_ring_inner_radius = 1.4 * RoadMetrics.UNIT_SCALE
	p.emission_ring_height = 1.6 * RoadMetrics.UNIT_SCALE
	p.emission_ring_axis = Vector3(0, 0, 1) # ring lies across the car's forward axis
	p.direction = Vector3(0, 0, -1) # streaks shoot backward past the car
	p.spread = 4.0
	p.gravity = Vector3.ZERO
	p.initial_velocity_min = 60.0 * RoadMetrics.UNIT_SCALE
	p.initial_velocity_max = 90.0 * RoadMetrics.UNIT_SCALE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.65, 0.85, 1.0)
	mat.emission_energy_multiplier = 3.0
	mat.albedo_color = Color(0.8, 0.9, 1.0, 0.8)
	p.material_override = mat
	return p
