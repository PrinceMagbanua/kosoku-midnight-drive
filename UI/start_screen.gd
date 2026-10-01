extends CanvasLayer

## Main menu overlay - mirrors Voxel Driver's #startScreen (index.html):
## title, best-distance readout, DRIVE / GARAGE. The shared MenuShowcase
## (menu_showcase.gd) renders the spinning preview car behind this as a
## plain full-screen background - this screen no longer draws its own dark
## overlay/background, since the showcase is already dark/spotlit on its
## own (see GaragePreview.tscn). No difficulty picker here either -
## difficulty is purchased in the garage, same as the original.

@export var orbit_camera_path: NodePath = NodePath("../MenuShowcase/Root/PreviewContainer/PreviewViewport/GaragePreview/OrbitCamera")

@onready var panel: Control = %Panel
@onready var best_distance_label: Label = %BestDistanceLabel
@onready var play_endless_button: Button = %PlayEndlessButton
@onready var garage_button: Button = %GarageButton
@onready var exit_button: Button = %ExitButton
@onready var cash_label: Label = %CashLabel
@onready var credits_button: Button = %CreditsButton
@onready var credits_overlay: Control = %CreditsOverlay
@onready var credits_text: RichTextLabel = %CreditsText
@onready var credits_close_button: Button = %CreditsCloseButton

## Attributions shown by the lower-right CREDITS link (main menu only). Full
## license texts ship as files in LICENSES/ next to the exe - keep the two in
## sync when adding third-party assets.
const CREDITS_BBCODE := """[b]Vehicle physics[/b]
VitaVehicles by Jreo - [url=https://jreo.itch.io/rcp4]jreo.itch.io/rcp4[/url]
Code: MIT License. Assets: [url=https://creativecommons.org/licenses/by/4.0/]CC BY 4.0[/url]. Modified.

[b]Vehicles & city buildings[/b]
Low Poly Ultimate Pack by polyperfect

[b]Night city buildings[/b]
"Low Poly Night City Building Skyline" by 99.Miles - [url=https://sketchfab.com/3d-models/low-poly-night-city-building-skyline-b0035b8713b048bb8ddf311ee67c28c8]Sketchfab[/url]
Licensed under [url=https://creativecommons.org/licenses/by/4.0/]CC BY 4.0[/url]. Modified (split into separate buildings, re-pivoted).

[b]Trees & plants[/b]
Low-Poly Plants Kit by Shapespark (CC0)

[b]Fonts[/b]
Kosoku Display (modified from Revalia by Johan Kallas & Mihkel Virkus), Exo 2 (SIL Open Font License 1.1)
Droid Sans (Apache License 2.0)

[b]Engine[/b]
Made with [url=https://godotengine.org]Godot Engine[/url] (MIT License)

Full license texts are in the LICENSES folder shipped with the game."""

const EXIT_OFFSET := -420.0 # how far off-screen (to the left) the panel slides before GameState actually flips to GARAGE
const TRANSITION_TIME := 0.35

var _base_panel_x: float = 0.0
var _transitioning := false

func _ready() -> void:
	# Like GarageScreen/PauseOverlay/CrashOverlay, this needs to keep
	# responding to its own buttons while the tree is paused (see
	# _on_state_changed below - MENU is now paused too, same reasoning as
	# GARAGE: the real gameplay car doesn't check GameState, so nothing else
	# stops it from driving/reading input in the background).
	process_mode = Node.PROCESS_MODE_ALWAYS
	play_endless_button.pressed.connect(_on_play_endless_pressed)
	garage_button.pressed.connect(_on_garage_pressed)
	exit_button.pressed.connect(_on_exit_pressed)
	credits_text.text = CREDITS_BBCODE
	credits_text.meta_clicked.connect(func(meta): OS.shell_open(str(meta)))
	credits_button.pressed.connect(func(): credits_overlay.visible = true)
	credits_close_button.pressed.connect(func(): credits_overlay.visible = false)
	GameState.state_changed.connect(_on_state_changed)
	_base_panel_x = panel.position.x
	_on_state_changed(GameState.current, GameState.current)
	_refresh_stats()

func _on_state_changed(new_state: GameState.State, _old_state: GameState.State) -> void:
	visible = new_state == GameState.State.MENU
	credits_overlay.visible = false
	# car.gd doesn't check GameState (kept as-is, see merge plan) - without
	# this the live gameplay car kept driving/reading input (audible engine
	# sound, visible motion) while just sitting at the main menu. Paused for
	# MENU *and* GARAGE - both share this exact predicate with
	# garage_screen.gd's own pause line so neither screen's state_changed
	# handler can race the other and undo it (see that script's own note).
	get_tree().paused = new_state == GameState.State.MENU or new_state == GameState.State.GARAGE
	if visible:
		panel.position.x = _base_panel_x
		panel.modulate.a = 1.0
		_transitioning = false
		_refresh_stats()

func _unhandled_input(event: InputEvent) -> void:
	if visible and credits_overlay.visible and event.is_action_pressed("ui_cancel"):
		credits_overlay.visible = false
		get_viewport().set_input_as_handled()

func _refresh_stats() -> void:
	var furthest: float = SaveData.game.garage.furthest_dist
	best_distance_label.text = "%d m" % int(furthest) if furthest > 0 else "-"
	cash_label.text = "$%d" % SaveData.game.garage.cash

func _on_play_endless_pressed() -> void:
	LoadingScreen.enter_drive(func(): GameState.set_state(GameState.State.PLAYING))

func _on_exit_pressed() -> void:
	get_tree().quit()

## Slides this panel out to the left with a fade, kicks the shared showcase
## camera into gliding toward the Garage framing immediately (so the car is
## already moving by the time the Garage panel appears, not a hard cut),
## then flips GameState once the exit finishes - garage_screen.gd's own
## entrance tween picks up from there (see its _on_state_changed).
func _on_garage_pressed() -> void:
	if _transitioning:
		return
	_transitioning = true
	var cam: Camera3D = get_node_or_null(orbit_camera_path)
	if cam:
		cam.set_mode("car")
	var tw := create_tween()
	tw.tween_property(panel, "position:x", _base_panel_x + EXIT_OFFSET, TRANSITION_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(panel, "modulate:a", 0.0, TRANSITION_TIME)
	tw.finished.connect(func():
		_transitioning = false
		GameState.set_state(GameState.State.GARAGE)
	)
