class_name CityTile
extends TileBase

const ROAD_WIDTH := 0.08
const ROAD_SEGMENT_DIRS := [
	Vector3(0.2165, 0.0, -0.3750),
	Vector3(0.4330, 0.0, 0.0000),
	Vector3(0.2165, 0.0, 0.3750),
	Vector3(-0.2165, 0.0, 0.3750),
	Vector3(-0.4330, 0.0, 0.0000),
	Vector3(-0.2165, 0.0, -0.3750)
]

@export var road_height := 0.28

var _road_overlay: MeshInstance3D


func get_terrain_name() -> String:
	return "City"


func _on_road_data_changed() -> void:
	_rebuild_road_overlay()


func _rebuild_road_overlay() -> void:
	if _road_overlay != null and is_instance_valid(_road_overlay):
		_road_overlay.queue_free()
		_road_overlay = null
	if not has_any_road():
		return

	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	var idx := 0
	for dir in range(6):
		if not has_road_in_direction(dir):
			continue
		var edge_mid: Vector3 = ROAD_SEGMENT_DIRS[dir]
		edge_mid.y = road_height
		var center := Vector3(0.0, road_height, 0.0)
		var seg_dir := (edge_mid - center).normalized()
		var perp := Vector3(seg_dir.z, 0.0, -seg_dir.x) * (ROAD_WIDTH * 0.5)

		verts.append(center - perp)
		verts.append(center + perp)
		verts.append(edge_mid + perp)
		verts.append(edge_mid - perp)
		indices.append(idx)
		indices.append(idx + 1)
		indices.append(idx + 2)
		indices.append(idx)
		indices.append(idx + 2)
		indices.append(idx + 3)
		idx += 4

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_road_overlay = MeshInstance3D.new()
	_road_overlay.name = "RoadOverlay"
	_road_overlay.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.55, 0.55)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	_road_overlay.material_override = mat
	add_child(_road_overlay)
