class_name TileBase
extends Node3D

signal unit_entered(unit: Object)
signal unit_exited(unit: Object)

const DEFAULT_MODEL_PATH := "res://assets/HexagonalPrism.glb"
const ROAD_WIDTH := 0.08
const ROAD_SEGMENT_DIRS := [
	Vector3(0.2165, 0.0, -0.3750),
	Vector3(0.4330, 0.0, 0.0000),
	Vector3(0.2165, 0.0, 0.3750),
	Vector3(-0.2165, 0.0, 0.3750),
	Vector3(-0.4330, 0.0, 0.0000),
	Vector3(-0.2165, 0.0, -0.3750)
]

@export var tile_scale := 0.97
@export var road_height := 0.28

var grid_col := 0
var grid_row := 0
var terrain_type := 0
var road_mask := 0

var _visual_root: Node3D
var _road_overlay: MeshInstance3D


func _ready() -> void:
	_ensure_visual_root()
	_ensure_model()
	_apply_terrain_visuals()
	_rebuild_road_overlay()


func configure(col: int, row: int, tile_type: int, roads: int) -> void:
	grid_col = col
	grid_row = row
	terrain_type = tile_type
	road_mask = roads
	_ensure_visual_root()
	_ensure_model()
	_apply_terrain_visuals()
	_rebuild_road_overlay()


func set_road_mask(roads: int) -> void:
	road_mask = roads
	_rebuild_road_overlay()


func set_selected(selected: bool) -> void:
	scale = Vector3.ONE * (1.05 if selected else 1.0)


func on_unit_enter(unit: Object) -> void:
	unit_entered.emit(unit)


func on_unit_leave(unit: Object) -> void:
	unit_exited.emit(unit)


func is_passable() -> bool:
	return true


func get_terrain_name() -> String:
	return "Plain"


func _get_terrain_color() -> Color:
	return Color(0.35, 0.65, 0.25)


func _ensure_visual_root() -> void:
	_visual_root = get_node_or_null("VisualRoot") as Node3D
	if _visual_root == null:
		_visual_root = Node3D.new()
		_visual_root.name = "VisualRoot"
		add_child(_visual_root)


func _ensure_model() -> void:
	if _visual_root.get_node_or_null("Model") != null:
		return
	var model_scene := load(DEFAULT_MODEL_PATH) as PackedScene
	if model_scene == null:
		return
	var model := model_scene.instantiate() as Node3D
	if model == null:
		return
	model.name = "Model"
	model.scale = Vector3.ONE * tile_scale
	_visual_root.add_child(model)


func _apply_terrain_visuals() -> void:
	if _visual_root == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _get_terrain_color()
	_set_mat_recursive(_visual_root, mat)


func _set_mat_recursive(node: Node, mat: Material) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = mat
	for child in node.get_children():
		_set_mat_recursive(child, mat)


func _rebuild_road_overlay() -> void:
	if _road_overlay != null and is_instance_valid(_road_overlay):
		_road_overlay.queue_free()
		_road_overlay = null
	if road_mask == 0:
		return

	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	var idx := 0
	for dir in range(6):
		if (road_mask & (1 << dir)) == 0:
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
