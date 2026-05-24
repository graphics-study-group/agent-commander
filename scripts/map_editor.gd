extends Node3D

const DeepSeekAPIScript = preload("res://scripts/deepseek_api.gd")
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

const _REGION_RENAME_TOOL: Dictionary = {
	"type": "function",
	"function": {
		"name": "name_point",
		"description": "为地图上某个格子打上地名标记（山口、渡口、高地、城镇等）。每次调用只标记一个坐标。",
		"parameters": {
			"type": "object",
			"properties": {
				"col":  {"type": "integer", "description": "目标列"},
				"row":  {"type": "integer", "description": "目标行"},
				"name": {"type": "string",  "description": "地名（2-6字，体现地形或军事意义）"}
			},
			"required": ["col", "row", "name"]
		}
	}
}

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
var _name_regions_btn: Button = null
var _region_vbox: VBoxContainer = null
var _file_dialog: FileDialog = null
var _style_hint_edit: LineEdit = null
var _player_count_spin: SpinBox = null
var _enemy_count_spin: SpinBox = null


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
	_build_extra_ui()
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
	if _name_regions_btn != null:
		_name_regions_btn.disabled = false
		_name_regions_btn.text = "AI: Name Points"
	_refresh_region_edit_list()


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


func _build_extra_ui() -> void:
	var vbox: VBoxContainer = $UILayer/EditorUI/VBox

	# Back to main scene button at top
	var back_btn := Button.new()
	back_btn.text = "← Main"
	back_btn.pressed.connect(func():
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	)
	vbox.add_child(back_btn)
	vbox.move_child(back_btn, 0)

	# Unit count row — inserted after SizeRow
	var unit_row := HBoxContainer.new()
	var pl_lbl := Label.new()
	pl_lbl.text = "玩家军队:"
	unit_row.add_child(pl_lbl)
	_player_count_spin = SpinBox.new()
	_player_count_spin.min_value = 1
	_player_count_spin.max_value = 5
	_player_count_spin.value = _hex_map.player_unit_count if _hex_map != null else 2
	_player_count_spin.custom_minimum_size = Vector2(70, 0)
	_player_count_spin.value_changed.connect(func(v: float):
		if _hex_map != null:
			_hex_map.player_unit_count = int(v)
	)
	unit_row.add_child(_player_count_spin)
	var en_lbl := Label.new()
	en_lbl.text = "  敌方军队:"
	unit_row.add_child(en_lbl)
	_enemy_count_spin = SpinBox.new()
	_enemy_count_spin.min_value = 1
	_enemy_count_spin.max_value = 5
	_enemy_count_spin.value = _hex_map.enemy_unit_count if _hex_map != null else 2
	_enemy_count_spin.custom_minimum_size = Vector2(70, 0)
	_enemy_count_spin.value_changed.connect(func(v: float):
		if _hex_map != null:
			_hex_map.enemy_unit_count = int(v)
	)
	unit_row.add_child(_enemy_count_spin)
	vbox.add_child(unit_row)
	var size_row_idx := $UILayer/EditorUI/VBox/SizeRow.get_index()
	vbox.move_child(unit_row, size_row_idx + 1)

	# Load button added to SaveRow alongside Save
	var load_btn := Button.new()
	load_btn.text = "Load..."
	load_btn.pressed.connect(_on_load_btn_pressed)
	$UILayer/EditorUI/VBox/SaveRow.add_child(load_btn)

	# Style hint row and Name Regions button — placed after GenerateButton
	var style_row := HBoxContainer.new()
	var style_lbl := Label.new()
	style_lbl.text = "Style:"
	style_row.add_child(style_lbl)
	_style_hint_edit = LineEdit.new()
	_style_hint_edit.placeholder_text = "命名风格示例 (可留空)"
	_style_hint_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_row.add_child(_style_hint_edit)
	vbox.add_child(style_row)

	_name_regions_btn = Button.new()
	_name_regions_btn.text = "AI: Name Points"
	_name_regions_btn.disabled = true
	_name_regions_btn.pressed.connect(_on_name_regions_pressed)
	vbox.add_child(_name_regions_btn)

	var gen_idx := _regen_btn.get_index()
	vbox.move_child(style_row, gen_idx + 1)
	vbox.move_child(_name_regions_btn, gen_idx + 2)

	# Region editing section at bottom
	var sep := HSeparator.new()
	vbox.add_child(sep)
	var region_title := Label.new()
	region_title.text = "Named Points"
	vbox.add_child(region_title)
	var region_scroll := ScrollContainer.new()
	region_scroll.custom_minimum_size = Vector2(0, 150)
	region_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(region_scroll)
	_region_vbox = VBoxContainer.new()
	_region_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	region_scroll.add_child(_region_vbox)

	# File dialog for loading saved maps
	_file_dialog = FileDialog.new()
	_file_dialog.title = "Load Map"
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_USERDATA
	_file_dialog.add_filter("*.tres", "Map Files")
	_file_dialog.file_selected.connect(_on_file_selected)
	_file_dialog.min_size = Vector2(500, 400)
	add_child(_file_dialog)


