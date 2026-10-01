extends Button

## One reusable hover/press motion script, attached directly to any Button
## in the UI (nav rows, cat rail, buy/sell, endless, etc.) instead of a
## bespoke animation per button. Mirrors the mockup's CSS transitions:
## lift/slide + scale up on hover, quick squash on press. Tune per-instance
## via the exported fields in the inspector - leave hover_offset at ZERO for
## a pure scale-up (used almost everywhere: cat rail, buy/sell, endless,
## etc.), or give it a nonzero offset for the sideways slide the Start
## Screen's nav rows use.

@export var hover_offset: Vector2 = Vector2.ZERO
@export var hover_scale: float = 1.04
@export var press_scale: float = 0.94
@export var hover_time: float = 0.15
@export var press_time: float = 0.06

## Only buttons that actually move (hover_offset != ZERO) need a tracked
## resting position at all. These buttons live inside Containers, which
## position children on a deferred sort pass - a freshly-instanced button
## (e.g. an upgrade row rebuilt on every category switch) can have _ready()
## run before its container ancestors finish laying out the new subtree, so
## capturing "position" then can grab a stale value. Previously this stale
## value still got tweened back to on every hover even when hover_offset
## was ZERO, snapping the button sideways for no reason (the MAP UPGRADES /
## BUY-button-drifting-left bugs this replaced). Skipping the position
## tween entirely whenever hover_offset is ZERO makes those buttons immune:
## there's nothing to mis-capture if position is never touched.
var _moves: bool
var _base_position: Vector2
var _tween: Tween
var _hovering := false

func _ready() -> void:
	_moves = hover_offset != Vector2.ZERO
	_base_position = position
	resized.connect(_on_resized)
	pivot_offset = size / 2.0
	mouse_entered.connect(_on_hover)
	mouse_exited.connect(_on_unhover)
	button_down.connect(_on_press)
	button_up.connect(_on_release)

func _on_resized() -> void:
	pivot_offset = size / 2.0
	if _moves and not _hovering:
		_base_position = position

func _animate(target_scale: Vector2, time: float, offset: Vector2) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	if _moves:
		_tween.tween_property(self, "position", _base_position + offset, time).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "scale", target_scale, time).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _on_hover() -> void:
	if _hovering:
		return
	_hovering = true
	if disabled:
		return
	_animate(Vector2.ONE * hover_scale, hover_time, hover_offset)

func _on_unhover() -> void:
	_hovering = false
	_animate(Vector2.ONE, hover_time, Vector2.ZERO)

func _on_press() -> void:
	if disabled:
		return
	_animate(Vector2.ONE * press_scale, press_time, Vector2.ZERO)

func _on_release() -> void:
	if disabled:
		return
	var offset := hover_offset if _hovering else Vector2.ZERO
	var target_scale := Vector2.ONE * (hover_scale if _hovering else 1.0)
	_animate(target_scale, hover_time, offset)
