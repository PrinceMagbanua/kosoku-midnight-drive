extends CanvasLayer

## "PSX crunch" post effect (psx_crunch.gdshader): low-res pixel snap, colour
## crush, scanline jitter, chromatic aberration, vignette and dither over the
## 3D view. Off by default - switched on and tuned from the dev console's
## "PSX SHADER" section (DevConsole.psx_enabled / DevConsole.psx), applied here
## whenever DevConsole.psx_changed fires.
##
## Layer -9: right above SpeedBlur (-10), so it crunches the blurred, grained,
## shaken image, and below every UI layer, so the HUD and menus stay sharp.
## The BackBufferCopy makes sure this pass reads the screen AS SpeedBlur left
## it, not the copy SpeedBlur itself read from.

const SHADER := preload("res://MAIN/misc/psx_crunch.gdshader")
## Uniforms the shader declares as int (the console stores everything as float).
const INT_UNIFORMS := ["resolution_x", "resolution_y", "color_bit_depth"]

var _material := ShaderMaterial.new()

func _ready() -> void:
	layer = -9
	_material.shader = SHADER
	var copy := BackBufferCopy.new()
	copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	add_child(copy)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = _material
	add_child(rect)
	DevConsole.psx_changed.connect(_apply)
	_apply()

func _apply() -> void:
	visible = DevConsole.psx_enabled
	for key in DevConsole.psx:
		var value: float = DevConsole.psx[key]
		if key in INT_UNIFORMS:
			_material.set_shader_parameter(key, int(round(value)))
		else:
			_material.set_shader_parameter(key, value)