func _on_load_btn_pressed() -> void:
	DirAccess.make_dir_recursive_absolute(USER_MAP_DIR)
	_file_dialog.current_dir = "maps"
	_file_dialog.popup_centered()


func _on_file_selected(path: String) -> void:
	if _hex_map == null or not _hex_map.has_method("load_map_from_path"):
		_status_label.text = "Hex map missing load API."
		return
	if _hex_map.load_map_from_path(path):
		var fname: String = path.get_file().get_basename()
		_name_edit.text = fname
		_status_label.text = "Loaded: " + fname
		if _name_regions_btn != null:
			_name_regions_btn.disabled = false
			_name_regions_btn.text = "AI: Name Regions"
		_reset_paint_state()
		_refresh_region_edit_list()
		if _player_count_spin != null:
			_player_count_spin.value = _hex_map.player_unit_count
		if _enemy_count_spin != null:
			_enemy_count_spin.value = _hex_map.enemy_unit_count
	else:
		_status_label.text = "Failed to load: " + path.get_file()


func _on_name_regions_pressed() -> void:
	if _hex_map == null:
		return
	if _hex_map.has_method("clear_region_names"):
		_hex_map.clear_region_names()
	_refresh_region_edit_list()
	_name_regions_btn.disabled = true
	_name_regions_btn.text = "AI: Naming..."
	_do_region_naming()


func _do_region_naming() -> void:
	var api: Node = DeepSeekAPIScript.new()
	add_child(api)
	api.tools = [_REGION_RENAME_TOOL]

	var map_size: Vector2i = _hex_map.get_map_size() if _hex_map.has_method("get_map_size") else Vector2i(16, 16)
	var suggested_count := clampi(int(sqrt(float(map_size.x * map_size.y)) * 1.25), 4, 60)
	var candidates := _pick_naming_candidates(map_size, suggested_count)
	var points_desc := _build_points_description(candidates)

	var style_hint := _style_hint_edit.text.strip_edges() if _style_hint_edit != null else ""
	var style_part := "命名风格参考：「%s」。" % style_hint if not style_hint.is_empty() else ""

	api.set_system_prompt(
		"你是战场地图标注官。用户会发来若干坐标及其地形，请为每个坐标起一个地名（2-6字）并用name_point工具标记。"
		+ "要求：地名须与该格本身地形相符；平原/树林/山地/水域格严禁含「城」字；城市格可含城/镇/堡等。"
		+ "完成所有标注后输出一句20字内总结。")

	api.tool_calls_received.connect(func(calls: Array):
		var results: Array = []
		for call: Dictionary in calls:
			var fn: Dictionary = call.get("function", {})
			var j := JSON.new()
			var args: Dictionary = {}
			if j.parse(fn.get("arguments", "{}")) == OK and j.get_data() is Dictionary:
				args = j.get_data()
			if fn.get("name", "") == "name_point" and _hex_map.has_method("name_point"):
				_hex_map.name_point(int(args.get("col", 0)), int(args.get("row", 0)), args.get("name", ""))
			results.append({
				"role": "tool",
				"tool_call_id": call.get("id", ""),
				"name": fn.get("name", ""),
				"content": "{\"ok\":true}"
			})
		api.send_tool_results(results)
	)

	api.response_received.connect(func(content: String):
		_status_label.text = content.left(80)
		if _name_regions_btn != null:
			_name_regions_btn.text = "AI: Re-name"
			_name_regions_btn.disabled = false
		_refresh_region_edit_list()
		api.queue_free()
	)

	api.request_failed.connect(func(err: String):
		_status_label.text = "Naming failed: " + err
		if _name_regions_btn != null:
			_name_regions_btn.text = "AI: Name Points"
			_name_regions_btn.disabled = false
		api.queue_free()
	)

	api.send_message(points_desc + "\n\n请用name_point为以上每个坐标命名。" + style_part)


func _pick_naming_candidates(map_size: Vector2i, count: int) -> Array:
	var all_cells: Array = []
	for r in range(map_size.y):
		for c in range(map_size.x):
			all_cells.append(Vector2i(c, r))
	all_cells.shuffle()
	var min_dist := maxf(2.0, sqrt(float(map_size.x * map_size.y)) / float(count + 1))
	var result: Array = []
	for pos: Vector2i in all_cells:
		var ok := true
		for sel: Vector2i in result:
			var dx := float(pos.x - sel.x)
			var dy := float(pos.y - sel.y)
			if sqrt(dx * dx + dy * dy) < min_dist:
				ok = false
				break
		if ok:
			result.append(pos)
			if result.size() >= count:
				break
	return result


