class_name CarInputLock
extends RefCounted

## Two DIFFERENT techniques for "the player shouldn't be able to drive right
## now" - picking the wrong one for a given situation caused a real bug
## (see suppress_input()'s own note), so read carefully before reusing this
## for a new case.

const WHEEL_CORNERS := ["fr", "fl", "rr", "rl"]

## Every input action car.gd itself reads (see its own _physics_process -
## both keyboard and "_mouse" alternate control-scheme variants).
const DRIVE_ACTIONS := [
	"gas", "gas_mouse", "brake", "brake_mouse", "left", "right",
	"handbrake", "handbrake_mouse", "clutch", "clutch_mouse",
	"shiftup", "shiftup_mouse", "shiftdown", "shiftdown_mouse",
]

## For a REAL, currently-driving car (intro pan-in, crash lock) - forces
## every drive-relevant input action to read as released THIS frame,
## WITHOUT stopping car.gd's script from running. Call every physics frame
## for the whole lock duration, not just once - a single call isn't
## reliably permanent, since a held key's OS repeat/echo can re-assert the
## action's "pressed" state before the lock window ends.
##
## Deliberately NOT process_mode=DISABLED on car.gd (that was the first
## attempt here, and it caused a real "car gets launched" bug): wheel.gd
## reads a large amount of car.gd's own continuously-recomputed state every
## physics frame (steer, brakeline, clutchpedal, rpm, ABS state, locked,
## mass, dsweight, stress...) completely independently of whether car.gd's
## script is actually executing. Disabling car.gd's script froze all of
## that at whatever it happened to be the instant input was cut - if the
## player was mid-throttle/steering, wheel.gd kept applying that frozen,
## never-decaying force every subsequent tick, with none of car.gd's own
## throttle-lift/braking/ABS logic ever running to correct it. Suppressing
## the INPUT instead keeps car.gd's script running normally, so its own
## state decays/settles exactly as if the player had simply let go of every
## control - a coast to a stop, not a frozen snapshot of whatever it was
## doing at the moment of the crash/reset.
## `except` lists actions to leave live (the start intro keeps gas so the
## player can rev in Neutral).
static func suppress_input(except: Array = []) -> void:
	for action in DRIVE_ACTIONS:
		if action in except:
			continue
		if InputMap.has_action(action):
			Input.action_release(action)

## For a FROZEN, non-driving car ONLY (the garage/menu showcase preview -
## garage_preview_settle.gd) - stops car.gd's own script entirely while
## keeping each wheel corner's OWN suspension script running independently,
## so a settling-under-gravity preview doesn't just look frozen/floating.
## Safe there specifically BECAUSE the body is frozen (freeze=true) and
## never actually needs to go anywhere - unlike suppress_input()'s case,
## nothing bad happens if wheel.gd computes forces against stale car.gd
## state, since those forces never move a frozen RigidBody3D. Do NOT use
## this on a real, currently-driving car - see suppress_input() instead.
static func disable_input(car: Node) -> void:
	car.process_mode = Node.PROCESS_MODE_DISABLED
	for corner in WHEEL_CORNERS:
		var w: Node = car.get_node_or_null(corner)
		if w:
			w.process_mode = Node.PROCESS_MODE_ALWAYS

## Counterpart to disable_input() - restores normal processing (both the
## car and its wheels go back to PROCESS_MODE_INHERIT).
static func enable_input(car: Node) -> void:
	car.process_mode = Node.PROCESS_MODE_INHERIT
	for corner in WHEEL_CORNERS:
		var w: Node = car.get_node_or_null(corner)
		if w:
			w.process_mode = Node.PROCESS_MODE_INHERIT
