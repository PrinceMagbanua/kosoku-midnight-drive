extends CanvasLayer

## Persistent shared "showcase" background - ONE SubViewport/preview-car/
## orbit-camera used by BOTH StartScreen and GarageScreen, instead of each
## owning its own separate preview. This is what lets the car read as one
## continuous element gliding between the Start layout (car offset right,
## via garage_orbit_camera.gd's "start" mode) and the Garage layout (car
## offset left, "car"/"map" modes) rather than a cut between two different
## 3D scenes. Visible for MENU and GARAGE; hidden the rest of the time (the
## live driving world shows through instead, same as before this existed).

@export var orbit_camera_path: NodePath = NodePath("Root/PreviewContainer/PreviewViewport/GaragePreview/OrbitCamera")

@onready var orbit_camera: Camera3D = get_node(orbit_camera_path)

func _ready() -> void:
	# Keep animating (camera orbit/easing) while SceneTree.paused is true -
	# GarageScreen pauses the tree exactly like the pause/crash overlays do,
	# and this preview needs to keep moving through that the same way it
	# always has (previously it inherited PROCESS_MODE_ALWAYS by being
	# nested inside GarageScreen; now a sibling, so it needs its own).
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameState.state_changed.connect(_on_state_changed)
	_on_state_changed(GameState.current, GameState.current)

func _on_state_changed(new_state: GameState.State, old_state: GameState.State) -> void:
	var showing: bool = new_state == GameState.State.MENU or new_state == GameState.State.GARAGE
	visible = showing
	if not showing:
		return
	# A fresh wide "intro" zoom-in ONLY when the showcase was fully hidden
	# before (coming from actually driving/paused/crashed) - re-entering via
	# a plain MENU<->GARAGE transition should keep gliding smoothly instead
	# of snapping back to the intro framing every time.
	var was_hidden: bool = old_state != GameState.State.MENU and old_state != GameState.State.GARAGE
	if was_hidden:
		orbit_camera.reset_intro()
	if new_state == GameState.State.MENU:
		orbit_camera.set_mode("start")
	# GARAGE's own car/map toggle is owned by garage_screen.gd - don't
	# override it here, it already calls set_mode() directly on its buttons.
