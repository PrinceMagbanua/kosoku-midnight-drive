extends Control

## Audio Config panel (mirrors graphics config.gd's toggle pattern). Each
## HSlider in $scroll/container binds to misc_graphics_settings.<var_name>;
## changes apply live and are written to disk (see graphics.gd's
## save_audio_settings) shortly after the last change and on close.

const SAVE_DELAY := 0.4

var _save_timer := Timer.new()

func _ready():
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DELAY
	_save_timer.timeout.connect(misc_graphics_settings.save_audio_settings)
	add_child(_save_timer)

	for slider in _sliders():
		slider.set_value_no_signal(misc_graphics_settings.get(slider.var_name))
		_update_label(slider)
		slider.value_changed.connect(_on_slider_changed.bind(slider))

	$scroll/container/ResetButton.pressed.connect(_on_reset_pressed)
	visibility_changed.connect(_on_visibility_changed)

func _sliders() -> Array:
	return $scroll/container.get_children().filter(func(n): return n is HSlider)

func _update_label(slider: HSlider):
	slider.get_node("amount").text = "%d%%" % int(round(slider.value * 100.0))

func _on_slider_changed(value: float, slider: HSlider):
	misc_graphics_settings.set(slider.var_name, value)
	_update_label(slider)
	_save_timer.start()

func _on_reset_pressed():
	for slider in _sliders():
		slider.value = misc_graphics_settings.AUDIO_DEFAULTS[slider.var_name]

func _on_visibility_changed():
	if not visible and not _save_timer.is_stopped():
		_save_timer.stop()
		misc_graphics_settings.save_audio_settings()

func _input(event):
	if Input.is_action_just_pressed("ui_cancel"):
		visible = false

func _on_Button_pressed():
	if visible:
		visible = false
	else:
		Input.action_press("ui_cancel")
		await get_tree().create_timer(0.1).timeout
		Input.action_release("ui_cancel")
		visible = true
