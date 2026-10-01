extends Control

var car

func setcar():
	car = get_parent().get_node(get_parent().car)

## Generic sync loop - was checkbox-only (button_pressed/var_name), now
## type-aware so a slider (value/var_name, same var_name convention audio
## config.gd's own sliders use) can live in the same container without the
## loop erroring on a property CheckBox and HSlider don't share.
func _ready():
	for i in $scroll/container.get_children():
		if i is CheckBox:
			i.button_pressed = misc_graphics_settings.get(i.var_name)
			i.get_node("amount").text = str(i.button_pressed)
		elif i is HSlider:
			i.value = misc_graphics_settings.get(i.var_name)
			i.get_node("amount").text = "%d%%" % int(round(i.value * 100.0))

func _process(delta):
	for i in $scroll/container.get_children():
		if i is CheckBox:
			misc_graphics_settings.set(i.var_name, i.button_pressed)
			i.get_node("amount").text = str(i.button_pressed)
		elif i is HSlider:
			misc_graphics_settings.set(i.var_name, i.value)
			i.get_node("amount").text = "%d%%" % int(round(i.value * 100.0))

func _input(event):
	if Input.is_action_just_pressed("ui_cancel"):
		visible = false
	elif Input.is_action_just_pressed("toggle_fs"):
		$scroll/container/_FULLSCREEN.button_pressed = !$scroll/container/_FULLSCREEN.button_pressed

#		if $scroll/container/_FULLSCREEN.button_pressed:
#			$scroll/container/_FULLSCREEN.button_pressed = false
#		else:
#			$scroll/container/_FULLSCREEN.button_pressed = true


func _on_Button_pressed():
	get_parent().get_node("open graphics").release_focus()
	if visible:
		visible = false
	else:
		Input.action_press("ui_cancel")
		await get_tree().create_timer(0.1).timeout
		Input.action_release("ui_cancel")
		visible = true
