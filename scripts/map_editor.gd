extends Node3D

const USER_MAP_DIR := "user://maps"
const INVALID_FILE_CHARS := ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]

const TERRAIN_OPTIONS := [
	{"id": 0, "label": "Plain"},
	{"id": 1, "label": "Forest"},
	{"id": 2, "label": "Mountain"},
	{"id": 3, "label": "Water"},
	{"id": 4, "label": "City"}
]

@onready var _hex_map: Node = $HexagonalMap
@onready var _status_label: Label = $UILayer/EditorUI/VBox/StatusLabel
@onready var _regen_btn: Button = $UILayer/EditorUI/VBox/GenerateButton
@onready var _save_btn: Button = $UILayer/EditorUI/VBox/SaveButton
@onready var _cols_spin: SpinBox = $UILayer/EditorUI/VBox/SizeRow/ColsSpin
@onready var _rows_spin: SpinBox = $UILayer/EditorUI/VBox/SizeRow/RowsSpin
@onready var _all_plain_check: CheckBox = $UILayer/EditorUI/VBox/AllPlainCheck
@onready var _name_edit: LineEdit = $UILayer/EditorUI/VBox/SaveRow/NameEdit
@onready var _terrain_option: OptionButton = $UILayer/EditorUI/VBox/PaintRow/TerrainOption

var _is_painting := false
var _last_painted := Vector2i(-1, -1)


func _ready() -> void:
	_regen_btn.pressed.connect(_on_generate_pressed)
	_save_btn.pressed.connect(_on_save_pressed)
	_terrain_option.item_selected.connect(_on_paint_type_changed)
	_populate_terrain_options()
	_on_generate_pressed()


func _on_generate_pressed() -> void:
	if _hex_map != null and _hex_map.has_method("regenerate_map"):
		var cols := int(_cols_spin.value)
		var rows := int(_rows_spin.value)
		var all_plain := _all_plain_check.button_pressed
		_hex_map.regenerate_map(cols, rows, all_plain)
		var mode := "All Plain" if all_plain else "Random"
		_status_label.text = "%s map generated: %dx%d" % [mode, cols, rows]
	else:
		_status_label.text = "Hex map node is missing regenerate_map API."


func _on_save_pressed() -> void:
	if _hex_map == null or not _hex_map.has_method("export_map_data"):
		_status_label.text = "Hex map node is missing export API."
		return

	var map_data: Resource = _hex_map.export_map_data()
	if map_data == null:
		_status_label.text = "Export failed: no map data."
		return

	var safe_name := _sanitize_map_name(_name_edit.text)
	if safe_name.is_empty():
		_status_label.text = "Please input a valid map name."
		return
	var save_path := "%s/%s.tres" % [USER_MAP_DIR, safe_name]

	DirAccess.make_dir_recursive_absolute(USER_MAP_DIR)
	var err := ResourceSaver.save(map_data, save_path)
	if err == OK:
		_status_label.text = "Saved map: %s" % save_path
	else:
		_status_label.text = "Save failed: %d" % err


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_is_painting = event.pressed
		if _is_painting:
			_paint_under_cursor()
		else:
			_last_painted = Vector2i(-1, -1)


func _process(_delta: float) -> void:
	if _is_painting:
		_paint_under_cursor()


func _populate_terrain_options() -> void:
	_terrain_option.clear()
	for option in TERRAIN_OPTIONS:
		_terrain_option.add_item(String(option["label"]))
		_terrain_option.set_item_metadata(_terrain_option.item_count - 1, int(option["id"]))
	_terrain_option.select(0)


func _on_paint_type_changed(_index: int) -> void:
	_last_painted = Vector2i(-1, -1)


func _paint_under_cursor() -> void:
	if _hex_map == null or not _hex_map.has_method("set_tile_type_at"):
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var mouse_pos := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse_pos)
	var to := from + camera.project_ray_normal(mouse_pos) * 2000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var collider := hit.get("collider") as Node
	var tile := _find_tile_node(collider)
	if tile == null:
		return
	var coord := Vector2i(tile.grid_col, tile.grid_row)
	if coord == _last_painted:
		return
	var selected := _get_selected_terrain_type()
	_hex_map.set_tile_type_at(coord.x, coord.y, selected)
	_last_painted = coord


func _find_tile_node(node: Node) -> TileBase:
	var cur := node
	while cur != null:
		if cur is TileBase:
			return cur as TileBase
		cur = cur.get_parent()
	return null


func _get_selected_terrain_type() -> int:
	var idx := _terrain_option.selected
	if idx < 0:
		return 0
	return int(_terrain_option.get_item_metadata(idx))


func _sanitize_map_name(name_text: String) -> String:
	var out := name_text.strip_edges()
	for c in INVALID_FILE_CHARS:
		out = out.replace(c, "_")
	out = out.replace(" ", "_")
	return out
