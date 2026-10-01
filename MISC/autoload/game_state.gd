extends Node

## Autoload. Single state machine driving which UI screen is visible - the
## Godot-signal equivalent of Voxel Driver's `gameState` string variable
## (hud-crash.js/main.js) that every screen/overlay checks each frame.
## Screens should connect to `state_changed` and show/hide themselves rather
## than polling `current` in `_process()`.

enum State { MENU, GARAGE, PLAYING, CRASHING, CRASHED, PAUSED }

signal state_changed(new_state: State, old_state: State)

var current: State = State.MENU
## Set by "end run" from the pause screen (mirrors `resumeToPlayingAfterGarage`
## in hud-crash.js): if true, closing the garage drops straight into a fresh
## run instead of back to the main menu.
var resume_to_playing_after_garage: bool = false

func set_state(new_state: State) -> void:
	if new_state == current:
		return
	var old_state := current
	current = new_state
	state_changed.emit(new_state, old_state)
