extends PanelContainer

## The dropdown list opened by the gear icon (MenuGear) in debugger.tscn -
## replaces the old always-visible row of "information/graphics config/
## change scene/swap car/control config" buttons. Each item button in
## MenuList/VBox is wired (in debugger.tscn's [connection] block) directly
## to the same target dialog methods the old top-row buttons used, plus a
## second connection back to this node's _on_item_pressed() so picking an
## item also closes this dropdown.

func _on_gear_pressed() -> void:
	visible = not visible

func _on_item_pressed() -> void:
	visible = false
