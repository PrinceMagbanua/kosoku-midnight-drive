class_name CarMeshUtil
extends RefCounted

## The car's visible solid meshes, found by walking down from `node` - skips
## hidden branches, the ink outline shells (car_outlines.gd) and transparent
## helpers (fake light cones etc.), so what's left is just the car's shape.
## Used by slow_mo.gd's afterimages and boost_burst.gd's shine sweep.
static func solid_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for child in node.get_children():
		if child is MeshInstance3D and child.visible and child.mesh and not child.has_meta("car_outline"):
			var m := (child as MeshInstance3D).material_override as BaseMaterial3D
			if m == null or m.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
				out.append(child as MeshInstance3D)
		if child is Node3D and (child as Node3D).visible:
			out.append_array(solid_meshes(child))
	return out
