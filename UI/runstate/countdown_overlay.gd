extends CanvasLayer

## Start-of-run light: a coloured gradient band down from the top edge of the
## screen (drawn above the HUD - this layer is higher than LiveHud's) that
## goes Red, Red, Orange, Green. "GO!" fades in at centre ONLY when it turns
## green. Driven by intro_pan.gd (which owns the timing + input lock); this
## just draws. Tweens ignore Engine.time_scale.

const STAGE_COLORS := [
	Color(1.0, 0.12, 0.08), # red
	Color(1.0, 0.12, 0.08), # red
	Color(1.0, 0.55, 0.05), # orange
]
const GREEN := Color(0.15, 1.0, 0.4)
const BAND_INTENSITY := 0.475
const PULSE_FROM := 0.275 # each beat flashes up from this to BAND_INTENSITY
const GO_HOLD := 0.6

@onready var _band: ColorRect = $Band
@onready var _go: Label = $GoLabel

var _tween: Tween

func _ready() -> void:
	hide_now()

## One beat of the countdown (0 red, 1 red, 2 orange).
func show_stage(index: int) -> void:
	_set_band_color(STAGE_COLORS[clampi(index, 0, STAGE_COLORS.size() - 1)])
	_pulse_band()

## Green: band turns green, "GO!" fades in, then everything fades out.
func show_go() -> void:
	_set_band_color(GREEN)
	_reset_tween()
	_go.pivot_offset = _go.size * 0.5
	_go.scale = Vector2.ONE * 1.25
	_tween.set_parallel(true)
	_tween.tween_method(_set_band_intensity, PULSE_FROM, BAND_INTENSITY, 0.2)
	_tween.tween_property(_go, "modulate:a", 1.0, 0.18)
	_tween.tween_property(_go, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.chain().tween_interval(GO_HOLD)
	_tween.chain().tween_method(_set_band_intensity, BAND_INTENSITY, 0.0, 0.5)
	_tween.tween_property(_go, "modulate:a", 0.0, 0.5) # parallel with the band fade

func hide_now() -> void:
	_reset_tween()
	_set_band_intensity(0.0)
	_go.modulate.a = 0.0

func _pulse_band() -> void:
	_reset_tween()
	_tween.tween_method(_set_band_intensity, PULSE_FROM, BAND_INTENSITY, 0.25).set_ease(Tween.EASE_OUT)

func _reset_tween() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_ignore_time_scale(true)

func _set_band_color(c: Color) -> void:
	(_band.material as ShaderMaterial).set_shader_parameter("band_color", c)

func _set_band_intensity(v: float) -> void:
	(_band.material as ShaderMaterial).set_shader_parameter("intensity", v)
