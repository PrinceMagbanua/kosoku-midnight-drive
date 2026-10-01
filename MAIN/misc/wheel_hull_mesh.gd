@tool
extends Node3D

## Pulls one wheel mesh out of the player's voxel car hull and uses it as
## this wheel's visual, instead of car.gd's own generic wheel cylinder mesh
## (hidden separately in base car.tscn) - avoids rendering two overlapping
## wheel sets. Purely cosmetic: this sits under wheel.tscn's existing
## "animation/camber/wheel" node, so it automatically inherits all of
## wheel.gd's steering/camber/spin animation for free without any extra
## logic here.
##
## `@tool`: runs this same extraction in the editor too, not just at Play
## time - opening base car.tscn now shows the real wheel meshes in the 3D
## viewport, so VoxelCarMesh's position/scale can be calibrated against
## what the wheels will actually look like, instead of guessing blind.
##
## `hull_scene`/`hull_scale` are exported (not hardcoded to coupe.glb) so
## this generalizes to whichever car the player has selected once car-select
## exists - currently all 4 corners in base car.tscn default to coupe.glb/
## 2.2078 since that's the only player hull wired up today.
##
## Matching goes through StructuredCarParts (structured_car_parts.gd) - see
## that file for the documented naming convention this asset pack uses.
##
## Re-centers the mesh on its own measured geometric center rather than
## trusting the node's raw local origin - found (by inspecting the actual
## asset data, not guessing) that most of this pack's wheel meshes are NOT
## centered on their own origin (coupe.glb's happens to be; taxi/truck/
## armored/police/passenger's are offset by ~70-140 units in their own
## local space). Left uncorrected, wheel.gd's existing spin/camber/steer
## animation (which rotates the ANCESTOR "wheel" node this sits under)
## would swing the mesh through a wide arc instead of spinning it in place.
## This computes the correction from each mesh's own measured AABB, so it
## self-corrects for any hull automatically - not a fix hardcoded to one
## model's data.

@export var hull_scene: PackedScene = preload("res://assets/cars/coupe.glb")
@export var hull_scale: float = 2.2078 # must match VoxelCarMesh's scale in base car.tscn
@export var wheel_corner: String = "FL" # one of FL/FR/BL/BR

## Modular (Synty) cars only - set by CarConfigurator, never in the editor.
## `rim_scene` (+ optional `tyre_scene`) replaces the hull's own wheel with a
## shared Wheel_NN/Tyre_NN, scaled to the stock wheel's radius (the physics
## tyre is fitted to that) and centred on the same pivot, so wheel.gd's
## spin/steer/camber drive it exactly like the stock one. `paint_material`
## is the car's shared paint (ModularCarBuilder), applied to whichever
## wheel is shown - the pack's meshes carry no textures of their own.
var rim_scene: PackedScene
var tyre_scene: PackedScene
var paint_material: Material

## The shared Wheel_NN/Tyre_NN meshes have their outer (spoke) face toward
## -X, i.e. they're authored as RIGHT-side wheels in this project's car space
## (left = +X) - so the LEFT corners get the 180 degree Y flip. (The brief's
## "flip the right side" is Unity's mirrored X.)
const LEFT_CORNERS := ["FL", "BL"]

## Re-extracts the wheel mesh from the current `hull_scene` - called by
## CarConfigurator when the player switches cars after this node is ready.
func rebuild() -> void:
	_ready()

func _ready() -> void:
	# Idempotent - a @tool script's _ready() can re-run on editor rescans/
	# saves, so clear out a previous extraction before doing it again rather
	# than piling up duplicate wheel meshes over time. Removed immediately (not
	# just queued) so an on-demand rebuild() never briefly shows two wheels.
	for child in get_children():
		remove_child(child)
		child.queue_free()

	var hull := hull_scene.instantiate()
	StructuredCarParts.force_opaque(hull)
	var wheel_mesh := StructuredCarParts.find_part(hull, StructuredCarParts.wheel_patterns(wheel_corner)) as MeshInstance3D
	if wheel_mesh and wheel_mesh.mesh:
		var local_aabb: AABB = wheel_mesh.mesh.get_aabb()
		var center: Vector3 = local_aabb.position + local_aabb.size / 2.0

		if rim_scene:
			_add_custom_wheel(maxf(local_aabb.size.y, local_aabb.size.z) * 0.5)
		else:
			wheel_mesh.get_parent().remove_child(wheel_mesh)
			wheel_mesh.owner = null # was owned by the temp hull instance, now freed below
			add_child(wheel_mesh)
			wheel_mesh.transform = Transform3D.IDENTITY
			wheel_mesh.scale = Vector3.ONE * hull_scale
			# Offsets the mesh back by its own true center (scaled) so that
			# center now sits exactly at this node's origin - i.e. at the real
			# suspension pivot wheel.gd already rotates for spin/camber/steer.
			wheel_mesh.position = -center * hull_scale
			if paint_material:
				ModularCarBuilder.apply_materials(wheel_mesh, paint_material)
	hull.queue_free()

## Rim + tyre centred on this node's origin (the suspension pivot), sized so
## the tyre's radius matches the stock wheel's `stock_radius` (hull space).
func _add_custom_wheel(stock_radius: float) -> void:
	var holder := Node3D.new()
	holder.name = "CustomWheel"
	var rim := rim_scene.instantiate() as Node3D
	holder.add_child(rim)
	var sized: Node3D = rim
	if tyre_scene:
		var tyre := tyre_scene.instantiate() as Node3D
		holder.add_child(tyre)
		sized = tyre
	var box := _subtree_aabb(sized)
	var radius := maxf(box.size.y, box.size.z) * 0.5
	var k := stock_radius / radius if radius > 0.0 else 1.0
	var flip := Basis(Vector3.UP, PI) if LEFT_CORNERS.has(wheel_corner) else Basis.IDENTITY
	var b := flip.scaled(Vector3.ONE * hull_scale * k)
	var centre: Vector3 = box.position + box.size * 0.5
	holder.transform = Transform3D(b, -(b * centre))
	if paint_material:
		ModularCarBuilder.apply_materials(holder, paint_material)
	add_child(holder)

static func _subtree_aabb(root: Node3D) -> AABB:
	var box := AABB()
	var have := false
	for mi in StructuredCarParts.mesh_instances(root):
		if mi.mesh == null:
			continue
		var t := Transform3D.IDENTITY
		var n: Node = mi
		while n != null and n != root.get_parent():
			if n is Node3D:
				t = (n as Node3D).transform * t
			n = n.get_parent()
		var b: AABB = t * mi.mesh.get_aabb()
		box = b if not have else box.merge(b)
		have = true
	return box
