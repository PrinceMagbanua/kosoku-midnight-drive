extends Node3D

## The player car hull model (VoxelCarMesh) has its own built-in
## wheel_FL/FR/BL/BR meshes baked into the body - these must stay hidden
## since the real, animated wheel visuals come from wheel_hull_mesh.gd
## instead (riding on the actual suspension/steering nodes, via a SEPARATE
## temporary hull instance it pulls one wheel mesh out of). Without this,
## both render at once: 4 real wheels + 4 static "ghost" wheels frozen in
## the body's own modeled pose - the exact "two sets of wheels" bug.

const WHEEL_CORNERS := ["FL", "FR", "BL", "BR"]

func _ready() -> void:
	for corner in WHEEL_CORNERS:
		var w := StructuredCarParts.find_part(self, StructuredCarParts.wheel_patterns(corner))
		if w:
			w.visible = false
