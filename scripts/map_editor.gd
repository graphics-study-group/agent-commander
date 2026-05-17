extends Node3D

const USER_MAP_DIR := "user://maps"
const INVALID_FILE_CHARS := ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
const IMPASSABLE_MOUNTAIN := 2
const IMPASSABLE_WATER := 3
const TILE_HIGHLIGHT_Y := 1.03
const LINK_HIGHLIGHT_Y := 1.05
const HOVER_ALPHA := 0.24
const DRAG_ALPHA := 0.42

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
@onready var _tile_highlight: MeshInstance3D = $HighlightRoot/TileHighlight
@onready var _link_highlight: MeshInstance3D = $HighlightRoot/LinkHighlight

var _is_painting := false
var _last_painted := Vector2i(-1, -1)
var _hover_coord := Vector2i(-1, -1)
var _hover_tile: TileBase
var _tile_highlight_material: StandardMaterial3D
var _link_highlight_material: StandardMaterial3D


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
	_setup_highlight_meshes()
	_on_generate_pressed()


func _on_generate_pressed() -> void:
	if _hex_map != null and _hex_map.has_method("regenerate_map"):
		var cols := int(_cols_spin.value)
		var rows := int(_rows_spin.value)
		var all_plain := _all_plain_check.button_pressed
		_hex_map.regenerate_map(cols, rows, all_plain)
		var mode := "All Plain" if all_plain else "Random"
		_status_label.text = "%s map generated: %dx%d" % [mode, cols, rows]
		_reset_paint_state()
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
	if event is InputEventMouseMotion:
		_update_hover_state()
		_update_highlight_visuals()


func _process(_delta: float) -> void:
	_update_hover_state()
	_update_highlight_visuals()
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
	_reset_paint_state()
	_update_editor_mode_ui()


func _on_road_setting_changed(_index: int) -> void:
	_last_painted = Vector2i(-1, -1)


func _update_editor_mode_ui() -> void:
	_road_row.visible = _get_edit_mode() == EDIT_MODE_ROAD
	_update_highlight_visuals()


func _paint_under_cursor() -> void:
	if _hover_tile == null:
		return
	var coord := _hover_coord
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


func _update_hover_state() -> void:
	var tile := _pick_tile_under_cursor()
	_hover_tile = tile
	if tile == null:
		_hover_coord = Vector2i(-1, -1)
		return
	_hover_coord = Vector2i(tile.grid_col, tile.grid_row)


func _setup_highlight_meshes() -> void:
	var tile_mesh := CylinderMesh.new()
	tile_mesh.top_radius = 0.98
	tile_mesh.bottom_radius = 0.98
	tile_mesh.height = 0.02
	tile_mesh.radial_segments = 6
	_tile_highlight.mesh = tile_mesh

	var link_mesh := BoxMesh.new()
	link_mesh.size = Vector3(0.30, 0.02, 1.0)
	_link_highlight.mesh = link_mesh

	_tile_highlight_material = _create_highlight_material()
	_link_highlight_material = _create_highlight_material()
	_tile_highlight.material_override = _tile_highlight_material
	_link_highlight.material_override = _link_highlight_material
	_tile_highlight.visible = false
	_link_highlight.visible = false


func _create_highlight_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _update_highlight_visuals() -> void:
	if _tile_highlight_material == null or _link_highlight_material == null:
		return
	if _hover_coord.x < 0:
		_hide_highlights()
		return

	var strong := _is_painting
	var color := _get_mode_highlight_color(strong)
	_tile_highlight_material.albedo_color = color
	_link_highlight_material.albedo_color = color

	var tile_world := _coord_to_world(_hover_coord)
	tile_world.y = TILE_HIGHLIGHT_Y
	_tile_highlight.visible = true
	_tile_highlight.position = tile_world
	_tile_highlight.scale = Vector3.ONE

	if _get_edit_mode() != EDIT_MODE_ROAD:
		_link_highlight.visible = false
		return

	var dir := _get_selected_road_direction()
	if dir >= 0:
		var nb := _get_neighbor_coord(_hover_coord, dir)
		if _is_coord_editable_road(_hover_coord) and _is_coord_editable_road(nb):
			_show_link_between(_hover_coord, nb)
		else:
			_link_highlight.visible = false
		return

	if not _is_painting or _last_painted.x < 0:
		_link_highlight.visible = false
		return
	if _last_painted == _hover_coord:
		_link_highlight.visible = false
		return
	if _is_adjacent(_last_painted, _hover_coord):
		_show_link_between(_last_painted, _hover_coord)
	else:
		_link_highlight.visible = false


func _show_link_between(a: Vector2i, b: Vector2i) -> void:
	var aw := _coord_to_world(a)
	var bw := _coord_to_world(b)
	aw.y = LINK_HIGHLIGHT_Y
	bw.y = LINK_HIGHLIGHT_Y
	var delta := bw - aw
	var dist := delta.length()
	if dist <= 0.001:
		_link_highlight.visible = false
		return
	_link_highlight.visible = true
	_link_highlight.position = (aw + bw) * 0.5
	_link_highlight.scale = Vector3(1.0, 1.0, dist)
	_link_highlight.look_at(bw, Vector3.UP, true)


func _hide_highlights() -> void:
	_tile_highlight.visible = false
	_link_highlight.visible = false


func _reset_paint_state() -> void:
	_is_painting = false
	_last_painted = Vector2i(-1, -1)


func _get_mode_highlight_color(strong: bool) -> Color:
	var alpha := DRAG_ALPHA if strong else HOVER_ALPHA
	if _get_edit_mode() == EDIT_MODE_ROAD:
		if _get_road_operation() == ROAD_OP_REMOVE:
			return Color(0.95, 0.28, 0.28, alpha)
		return Color(0.20, 0.90, 0.30, alpha)
	return Color(0.22, 0.58, 0.98, alpha)


func _coord_to_world(coord: Vector2i) -> Vector3:
	if _hex_map != null and _hex_map.has_method("hex_to_world"):
		return _hex_map.call("hex_to_world", coord.x, coord.y)
	return Vector3.ZERO


func _get_neighbor_coord(coord: Vector2i, dir: int) -> Vector2i:
	if _hex_map == null or not _hex_map.has_method("get_neighbor"):
		return Vector2i(-1, -1)
	return _hex_map.call("get_neighbor", coord.x, coord.y, dir)


func _is_adjacent(a: Vector2i, b: Vector2i) -> bool:
	if _hex_map == null or not _hex_map.has_method("get_direction_between"):
		return false
	var dir := int(_hex_map.call("get_direction_between", a.x, a.y, b.x, b.y))
	return dir >= 0


func _is_coord_editable_road(coord: Vector2i) -> bool:
	if not _is_in_map_bounds(coord):
		return false
	if _hex_map == null or not _hex_map.has_method("get_tile_type_at"):
		return false
	var tile_type := int(_hex_map.call("get_tile_type_at", coord.x, coord.y))
	return tile_type != IMPASSABLE_MOUNTAIN and tile_type != IMPASSABLE_WATER


func _is_in_map_bounds(coord: Vector2i) -> bool:
	if _hex_map == null or not _hex_map.has_method("get_map_size"):
		return false
	var size := _hex_map.call("get_map_size") as Vector2i
	return coord.x >= 0 and coord.y >= 0 and coord.x < size.x and coord.y < size.y


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_reset_paint_state()
		_hide_highlights()


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
