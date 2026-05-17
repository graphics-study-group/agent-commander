class_name HexRoadRenderer
extends Node3D

const OPPOSITE_DIR := [3, 4, 5, 0, 1, 2]
const TERRAIN_MOUNTAIN := 2
const TERRAIN_WATER := 3
const BASE_EDGE_MIDPOINTS := [
	Vector3(0.4330, 0.0, -0.7500),
	Vector3(0.8660, 0.0, 0.0000),
	Vector3(0.4330, 0.0, 0.7500),
	Vector3(-0.4330, 0.0, 0.7500),
	Vector3(-0.8660, 0.0, 0.0000),
	Vector3(-0.4330, 0.0, -0.7500)
]

@export var hex_radius := 1.0
@export var road_height := 0.28
@export var road_width := 0.16
@export var default_color := Color(0.55, 0.55, 0.55)
@export var road_material: Material

var _neighbor_types: Array = []
var _road_mask := 0
var _neighbor_road_masks: Array = []

var _mesh_instance: MeshInstance3D


func _ready() -> void:
	_ensure_mesh_instance()
	_rebuild_mesh()


func setup_roads(neighbor_types: Array, road_mask: int, neighbor_road_masks: Array) -> void:
	_neighbor_types = neighbor_types.duplicate()
	_road_mask = road_mask
	_neighbor_road_masks = neighbor_road_masks.duplicate()
	_rebuild_mesh()


func set_hex_metrics(radius: float, height: float) -> void:
	hex_radius = maxf(radius, 0.01)
	road_height = height
	_rebuild_mesh()


func set_road_width_value(width: float) -> void:
	road_width = maxf(width, 0.01)
	_rebuild_mesh()


func set_road_material(mat: Material) -> void:
	road_material = mat
	if _mesh_instance == null:
		return
	_mesh_instance.material_override = _build_material()


func _ensure_mesh_instance() -> void:
	_mesh_instance = get_node_or_null("RoadMesh") as MeshInstance3D
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "RoadMesh"
		add_child(_mesh_instance)


func _rebuild_mesh() -> void:
	_ensure_mesh_instance()
	if _road_mask == 0:
		_mesh_instance.mesh = null
		return

	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	var idx := 0
	for dir in range(6):
		if (_road_mask & (1 << dir)) == 0:
			continue

		var edge_mid: Vector3 = BASE_EDGE_MIDPOINTS[dir] * hex_radius
		edge_mid.y = road_height
		var length_scale := _segment_scale_for_dir(dir)
		var target: Vector3 = edge_mid * length_scale
		target.y = road_height
		var center := Vector3(0.0, road_height, 0.0)
		var seg_dir: Vector3 = (target - center).normalized()
		var perp := Vector3(seg_dir.z, 0.0, -seg_dir.x) * (road_width * 0.5)

		verts.append(center - perp)
		verts.append(center + perp)
		verts.append(target + perp)
		verts.append(target - perp)
		indices.append(idx)
		indices.append(idx + 1)
		indices.append(idx + 2)
		indices.append(idx)
		indices.append(idx + 2)
		indices.append(idx + 3)
		idx += 4

	if verts.is_empty():
		_mesh_instance.mesh = null
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = _build_material()


func _segment_scale_for_dir(dir: int) -> float:
	if dir < 0 or dir > 5:
		return 0.72

	var nb_mask := _get_neighbor_mask(dir)
	var opposite: int = OPPOSITE_DIR[dir]
	if (nb_mask & (1 << opposite)) != 0:
		return 1.0
	return 0.80


func _get_neighbor_type(dir: int) -> int:
	if dir < 0 or dir >= _neighbor_types.size():
		return -1
	return int(_neighbor_types[dir])


func _get_neighbor_mask(dir: int) -> int:
	if dir < 0 or dir >= _neighbor_road_masks.size():
		return 0
	return int(_neighbor_road_masks[dir])


func _build_material() -> Material:
	if road_material != null:
		return road_material
	var mat := StandardMaterial3D.new()
	mat.albedo_color = default_color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	return mat
