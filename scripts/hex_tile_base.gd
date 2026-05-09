class_name HexTileBase
extends Area3D

@export var tile_coord: Vector2i = Vector2i.ZERO
@export var tile_data: HexTileData = null

var _is_hovered: bool = false
var _is_selected: bool = false

@onready var _mesh_instance: MeshInstance3D = _find_mesh_instance()

func _ready() -> void:
	input_ray_pickable = true
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	input_event.connect(_on_input_event)
	_apply_visual_state()

func set_tile_info(coord: Vector2i, data: HexTileData) -> void:
	tile_coord = coord
	tile_data = data

func reset_state() -> void:
	_is_hovered = false
	_is_selected = false
	_apply_visual_state()

func _on_mouse_entered() -> void:
	_is_hovered = true
	on_hover_start()
	_apply_visual_state()

func _on_mouse_exited() -> void:
	_is_hovered = false
	on_hover_end()
	_apply_visual_state()

func _on_input_event(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_is_selected = not _is_selected
		if _is_selected:
			on_selected()
		else:
			on_deselected()
		_apply_visual_state()
		get_viewport().set_input_as_handled()

func on_hover_start() -> void:
	pass

func on_hover_end() -> void:
	pass

func on_selected() -> void:
	pass

func on_deselected() -> void:
	pass

func _apply_visual_state() -> void:
	if _mesh_instance == null:
		return
	if _is_hovered:
		apply_hover_visual(_mesh_instance)
		return
	if _is_selected:
		apply_selected_visual(_mesh_instance)
		return
	apply_default_visual(_mesh_instance)

func apply_default_visual(mesh: MeshInstance3D) -> void:
	mesh.material_overlay = null

func apply_hover_visual(mesh: MeshInstance3D) -> void:
	mesh.material_overlay = null

func apply_selected_visual(mesh: MeshInstance3D) -> void:
	mesh.material_overlay = null

func create_overlay_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.0
	mat.roughness = 1.0
	mat.emission_enabled = false
	return mat

func _find_mesh_instance() -> MeshInstance3D:
	for child in find_children("*", "MeshInstance3D", true, false):
		return child as MeshInstance3D
	return null
