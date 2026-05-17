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

const EDIT_MODE_TERRAIN := 0
const EDIT_MODE_ROAD := 1
const ROAD_OP_ADD := 0
const ROAD_OP_REMOVE := 1

const ROAD_DIR_OPTIONS := [
	{"id": -1, "label": "Auto"},
	{"id": 0, "label": "NE(0)"},
	{"id": 1, "label": "E(1)"},
	{"id": 2, "label": "SE(2)"},
	{"id": 3, "label": "SW(3)"},
	{"id": 4, "label": "W(4)"},
	{"id": 5, "label": "NW(5)"}
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
@onready var _mode_option: OptionButton = $UILayer/EditorUI/VBox/ModeRow/ModeOption
@onready var _road_row: HBoxContainer = $UILayer/EditorUI/VBox/RoadRow
@onready var _road_op_option: OptionButton = $UILayer/EditorUI/VBox/RoadRow/RoadOpOption
@onready var _road_dir_option: OptionButton = $UILayer/EditorUI/VBox/RoadRow/RoadDirOption

var _is_painting := false
var _last_painted := Vector2i(-1, -1)


func _ready() -> void:
	_regen_btn.pressed.connect(_on_generate_pressed)
	_save_btn.pressed.connect(_on_save_pressed)
	_terrain_option.item_selected.connect(_on_paint_type_changed)
	_mode_option.item_selected.connect(_on_mode_changed)
	_road_op_option.item_selected.connect(_on_road_setting_changed)
	_road_dir_option.item_selected.connect(_on_road_setting_changed)
	_populate_terrain_options()
	_populate_mode_options()
	_populate_road_options()
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


func _populate_mode_options() -> void:
	_mode_option.clear()
	_mode_option.add_item("Terrain")
	_mode_option.set_item_metadata(0, EDIT_MODE_TERRAIN)
	_mode_option.add_item("Road")
	_mode_option.set_item_metadata(1, EDIT_MODE_ROAD)
	_mode_option.select(0)
	_update_editor_mode_ui()


func _populate_road_options() -> void:
	_road_op_option.clear()
	_road_op_option.add_item("Add")
	_road_op_option.set_item_metadata(0, ROAD_OP_ADD)
	_road_op_option.add_item("Remove")
	_road_op_option.set_item_metadata(1, ROAD_OP_REMOVE)
	_road_op_option.select(0)

	_road_dir_option.clear()
	for option in ROAD_DIR_OPTIONS:
		_road_dir_option.add_item(String(option["label"]))
		_road_dir_option.set_item_metadata(_road_dir_option.item_count - 1, int(option["id"]))
	_road_dir_option.select(0)


func _on_paint_type_changed(_index: int) -> void:
	_last_painted = Vector2i(-1, -1)


func _on_mode_changed(_index: int) -> void:
	_last_painted = Vector2i(-1, -1)
	_update_editor_mode_ui()


func _on_road_setting_changed(_index: int) -> void:
	_last_painted = Vector2i(-1, -1)


func _update_editor_mode_ui() -> void:
	_road_row.visible = _get_edit_mode() == EDIT_MODE_ROAD


func _paint_under_cursor() -> void:
	var tile := _pick_tile_under_cursor()
	if tile == null:
		return
	var coord := Vector2i(tile.grid_col, tile.grid_row)
	if _get_edit_mode() == EDIT_MODE_ROAD:
		_paint_road_at(coord)
	else:
		_paint_terrain_at(coord)


func _paint_terrain_at(coord: Vector2i) -> void:
	if _hex_map == null or not _hex_map.has_method("set_tile_type_at"):
		return
	if coord == _last_painted:
		return
	var selected := _get_selected_terrain_type()
	_hex_map.set_tile_type_at(coord.x, coord.y, selected)
	_last_painted = coord


func _paint_road_at(coord: Vector2i) -> void:
	if _hex_map == null or not _hex_map.has_method("set_road_at"):
		return
	var enabled := _get_road_operation() == ROAD_OP_ADD
	var selected_dir := _get_selected_road_direction()

	if selected_dir >= 0:
		if coord == _last_painted:
			return
		_hex_map.set_road_at(coord.x, coord.y, selected_dir, enabled)
		_last_painted = coord
		return

	if _last_painted.x < 0:
		_last_painted = coord
		return
	if coord == _last_painted:
		return
	if _hex_map.has_method("get_direction_between"):
		var dir := int(_hex_map.call("get_direction_between", _last_painted.x, _last_painted.y, coord.x, coord.y))
		if dir >= 0:
			_hex_map.set_road_at(_last_painted.x, _last_painted.y, dir, enabled)
	_last_painted = coord


func _pick_tile_under_cursor() -> TileBase:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return null
	var mouse_pos := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse_pos)
	var to := from + camera.project_ray_normal(mouse_pos) * 2000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	var collider := hit.get("collider") as Node
	return _find_tile_node(collider)


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


func _get_edit_mode() -> int:
	var idx := _mode_option.selected
	if idx < 0:
		return EDIT_MODE_TERRAIN
	return int(_mode_option.get_item_metadata(idx))


func _get_road_operation() -> int:
	var idx := _road_op_option.selected
	if idx < 0:
		return ROAD_OP_ADD
	return int(_road_op_option.get_item_metadata(idx))


func _get_selected_road_direction() -> int:
	var idx := _road_dir_option.selected
	if idx < 0:
		return -1
	return int(_road_dir_option.get_item_metadata(idx))


func _sanitize_map_name(name_text: String) -> String:
	var out := name_text.strip_edges()
	for c in INVALID_FILE_CHARS:
		out = out.replace(c, "_")
	out = out.replace(" ", "_")
	return out
