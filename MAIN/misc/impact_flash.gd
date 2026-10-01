extends CanvasLayer

## White VIGNETTE on a big NPC crash (not a full-screen wash) - transparent
## in the center, brightening toward the edges (impact_flash.gdshader),
## darker/less harsh than pure white. crash_system.gd calls flash()
## directly (this node isn't autoload/singleton, just a persistent instance
## in world.tscn found via a NodePath export, same pattern as SpeedBlur).
##
## Layer 8 (above CrashOverlay's 7, the highest layer anything else in this
## project uses) - unlike SpeedBlur, which deliberately stays BELOW every
## UI layer so it only blurs the 3D world, this is meant to read over the
## whole screen for an instant, HUD included.

const FADE_TIME := 0.35

@onready var _rect: ColorRect = $Rect

var _alpha := 0.0

func flash(strength: float = 1.0) -> void:
	_alpha = clampf(strength, 0.0, 1.0)

func _process(delta: float) -> void:
	if _alpha <= 0.0:
		return
	_alpha = maxf(_alpha - delta / FADE_TIME, 0.0)
	_rect.material.set_shader_parameter("intensity", _alpha)
