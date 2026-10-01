class_name TunnelRig
extends Node3D

## Everything a tunnel does around the PLAYER rather than per chunk (added by
## RoadGenerator at runtime, reads its layout/tracker):
## - A small pool of real sodium OmniLights parked at lamp positions just
##   around the car, leapfrogging ahead as it drives - the lamp rows' light on
##   the walls is faked in the shaders, but these give the car body the
##   rhythmic passing highlights. Far ones fade out before they jump, so
##   nothing pops.
## - Engine echo: a reverb on the Engine audio bus, faded in while inside.
## - Weather.sheltered, so rain streaks and tyre spray stop in the tunnel.

const M := RoadMetrics.UNIT_SCALE

const LIGHT_STEP := RoadTunnel.LAMP_SPACING * 3.0 # every 3rd lamp gets a real light
const LIGHTS_PER_SIDE := 4
const LIGHT_RANGE := 8.0 * M
@export var light_energy: float = 1.6
@export var reverb_wet: float = 0.28
const REVERB_FADE := 3.0 # per second

var _lights: Array[OmniLight3D] = []
var _reverb: AudioEffectReverb = null
var _bus := -1
var _fx := -1
var _wet := 0.0

func _ready() -> void:
	for i in LIGHTS_PER_SIDE * 2:
		var l := OmniLight3D.new()
		l.light_color = RoadTunnel.LAMP_COLOR
		l.omni_range = LIGHT_RANGE
		l.omni_attenuation = 1.2
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		_lights.append(l)
	_bus = AudioServer.get_bus_index("Engine")
	if _bus >= 0:
		_reverb = AudioEffectReverb.new()
		_reverb.room_size = 0.55
		_reverb.damping = 0.35
		_reverb.predelay_msec = 40.0
		_reverb.dry = 1.0
		_reverb.wet = 0.0
		AudioServer.add_bus_effect(_bus, _reverb)
		_fx = AudioServer.get_bus_effect_count(_bus) - 1
		AudioServer.set_bus_effect_enabled(_bus, _fx, false)

func _exit_tree() -> void:
	# The effect was added to the shared bus layout at runtime - take it back
	# out so a scene reload doesn't stack another one.
	if _bus >= 0 and _fx >= 0 and _fx < AudioServer.get_bus_effect_count(_bus) \
			and AudioServer.get_bus_effect(_bus, _fx) == _reverb:
		AudioServer.remove_bus_effect(_bus, _fx)

func _physics_process(delta: float) -> void:
	var gen = get_parent()
	if gen == null or gen.tracker == null or gen.layout == null:
		return
	var layout: RoadLayout = gen.layout
	var dist: float = gen.tracker.dist
	var inside: bool = layout.in_tunnel(dist)
	Weather.sheltered = inside
	_update_lights(gen, layout, dist)
	_update_reverb(inside, delta)

func _update_lights(gen, layout: RoadLayout, dist: float) -> void:
	var t: Dictionary = layout.tunnel_at(dist)
	var near: bool = not t.is_empty() and dist > t.portal_in - LIGHT_STEP * 2.0 and dist < t.portal_out + LIGHT_STEP * 2.0
	if not near:
		for l in _lights:
			l.visible = false
		return
	# Slots at base-1 .. base+2 steps: a light enters the window 2 steps ahead
	# and leaves it 2 steps behind, and is fully faded at exactly that
	# distance, so the leapfrog never pops.
	var base: float = floorf(dist / LIGHT_STEP) * LIGHT_STEP
	var i := 0
	for k in LIGHTS_PER_SIDE:
		var ld: float = base + float(k - 1) * LIGHT_STEP
		var w: float = 1.0 - smoothstep(LIGHT_STEP * 0.9, LIGHT_STEP * 2.0, absf(ld - dist))
		var ok: bool = ld >= t.portal_in and ld < t.portal_out and w > 0.01
		var fr: Dictionary = RoadTunnel._frame(gen, ld) if ok else {}
		for side in [-1.0, 1.0]:
			var l: OmniLight3D = _lights[i]
			i += 1
			l.visible = ok
			if ok:
				var ww: float = RoadTunnel._half(gen, ld).y
				l.global_position = RoadTunnel._pt(fr, side * (ww - 0.6 * M), RoadTunnel.WALL_HEIGHT - 0.2 * M)
				l.light_energy = light_energy * w

func _update_reverb(inside: bool, delta: float) -> void:
	if _reverb == null:
		return
	_wet = move_toward(_wet, reverb_wet if inside else 0.0, REVERB_FADE * reverb_wet * delta)
	_reverb.wet = _wet
	AudioServer.set_bus_effect_enabled(_bus, _fx, _wet > 0.005)
