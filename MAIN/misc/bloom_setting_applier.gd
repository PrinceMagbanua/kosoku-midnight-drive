extends WorldEnvironment

## Applies the user's Bloom Intensity graphics setting live to this
## WorldEnvironment's own Environment resource - one shared script so both
## the driving world (NightEnvironment.tscn) and the garage/menu showcase
## (UI/garage/GaragePreview.tscn) respond to the same setting instead of
## carrying two copies that could drift apart. Polls each frame (same
## pattern as crossfade.gd's engine_volume / tyres.gd's tyre_volume) rather
## than signal wiring - simplest way to stay in sync with a setting that can
## change any time the Graphics Config panel is open.
##
## The Glow values authored in the editor (Environment > Glow) are the look;
## the setting is only a 0..1 multiplier on top of the authored intensity, so
## tweaking glow in the inspector is what you get in-game at setting 1.0.

var _base_intensity: float = 0.3
var _base_enabled: bool = false


func _ready() -> void:
	if environment == null:
		return
	_base_intensity = environment.glow_intensity
	_base_enabled = environment.glow_enabled


func _process(_delta: float) -> void:
	if environment == null:
		return
	var scale: float = misc_graphics_settings.bloom_intensity
	environment.glow_enabled = _base_enabled and scale > 0.001
	environment.glow_intensity = _base_intensity * scale
