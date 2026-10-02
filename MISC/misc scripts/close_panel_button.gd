extends Button

## Generic close button for a debug-HUD dialog panel - just hides its own
## parent Control. Works uniformly across controls manipulator/
## graphics config/audio config since all of them already use plain
## `visible = true/false` to show/hide themselves (confirmed in each panel's
## own _on_*_pressed() toggle method), so this doesn't need to know anything
## panel-specific.

func _ready() -> void:
	pressed.connect(func(): get_parent().visible = false)