func _build_points_description(candidates: Array) -> String:
	var terrain_names := ["平原", "树林", "山地", "水域", "城市"]
	var dir_names := ["东北", "东", "东南", "西南", "西", "西北"]
	var lines: Array = ["需要命名的 %d 个地点：" % candidates.size()]
	for pos: Vector2i in candidates:
		var t := int(_hex_map.get_tile_type_at(pos.x, pos.y))
		var tname: String = terrain_names[clampi(t, 0, 4)]
		var nb_strs: Array = []
		for dir in range(6):
			var nb: Vector2i = _hex_map.get_neighbor(pos.x, pos.y, dir)
			if _is_in_map_bounds(nb):
				var nt := int(_hex_map.get_tile_type_at(nb.x, nb.y))
				nb_strs.append(dir_names[dir] + terrain_names[clampi(nt, 0, 4)])
			else:
				nb_strs.append(dir_names[dir] + "边界")
		lines.append("(%d,%d) 本格：%s  四周：%s" % [pos.x, pos.y, tname, " ".join(nb_strs)])
	return "\n".join(lines)


func _refresh_region_edit_list() -> void:
	if _region_vbox == null:
		return
	for child in _region_vbox.get_children():
		child.queue_free()
	if _hex_map == null or not _hex_map.has_method("get_named_points"):
		return

	var points: Array = _hex_map.get_named_points()
	if not points.is_empty():
		for pt: Dictionary in points:
			var cap_col: int = pt["col"]
			var cap_row: int = pt["row"]
			var cap_name: String = pt["name"]

			var hbox := HBoxContainer.new()
			var coord_lbl := Label.new()
			coord_lbl.text = "(%d,%d)" % [cap_col, cap_row]
			coord_lbl.custom_minimum_size = Vector2(52, 0)
			var name_edit := LineEdit.new()
			name_edit.text = cap_name
			name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var apply_btn := Button.new()
			apply_btn.text = "✓"
			apply_btn.custom_minimum_size = Vector2(28, 0)
			apply_btn.pressed.connect(func():
				var new_name := name_edit.text.strip_edges() if is_instance_valid(name_edit) else ""
				if not new_name.is_empty():
					_hex_map.name_point(cap_col, cap_row, new_name)
					_status_label.text = "(%d,%d) -> %s" % [cap_col, cap_row, new_name]
					_refresh_region_edit_list()
			)
			var del_btn := Button.new()
			del_btn.text = "✗"
			del_btn.custom_minimum_size = Vector2(28, 0)
			del_btn.pressed.connect(func():
				_hex_map.name_point(cap_col, cap_row, "")
				_status_label.text = "Deleted: %s" % cap_name
				_refresh_region_edit_list()
			)
			hbox.add_child(coord_lbl)
			hbox.add_child(name_edit)
			hbox.add_child(apply_btn)
			hbox.add_child(del_btn)
			_region_vbox.add_child(hbox)

	# Add-point row at bottom
	var sep2 := HSeparator.new()
	_region_vbox.add_child(sep2)
	var add_hbox := HBoxContainer.new()
	var col_spin := SpinBox.new()
	col_spin.min_value = 0
	col_spin.max_value = 127
	col_spin.prefix = "C:"
	col_spin.custom_minimum_size = Vector2(62, 0)
	var row_spin := SpinBox.new()
	row_spin.min_value = 0
	row_spin.max_value = 127
	row_spin.prefix = "R:"
	row_spin.custom_minimum_size = Vector2(62, 0)
	var add_name := LineEdit.new()
	add_name.placeholder_text = "地名"
	add_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var add_btn := Button.new()
	add_btn.text = "+"
	add_btn.custom_minimum_size = Vector2(28, 0)
	add_btn.pressed.connect(func():
		if not is_instance_valid(col_spin):
			return
		var col := int(col_spin.value)
		var row := int(row_spin.value)
		var pname := add_name.text.strip_edges() if is_instance_valid(add_name) else ""
		if not pname.is_empty() and _hex_map != null and _hex_map.has_method("name_point"):
			_hex_map.name_point(col, row, pname)
			_status_label.text = "Added: (%d,%d) %s" % [col, row, pname]
			_refresh_region_edit_list()
	)
	add_hbox.add_child(col_spin)
	add_hbox.add_child(row_spin)
	add_hbox.add_child(add_name)
	add_hbox.add_child(add_btn)
	_region_vbox.add_child(add_hbox)
