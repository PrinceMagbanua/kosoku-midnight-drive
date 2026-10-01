extends CanvasLayer

## Pause menu - mirrors Voxel Driver's #pauseOverlay (hud-crash.js): resume,
## garage (with an "end run?" confirm that banks rewards and can drop
## straight back into a fresh run via GameState.resume_to_playing_after_garage),
## end run. Freezing gameplay uses Godot's own SceneTree.paused instead of a
## manual per-frame skip-update flag (the original's approach in JS, which
## had nothing built-in to reach for) - this node stays PROCESS_MODE_ALWAYS
## so its own buttons keep responding while the tree is paused.

@onready var main_panel: Control = %MainPanel
@onready var confirm_panel: Control = %ConfirmPanel
@onready var resume_button: Button = %ResumeButton
@onready var garage_button: Button = %GarageButton
@onready var end_run_button: Button = %EndRunButton
@onready var confirm_yes_button: Button = %ConfirmYesButton
@onready var confirm_cancel_button: Button = %ConfirmCancelButton

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	resume_button.pressed.connect(_on_resume_pressed)
	garage_button.pressed.connect(_on_garage_pressed)
	end_run_button.pressed.connect(_on_end_run_pressed)
	confirm_yes_button.pressed.connect(_on_confirm_yes_pressed)
	confirm_cancel_button.pressed.connect(_on_confirm_cancel_pressed)
	GameState.state_changed.connect(_on_state_changed)
	_on_state_changed(GameState.current, GameState.current)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and GameState.current == GameState.State.PLAYING:
		GameState.set_state(GameState.State.PAUSED)
		get_tree().paused = true

func _on_state_changed(new_state: GameState.State, _old_state: GameState.State) -> void:
	visible = new_state == GameState.State.PAUSED
	if visible:
		main_panel.visible = true
		confirm_panel.visible = false

func _on_resume_pressed() -> void:
	get_tree().paused = false
	GameState.set_state(GameState.State.PLAYING)

func _on_garage_pressed() -> void:
	main_panel.visible = false
	confirm_panel.visible = true

func _on_end_run_pressed() -> void:
	get_tree().paused = false
	# CrashOverlay banks on entering CRASHED - don't double-bank here.
	GameState.set_state(GameState.State.CRASHED)
	get_tree().paused = true

func _on_confirm_yes_pressed() -> void:
	get_tree().paused = false
	RunRewards.bank_run_rewards()
	GameState.resume_to_playing_after_garage = true
	GameState.set_state(GameState.State.GARAGE)

func _on_confirm_cancel_pressed() -> void:
	confirm_panel.visible = false
	main_panel.visible = true
