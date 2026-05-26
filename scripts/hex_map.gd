extends Node3D

const GRID_COLS := 16
const GRID_ROWS := 16
const H_STEP := 1.732
const V_STEP := 1.5
const ROW_OFFSET := 0.866

const HEX_DIST_KM := 40.0
const ASTAR_GRASS := 10.0
const ASTAR_ROAD := 5.0

enum Terrain { PLAIN, FOREST, MOUNTAIN, WATER, CITY }

const OFFSETS_EVEN := [[0, -1], [1, 0], [0, 1], [-1, 1], [-1, 0], [-1, -1]]
const OFFSETS_ODD := [[1, -1], [1, 0], [1, 1], [0, 1], [-1, 0], [0, -1]]

const TILE_SCENE_PLAIN := preload("res://scenes/tiles/PlainTile.tscn")
const TILE_SCENE_FOREST := preload("res://scenes/tiles/ForestTile.tscn")
const TILE_SCENE_MOUNTAIN := preload("res://scenes/tiles/MountainTile.tscn")
const TILE_SCENE_WATER := preload("res://scenes/tiles/WaterTile.tscn")
const TILE_SCENE_CITY := preload("res://scenes/tiles/CityTile.tscn")
const UNIT_MARKER_SCENE := preload("res://scenes/units/UnitMarker.tscn")
const SUPPLY_MARKER_SCENE := preload("res://scenes/units/SupplyMarker.tscn")

@export var auto_generate_on_ready := true
@export_file("*.tres", "*.res") var startup_map_path := ""

var _grid_cols := GRID_COLS
var _grid_rows := GRID_ROWS
var _terrain: Array = []
var _roads: Array = []
var _tile_nodes: Array = []
var _spawn_col := 8
var _spawn_row := 8
var player_unit_count: int = 2
var enemy_unit_count: int = 2

# unit_name → {unit, col, row, color, marker_root, move_queue, current_tween,
#              is_moving, speed_buff_kmh, speed_buff_hexes}
var _units: Dictionary = {}
var _frozen_units: Dictionary = {}  # unit_name → true (blocks movement while in battle)
var _unit_templates: Array = []     # Array[Dictionary] — initial unit configs saved with map

# _cell_region[row][col] = region name string, "" = unnamed
var _cell_region: Array = []
var _region_labels_root: Node3D = null

var _generated_root: Node3D
var _tooltip_canvas: CanvasLayer
var _tooltip: PanelContainer
var _tooltip_label: RichTextLabel

signal movement_finished(unit_name: String)
signal hex_coord_selected(col: int, row: int)
signal unit_collision(mover_name: String, resident_name: String)

var _hovered_hex: Vector2i = Vector2i(-1, -1)
var _hover_highlight: MeshInstance3D
var _hover_label: Label3D
var _highlight_mat: StandardMaterial3D

var debug_mode: bool = false
var _unit_debug_texts: Dictionary = {}  # unit_name → queue string

var _victory_city: Vector2i = Vector2i(-1, -1)
var _victory_city_marker: Node3D = null

var _convoy_markers: Dictionary = {}  # convoy_id → Node3D marker_root


func _ready() -> void:
	add_to_group("hex_map")
	if auto_generate_on_ready:
		if not startup_map_path.is_empty():
			if not load_map_from_path(startup_map_path):
				regenerate_random_map()
		else:
			regenerate_random_map()
	call_deferred("_init_refs")


func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		if _tooltip != null:
			_tooltip.visible = false
		return
	var mouse_pos := get_viewport().get_mouse_position()

	# Unit tooltip
	if _tooltip != null:
		var closest_unit: Unit = null
		var closest_dist := 60.0
		for unit_name: String in _units:
			var d: Dictionary = _units[unit_name]
			var mr: Node3D = d.get("marker_root")
			if not is_instance_valid(mr):
				continue
			var screen_pos := camera.unproject_position(mr.global_position + Vector3(0, 1.5, 0))
			var dist := screen_pos.distance_to(mouse_pos)
			if dist < closest_dist:
				closest_dist = dist
				closest_unit = d.get("unit") as Unit
		if closest_unit != null:
			_tooltip.visible = true
			var text := closest_unit.get_display_text()
			if debug_mode and _unit_debug_texts.has(closest_unit.unit_name):
				text += "\n[color=gray]【队列】%s[/color]" % _unit_debug_texts[closest_unit.unit_name]
			_tooltip_label.text = text
			var vp := get_viewport().get_visible_rect().size
			var tp := Vector2(mouse_pos.x + 14.0, mouse_pos.y - _tooltip.size.y - 8.0)
			tp.x = clamp(tp.x, 4.0, vp.x - _tooltip.size.x - 4.0)
			tp.y = clamp(tp.y, 4.0, vp.y - _tooltip.size.y - 4.0)
			_tooltip.position = tp
		else:
			_tooltip.visible = false

	# Hex hover: update hovered cell via tile collision picking
	if _hover_highlight != null:
		var tile := _pick_tile_under_cursor()
		if tile != null and _in_bounds(tile.grid_col, tile.grid_row):
			_hovered_hex = Vector2i(tile.grid_col, tile.grid_row)
			var wpos := hex_to_world(tile.grid_col, tile.grid_row)
			_hover_highlight.position = Vector3(wpos.x, 1.03, wpos.z)
			_hover_highlight.visible = true
			_hover_label.text = "(%d,%d)" % [tile.grid_col, tile.grid_row]
			_hover_label.position = Vector3(wpos.x, 1.7, wpos.z)
			_hover_label.visible = true
		else:
			_hovered_hex = Vector2i(-1, -1)
			_hover_highlight.visible = false
			_hover_label.visible = false


func _exit_tree() -> void:
	if is_instance_valid(_tooltip_canvas):
		_tooltip_canvas.queue_free()


func _init_refs() -> void:
	_create_tooltip()
	_create_hover_overlay()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			var tile := _pick_tile_under_cursor()
			if tile != null and _in_bounds(tile.grid_col, tile.grid_row):
				_hovered_hex = Vector2i(tile.grid_col, tile.grid_row)
				hex_coord_selected.emit(tile.grid_col, tile.grid_row)


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


# ── Unit registration ─────────────────────────────────────────────────────────

func register_unit(unit: Unit, color: Color = Color(0.25, 0.55, 1.0),
		preferred_col: int = -1, preferred_row: int = -1,
		is_enemy: bool = false) -> void:
	if unit == null:
		return
	var col := preferred_col
	var row := preferred_row
	if col < 0 or row < 0 or not _in_bounds(col, row) or _is_impassable(_terrain[row][col]):
		var sp := _find_start_pos(preferred_col, preferred_row)
		col = sp.x
		row = sp.y
	var m := _create_unit_marker_node(unit.unit_name, col, row, color, is_enemy)
	if m.is_empty():
		push_warning("HexMap: failed to create marker for %s" % unit.unit_name)
		return
	var marker_node: Node3D = m.get("marker_root") as Node3D
	_units[unit.unit_name] = {
		"unit": unit,
		"col": col,
		"row": row,
		"color": color,
		"is_enemy": is_enemy,
		"marker_root": marker_node,
		"move_queue": [],
		"current_tween": null,
		"is_moving": false,
		"speed_buff_kmh": 0.0,
		"speed_buff_hexes": 0
	}
	update_unit_org(unit.unit_name, unit.ORG)


# ── Map generation / load / save ──────────────────────────────────────────────

func regenerate_random_map() -> void:
	regenerate_map(GRID_COLS, GRID_ROWS, false)


func regenerate_map(cols: int, rows: int, all_plain: bool = false) -> void:
	_grid_cols = maxi(cols, 1)
	_grid_rows = maxi(rows, 1)
	if all_plain:
		_generate_plain_terrain()
		_generate_empty_roads()
	else:
		_generate_terrain()
		_generate_roads()
	var sp := _find_start_pos()
	_spawn_col = sp.x
	_spawn_row = sp.y
	_init_cell_region()
	_rebuild_visuals()


func load_map_from_path(path: String) -> bool:
	var loaded := ResourceLoader.load(path)
	if loaded == null:
		push_warning("Map resource not found: %s" % path)
		return false
	if not (loaded is MapData):
		push_warning("Resource is not MapData: %s" % path)
		return false
	return load_map_data(loaded as MapData)


func load_map_data(data: MapData) -> bool:
	if data == null:
		return false
	var validation_error := data.validate()
	if not validation_error.is_empty():
		push_warning("Invalid map data: %s" % validation_error)
		return false

	_grid_cols = data.cols
	_grid_rows = data.rows
	_roads = _copy_grid(data.roads)

	var legacy_terrain := data.tile_types.is_empty() and data.version <= 1
	_terrain = _normalize_tile_grid(data.get_tile_types_grid(), legacy_terrain)

	_spawn_col = data.spawn_col
	_spawn_row = data.spawn_row
	if _is_impassable(_terrain[_spawn_row][_spawn_col]):
		var sp := _find_start_pos()
		_spawn_col = sp.x
		_spawn_row = sp.y

	# Reposition any registered units that landed on impassable terrain
	for unit_name: String in _units:
		var d: Dictionary = _units[unit_name]
		if _is_impassable(_terrain[int(d["row"])][int(d["col"])]):
			d["col"] = _spawn_col
			d["row"] = _spawn_row

	_init_cell_region()
	if data.cell_region.size() == _grid_rows:
		_cell_region = _copy_grid(data.cell_region)
	player_unit_count = data.player_unit_count
	enemy_unit_count  = data.enemy_unit_count
	_victory_city = Vector2i(data.victory_city_col, data.victory_city_row)
	_unit_templates = data.unit_templates.duplicate(true)
	_rebuild_visuals()
	return true


func export_map_data() -> MapData:
	var data := MapData.new()
	data.version = 3
	data.cols = _grid_cols
	data.rows = _grid_rows
	data.set_tile_types_grid(_terrain)
	data.roads = _copy_grid(_roads)
	data.spawn_col = _spawn_col
	data.spawn_row = _spawn_row
	data.player_unit_count = player_unit_count
	data.enemy_unit_count  = enemy_unit_count
	if not _cell_region.is_empty():
		data.cell_region = _copy_grid(_cell_region)
	data.victory_city_col = _victory_city.x
	data.victory_city_row = _victory_city.y
	data.unit_templates = _unit_templates.duplicate(true)
	return data


func _copy_grid(src: Array) -> Array:
	var out: Array = []
	for row in src:
		out.append((row as Array).duplicate())
	return out


func _normalize_tile_grid(src: Array, legacy_terrain: bool) -> Array:
	var out: Array = []
	for row in src:
		var converted_row: Array = []
		for raw_value in row:
			converted_row.append(_normalize_tile_value(int(raw_value), legacy_terrain))
		out.append(converted_row)
	return out


func _normalize_tile_value(v: int, legacy_terrain: bool) -> int:
	if legacy_terrain:
		match v:
			0:
				return Terrain.PLAIN
			1:
				return Terrain.MOUNTAIN
			2:
				return Terrain.WATER
			_:
				return Terrain.PLAIN
	return clamp(v, 0, 4)


func _rebuild_visuals() -> void:
	_region_labels_root = null  # freed with _generated_root below
	_clear_generated_root()
	_generate_tiles()
	_recreate_all_markers()
	_create_coord_labels()
	refresh_region_labels()
	_rebuild_victory_marker()
	_enable_shadows_on_subtree(_generated_root)


func _clear_generated_root() -> void:
	if is_instance_valid(_generated_root):
		_generated_root.queue_free()
	_generated_root = Node3D.new()
	_generated_root.name = "GeneratedMap"
	add_child(_generated_root)
	_tile_nodes = []


func _enable_shadows_on_subtree(root_node: Node) -> void:
	if not is_instance_valid(root_node):
		return
	var stack: Array = [root_node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D:
			(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		for c in n.get_children():
			if c is Node:
				stack.append(c)


func _generate_terrain() -> void:
	_terrain.resize(_grid_rows)
	for r in range(_grid_rows):
		_terrain[r] = []
		_terrain[r].resize(_grid_cols)
		for c in range(_grid_cols):
			var v := randf()
			if v < 0.52:
				_terrain[r][c] = Terrain.PLAIN
			elif v < 0.74:
				_terrain[r][c] = Terrain.FOREST
			elif v < 0.86:
				_terrain[r][c] = Terrain.MOUNTAIN
			elif v < 0.96:
				_terrain[r][c] = Terrain.WATER
			else:
				_terrain[r][c] = Terrain.CITY


func _generate_plain_terrain() -> void:
	_terrain.resize(_grid_rows)
	for r in range(_grid_rows):
		_terrain[r] = []
		_terrain[r].resize(_grid_cols)
		for c in range(_grid_cols):
			_terrain[r][c] = Terrain.PLAIN


func _find_start_pos(pref_col: int = -1, pref_row: int = -1) -> Vector2i:
	var tc := pref_col if pref_col >= 0 else _grid_cols / 2
	var tr := pref_row if pref_row >= 0 else _grid_rows / 2
	var best_dist := INF
	var best := Vector2i(tc, tr)
	for r in range(_grid_rows):
		for c in range(_grid_cols):
			if not _is_impassable(_terrain[r][c]):
				var d := _hex_dist(c, r, tc, tr)
				if d < best_dist:
					best_dist = d
					best = Vector2i(c, r)
	return best


func _generate_roads() -> void:
	_roads.resize(_grid_rows)
	for r in range(_grid_rows):
		_roads[r] = []
		_roads[r].resize(_grid_cols)
		for c in range(_grid_cols):
			_roads[r][c] = 0

	# Collect all city positions
	var cities: Array = []
	for r in range(_grid_rows):
		for c in range(_grid_cols):
			if _terrain[r][c] == Terrain.CITY:
				cities.append(Vector2i(c, r))

	# Connect cities with a greedy spanning tree (nearest unconnected city next)
	if cities.size() >= 2:
		var connected: Array = [cities[0]]
		var remaining: Array = cities.slice(1)
		while not remaining.is_empty():
			var best_from: Vector2i = connected[0]
			var best_to: Vector2i = remaining[0]
			var best_dist := INF
			for from: Vector2i in connected:
				for to: Vector2i in remaining:
					var d := _hex_dist(from.x, from.y, to.x, to.y)
					if d < best_dist:
						best_dist = d
						best_from = from
						best_to = to
			var path := _astar(best_from.x, best_from.y, best_to.x, best_to.y)
			if not path.is_empty():
				_mark_path_as_road(best_from, path)
			remaining.erase(best_to)
			connected.append(best_to)

	# Sparse random segments for texture
	_add_random_road_segments(_grid_cols * _grid_rows / 8)


func _mark_path_as_road(start: Vector2i, path: Array) -> void:
	var prev := start
	for step in path:
		var cur := Vector2i(int(step[0]), int(step[1]))
		var dir := _get_direction(prev.x, prev.y, cur.x, cur.y)
		if dir >= 0:
			_roads[prev.y][prev.x] |= (1 << dir)
			_roads[cur.y][cur.x] |= (1 << ((dir + 3) % 6))
		prev = cur


func _add_random_road_segments(count: int) -> void:
	for _i in range(count):
		var col := randi() % _grid_cols
		var row := randi() % _grid_rows
		if _is_impassable(_terrain[row][col]):
			continue
		var dir := randi() % 6
		var nb := get_neighbor(col, row, dir)
		if not _in_bounds(nb.x, nb.y):
			continue
		if _is_impassable(_terrain[nb.y][nb.x]):
			continue
		_roads[row][col] |= (1 << dir)
		_roads[nb.y][nb.x] |= (1 << ((dir + 3) % 6))


func _generate_empty_roads() -> void:
	_roads.resize(_grid_rows)
	for r in range(_grid_rows):
		_roads[r] = []
		_roads[r].resize(_grid_cols)
		for c in range(_grid_cols):
			_roads[r][c] = 0


func _is_impassable(tile_type: int) -> bool:
	return tile_type == Terrain.MOUNTAIN or tile_type == Terrain.WATER


func hex_to_world(col: int, row: int) -> Vector3:
	var cx := (_grid_cols - 1) * H_STEP * 0.5
	var cz := (_grid_rows - 1) * V_STEP * 0.5
	var x := col * H_STEP + (ROW_OFFSET if row % 2 == 1 else 0.0) - cx
	var z := row * V_STEP - cz
	return Vector3(x, 0.0, z)


func get_neighbor(col: int, row: int, dir: int) -> Vector2i:
	var off: Array = OFFSETS_ODD[dir] if row % 2 == 1 else OFFSETS_EVEN[dir]
	return Vector2i(col + int(off[0]), row + int(off[1]))


func _in_bounds(col: int, row: int) -> bool:
	return col >= 0 and col < _grid_cols and row >= 0 and row < _grid_rows


func get_tile_type_at(col: int, row: int) -> int:
	if not _in_bounds(col, row):
		return -1
	return int(_terrain[row][col])


func get_road_mask_at(col: int, row: int) -> int:
	if not _in_bounds(col, row):
		return 0
	return int(_roads[row][col])


func set_road_at(col: int, row: int, direction: int, enabled: bool) -> bool:
	if not _in_bounds(col, row):
		return false
	if direction < 0 or direction > 5:
		return false
	var nb := get_neighbor(col, row, direction)
	if not _in_bounds(nb.x, nb.y):
		return false
	if _is_impassable(_terrain[row][col]) or _is_impassable(_terrain[nb.y][nb.x]):
		return false
	var opposite := (direction + 3) % 6
	var old_mask := int(_roads[row][col])
	var old_nb_mask := int(_roads[nb.y][nb.x])
	if enabled:
		_roads[row][col] = old_mask | (1 << direction)
		_roads[nb.y][nb.x] = old_nb_mask | (1 << opposite)
	else:
		_roads[row][col] = old_mask & ~(1 << direction)
		_roads[nb.y][nb.x] = old_nb_mask & ~(1 << opposite)
	if int(_roads[row][col]) == old_mask and int(_roads[nb.y][nb.x]) == old_nb_mask:
		return false
	_refresh_tile_and_neighbors(col, row)
	_refresh_tile_and_neighbors(nb.x, nb.y)
	return true


func get_direction_between(fc: int, fr: int, tc: int, tr: int) -> int:
	if not _in_bounds(fc, fr) or not _in_bounds(tc, tr):
		return -1
	return _get_direction(fc, fr, tc, tr)


func set_tile_type_at(col: int, row: int, tile_type: int) -> bool:
	if not _in_bounds(col, row):
		return false
	var normalized_type := clampi(tile_type, Terrain.PLAIN, Terrain.CITY)
	if int(_terrain[row][col]) == normalized_type:
		return false
	_terrain[row][col] = normalized_type
	for unit_name: String in _units:
		var d: Dictionary = _units[unit_name]
		if _is_impassable(_terrain[int(d["row"])][int(d["col"])]):
			var sp := _find_start_pos()
			d["col"] = sp.x
			d["row"] = sp.y
			_update_marker_pos_for(unit_name)
	_replace_tile_node(col, row)
	_refresh_tile_and_neighbors(col, row)
	return true


func get_map_size() -> Vector2i:
	return Vector2i(_grid_cols, _grid_rows)


func _get_direction(fc: int, fr: int, tc: int, tr: int) -> int:
	var off: Array = OFFSETS_ODD if fr % 2 == 1 else OFFSETS_EVEN
	for d in range(6):
		var entry: Array = off[d]
		if fc + int(entry[0]) == tc and fr + int(entry[1]) == tr:
			return d
	return -1


func _get_tile_scene(tile_type: int) -> PackedScene:
	match tile_type:
		Terrain.FOREST:
			return TILE_SCENE_FOREST
		Terrain.MOUNTAIN:
			return TILE_SCENE_MOUNTAIN
		Terrain.WATER:
			return TILE_SCENE_WATER
		Terrain.CITY:
			return TILE_SCENE_CITY
		_:
			return TILE_SCENE_PLAIN


func _generate_tiles() -> void:
	_tile_nodes.resize(_grid_rows)
	for row in range(_grid_rows):
		_tile_nodes[row] = []
		_tile_nodes[row].resize(_grid_cols)
		for col in range(_grid_cols):
			var tile_scene := _get_tile_scene(_terrain[row][col])
			var tile := tile_scene.instantiate() as TileBase
			if tile == null:
				continue
			tile.position = hex_to_world(col, row)
			tile.configure(col, row, _terrain[row][col], _roads[row][col], self)
			_tile_nodes[row][col] = tile
			_generated_root.add_child(tile)
			_enable_shadows_on_subtree(tile)


func _replace_tile_node(col: int, row: int) -> void:
	if not _in_bounds(col, row):
		return
	if row >= _tile_nodes.size():
		return
	var row_data := _tile_nodes[row] as Array
	if col >= row_data.size():
		return
	var existing := row_data[col] as TileBase
	if is_instance_valid(existing):
		existing.queue_free()
	var tile_scene := _get_tile_scene(_terrain[row][col])
	var tile := tile_scene.instantiate() as TileBase
	if tile == null:
		return
	tile.position = hex_to_world(col, row)
	tile.configure(col, row, _terrain[row][col], _roads[row][col], self)
	row_data[col] = tile
	_tile_nodes[row] = row_data
	_generated_root.add_child(tile)
	_enable_shadows_on_subtree(tile)


func _refresh_tile_and_neighbors(col: int, row: int) -> void:
	_refresh_tile_config(col, row)
	for dir in range(6):
		var nb := get_neighbor(col, row, dir)
		_refresh_tile_config(nb.x, nb.y)


func _refresh_tile_config(col: int, row: int) -> void:
	var tile := _get_tile_node(col, row)
	if tile == null:
		return
	tile.configure(col, row, _terrain[row][col], _roads[row][col], self)


func _get_tile_node(col: int, row: int) -> TileBase:
	if not _in_bounds(col, row):
		return null
	if row >= _tile_nodes.size():
		return null
	var row_data := _tile_nodes[row] as Array
	if col >= row_data.size():
		return null
	return row_data[col] as TileBase


# ── Marker creation ───────────────────────────────────────────────────────────

func _create_unit_marker_node(unit_name: String, col: int, row: int, color: Color,
		is_enemy: bool = false) -> Dictionary:
	if UNIT_MARKER_SCENE == null:
		push_warning("HexMap: UnitMarker scene is missing.")
		return {}
	var root := UNIT_MARKER_SCENE.instantiate() as UnitMarker
	if root == null:
		push_warning("HexMap: failed to instantiate UnitMarker scene.")
		return {}
	root.position = _unit_world_pos(col, row)
	_generated_root.add_child(root)
	root.configure(unit_name, color, is_enemy)
	_enable_shadows_on_subtree(root)
	return {
		"marker_root": root
	}


func _recreate_all_markers() -> void:
	for unit_name: String in _units:
		var d: Dictionary = _units[unit_name]
		var m := _create_unit_marker_node(unit_name, int(d["col"]), int(d["row"]),
				d.get("color", Color(0.25, 0.55, 1.0)) as Color,
				bool(d.get("is_enemy", false)))
		if not m.is_empty():
			d["marker_root"] = m.get("marker_root") as Node3D
		update_unit_org(unit_name, (d["unit"] as Unit).ORG)


func _update_marker_pos_for(unit_name: String) -> void:
	var d: Dictionary = _units.get(unit_name, {})
	if d.is_empty():
		return
	var mr: Node3D = d.get("marker_root")
	if not is_instance_valid(mr):
		return
	mr.position = _unit_world_pos(int(d["col"]), int(d["row"]))


func _unit_world_pos(col: int, row: int) -> Vector3:
	var pos := hex_to_world(col, row)
	pos.y += 0.9
	return pos


func _face_marker_towards(marker_root: Node3D, target_pos: Vector3) -> void:
	if not is_instance_valid(marker_root):
		return
	if marker_root is UnitMarker:
		(marker_root as UnitMarker).face_towards(target_pos)
		return
	var from := marker_root.global_position
	var flat_target := Vector3(target_pos.x, from.y, target_pos.z)
	if from.distance_squared_to(flat_target) < 0.000001:
		return
	# Keep rotation on horizontal plane only.
	marker_root.look_at(flat_target, Vector3.UP)


func update_unit_org(unit_name: String, org: float) -> void:
	var d: Dictionary = _units.get(unit_name, {})
	if d.is_empty():
		return
	var marker_root: UnitMarker = d.get("marker_root") as UnitMarker
	if not is_instance_valid(marker_root):
		return
	marker_root.set_org(org)


# ── Public movement API ───────────────────────────────────────────────────────

func calc_path(fc: int, fr: int, tc: int, tr: int) -> Array:
	if _in_bounds(tc, tr) and _is_impassable(_terrain[tr][tc]):
		var best := Vector2i(-1, -1)
		var best_dist := INF
		for dir in range(6):
			var nb := get_neighbor(tc, tr, dir)
			if _in_bounds(nb.x, nb.y) and not _is_impassable(_terrain[nb.y][nb.x]):
				var d := _hex_dist(nb.x, nb.y, fc, fr)
				if d < best_dist:
					best_dist = d
					best = nb
		if best.x < 0:
			return []
		tc = best.x
		tr = best.y
	return _astar(fc, fr, tc, tr)


func set_move_path(unit_name: String, path: Array) -> void:
	if _frozen_units.has(unit_name):
		return
	var d: Dictionary = _units.get(unit_name, {})
	if d.is_empty() or path.is_empty():
		return
	d["move_queue"] = path.duplicate()
	if not d["is_moving"]:
		_execute_next_move(unit_name)


func clear_move_queue(unit_name: String) -> void:
	var d: Dictionary = _units.get(unit_name, {})
	if d.is_empty():
		return
	var tween: Tween = d.get("current_tween")
	if is_instance_valid(tween) and tween.is_valid():
		tween.kill()
		# Before snapping visual, update logical position to nearest hex of current visual position
		# so that get_unit_pos() and path calculations use the correct starting hex.
		var marker_root: Node3D = d.get("marker_root") as Node3D
		if marker_root != null:
			var nearest := world_to_hex(marker_root.position)
			d["col"] = nearest.x
			d["row"] = nearest.y
	d["current_tween"] = null
	d["move_queue"] = []
	if d["is_moving"]:
		d["is_moving"] = false
		_update_marker_pos_for(unit_name)
		movement_finished.emit(unit_name)


func get_unit_pos(unit_name: String) -> Vector2i:
	var d: Dictionary = _units.get(unit_name, {})
	if d.is_empty():
		return Vector2i.ZERO
	return Vector2i(int(d["col"]), int(d["row"]))


func get_unit_is_enemy(unit_name: String) -> bool:
	var d: Dictionary = _units.get(unit_name, {})
	return bool(d.get("is_enemy", false))


func freeze_unit(unit_name: String) -> void:
	_frozen_units[unit_name] = true
	var d: Dictionary = _units.get(unit_name, {})
	if d.is_empty():
		return
	d["move_queue"] = []
	if not d.get("is_moving", false):
		return
	# If no active tween (unit just arrived, collision detected before _execute_next_move)
	# emit movement_finished to unblock the exec_queue runner
	var tween: Tween = d.get("current_tween") as Tween
	if not (is_instance_valid(tween) and tween.is_valid()):
		d["is_moving"] = false
		movement_finished.emit(unit_name)
	# else: tween still running (defender mid-step); tween callback will emit when done


func unfreeze_unit(unit_name: String) -> void:
	_frozen_units.erase(unit_name)


func is_unit_frozen(unit_name: String) -> bool:
	return _frozen_units.has(unit_name)


func find_adjacent_passable(col: int, row: int) -> Vector2i:
	var dirs := [0, 1, 2, 3, 4, 5]
	dirs.shuffle()
	for dir: int in dirs:
		var nb := get_neighbor(col, row, dir)
		if not _in_bounds(nb.x, nb.y):
			continue
		if _is_impassable(_terrain[nb.y][nb.x]):
			continue
		return nb
	return Vector2i(-1, -1)



func apply_speed_buff(unit_name: String, extra_kmh: float, hexes: int) -> void:
	var d: Dictionary = _units.get(unit_name, {})
	if d.is_empty():
		return
	d["speed_buff_kmh"] = extra_kmh
	d["speed_buff_hexes"] = hexes


func rename_unit(old_name: String, new_name: String) -> void:
	if not _units.has(old_name) or new_name.is_empty():
		return
	var d: Dictionary = _units[old_name]
	_units.erase(old_name)
	_units[new_name] = d
	var marker: UnitMarker = d.get("marker_root") as UnitMarker
	if is_instance_valid(marker):
		marker.set_unit_name(new_name)


func teleport_unit(unit_name: String, col: int, row: int) -> void:
	var d: Dictionary = _units.get(unit_name, {})
	if d.is_empty():
		return
	var tween = d.get("current_tween")
	if tween != null and tween is Tween:
		tween.kill()
		d["current_tween"] = null
	d["is_moving"] = false
	d["col"] = col
	d["row"] = row
	_update_marker_pos_for(unit_name)


func get_all_units_info() -> Array:
	var result: Array = []
	for unit_name: String in _units:
		var d: Dictionary = _units[unit_name]
		var u: Unit = d.get("unit") as Unit
		if u == null:
			continue
		result.append({
			"unit":     u,
			"col":      int(d.get("col", 0)),
			"row":      int(d.get("row", 0)),
			"is_enemy": bool(d.get("is_enemy", false))
		})
	result.sort_custom(func(a, b): return int(a["is_enemy"]) < int(b["is_enemy"]))
	return result


func get_unit_templates() -> Array:
	return _unit_templates


func ensure_unit_templates() -> void:
	if not _unit_templates.is_empty():
		return
	var player_names := ["第一重骑队", "第二长矛队", "第三步卒队", "第四弓弩队", "第五斥候队"]
	var enemy_names  := ["赤甲一部", "赤甲二部", "赤甲三部", "赤甲四部", "赤甲五部"]
	for i in range(player_unit_count):
		_unit_templates.append({
			"name": player_names[i] if i < player_names.size() else ("第%d部队" % (i + 1)),
			"is_enemy": false,
			"col": 0, "row": (4 + i * 3) % _grid_rows,
			"ATK": 70.0, "DEF": 60.0, "ORG": 85.0, "MORALE": 72.0,
			"PROF": 63.0, "RECON": 45.0, "STR": 88.0, "SUPPLY": 3.0,
			"SPEED": 4.5, "STAFF": 52.0
		})
	for i in range(enemy_unit_count):
		_unit_templates.append({
			"name": enemy_names[i] if i < enemy_names.size() else ("红%d部" % (i + 1)),
			"is_enemy": true,
			"col": _grid_cols - 1, "row": (4 + i * 3) % _grid_rows,
			"ATK": 68.0, "DEF": 58.0, "ORG": 80.0, "MORALE": 70.0,
			"PROF": 60.0, "RECON": 48.0, "STR": 85.0, "SUPPLY": 3.0,
			"SPEED": 5.0, "STAFF": 50.0
		})


func unregister_unit(unit_name: String) -> void:
	var d: Dictionary = _units.get(unit_name, {})
	if d.is_empty():
		return
	var mr: Node3D = d.get("marker_root")
	if is_instance_valid(mr):
		mr.queue_free()
	_units.erase(unit_name)


# ── Region system ─────────────────────────────────────────────────────────────

func _init_cell_region() -> void:
	_cell_region.resize(_grid_rows)
	for r in range(_grid_rows):
		_cell_region[r] = []
		_cell_region[r].resize(_grid_cols)
		for c in range(_grid_cols):
			_cell_region[r][c] = ""


func get_region_name(col: int, row: int) -> String:
	if not _in_bounds(col, row) or _cell_region.is_empty():
		return ""
	return str(_cell_region[row][col])


func name_region_rect(col_min: int, col_max: int, row_min: int, row_max: int, name: String) -> void:
	if _cell_region.is_empty():
		return
	for r in range(maxi(0, row_min), mini(_grid_rows, row_max + 1)):
		for c in range(maxi(0, col_min), mini(_grid_cols, col_max + 1)):
			_cell_region[r][c] = name
	refresh_region_labels()


func name_point(col: int, row: int, pname: String) -> void:
	if not _in_bounds(col, row) or _cell_region.is_empty():
		return
	_cell_region[row][col] = pname
	refresh_region_labels()


func clear_region_names() -> void:
	_init_cell_region()
	refresh_region_labels()


func get_all_region_names() -> Array:
	var result: Array = []
	if _cell_region.is_empty():
		return result
	var seen: Dictionary = {}
	for r in range(_grid_rows):
		for c in range(_grid_cols):
			var rname: String = str(_cell_region[r][c])
			if not rname.is_empty() and not seen.has(rname):
				seen[rname] = true
				result.append(rname)
	return result


func get_named_points() -> Array:
	var result: Array = []
	if _cell_region.is_empty():
		return result
	for r in range(_grid_rows):
		for c in range(_grid_cols):
			var rname: String = str(_cell_region[r][c])
			if not rname.is_empty():
				result.append({"name": rname, "col": c, "row": r})
	return result


func rename_region_name(old_name: String, new_name: String) -> void:
	if _cell_region.is_empty() or old_name == new_name or new_name.is_empty():
		return
	for r in range(_grid_rows):
		for c in range(_grid_cols):
			if str(_cell_region[r][c]) == old_name:
				_cell_region[r][c] = new_name
	refresh_region_labels()


func refresh_region_labels() -> void:
	if not is_instance_valid(_generated_root):
		return
	if is_instance_valid(_region_labels_root):
		_region_labels_root.queue_free()
	_region_labels_root = Node3D.new()
	_region_labels_root.name = "RegionLabels"
	_generated_root.add_child(_region_labels_root)
	if _cell_region.is_empty():
		return

	var name_sum: Dictionary = {}
	for r in range(_grid_rows):
		for c in range(_grid_cols):
			var rname: String = str(_cell_region[r][c])
			if rname.is_empty():
				continue
			var wpos := hex_to_world(c, r)
			if not name_sum.has(rname):
				name_sum[rname] = [wpos.x, wpos.z, 1]
			else:
				name_sum[rname][0] += wpos.x
				name_sum[rname][1] += wpos.z
				name_sum[rname][2] += 1

	for rname: String in name_sum:
		var s: Array = name_sum[rname]
		var cx: float = s[0] / float(s[2])
		var cz: float = s[1] / float(s[2])
		var lbl := Label3D.new()
		lbl.text = rname
		lbl.font_size = 72
		lbl.pixel_size = 0.0075
		lbl.modulate = Color(1.0, 0.85, 0.3, 0.5)
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		lbl.position = Vector3(cx, 0.8, cz)
		_region_labels_root.add_child(lbl)


# ── Map string for AI context ─────────────────────────────────────────────────

func get_map_string() -> String:
	const T_CHAR := ["P", "F", "M", "W", "C"]
	var col_header := "    "  # 4-space prefix matches row data prefix width
	for c in range(_grid_cols):
		col_header += (str(c) if c < 10 else char(ord("A") + c - 10))
	var lines: Array[String] = [
		"【地图%d×%d: P=平原 F=树林 M=山地 W=水域 C=城市，小写=有路，→=奇数行右偏，列10+=A/B/C...】" \
			% [_grid_cols, _grid_rows],
		col_header
	]
	for r in range(_grid_rows):
		var row_str := ""
		for c in range(_grid_cols):
			var t: int = _terrain[r][c]
			var ch: String = T_CHAR[clampi(t, 0, T_CHAR.size() - 1)]
			if int(_roads[r][c]) != 0:
				ch = ch.to_lower()
			row_str += ch
		var prefix := "%2d%s " % [r, "→" if r % 2 == 1 else " "]
		lines.append(prefix + row_str)

	# Append named regions summary if any cells have been named
	if not _cell_region.is_empty():
		var name_bounds: Dictionary = {}
		for r in range(_grid_rows):
			for c in range(_grid_cols):
				var rname: String = str(_cell_region[r][c])
				if not rname.is_empty():
					if not name_bounds.has(rname):
						name_bounds[rname] = [c, c, r, r]
					else:
						name_bounds[rname][0] = mini(name_bounds[rname][0], c)
						name_bounds[rname][1] = maxi(name_bounds[rname][1], c)
						name_bounds[rname][2] = mini(name_bounds[rname][2], r)
						name_bounds[rname][3] = maxi(name_bounds[rname][3], r)
		if not name_bounds.is_empty():
			lines.append("\n【已命名区域】")
			for rname: String in name_bounds:
				var b: Array = name_bounds[rname]
				lines.append("  %s(列%d-%d,行%d-%d)" % [rname, b[0], b[1], b[2], b[3]])

	return "\n".join(lines)


func get_position_info(unit_name: String) -> String:
	var d: Dictionary = _units.get(unit_name, {})
	if d.is_empty():
		return ""
	var col: int = int(d["col"])
	var row: int = int(d["row"])
	const TERRAIN_NAMES := ["平原", "树林", "山地", "水域", "城市"]
	const DIR_NAMES := ["东北", "东", "东南", "西南", "西", "西北"]
	var cur: String = TERRAIN_NAMES[_terrain[row][col]]
	var road_mask: int = _roads[row][col]
	var region: String = get_region_name(col, row)
	var region_part := (" 区域：" + region) if not region.is_empty() else ""
	var info := "【%s】位置：(%d,%d) 地块：%s%s" % [unit_name, col, row, cur, region_part]
	var neighbors: Array[String] = []
	for dir in range(6):
		var nb := get_neighbor(col, row, dir)
		if _in_bounds(nb.x, nb.y):
			var has_road := " [有路]" if (road_mask & (1 << dir)) else ""
			neighbors.append("%s(%d,%d):%s%s" % [
				DIR_NAMES[dir], nb.x, nb.y,
				TERRAIN_NAMES[_terrain[nb.y][nb.x]], has_road
			])
	info += "\n相邻格：" + ", ".join(neighbors)

	# Visible enemy units (opposite faction, within detection range)
	var self_is_enemy: bool = bool(d.get("is_enemy", false))
	var self_unit: Unit = d.get("unit") as Unit
	var recon_range: float = 5.0  # default detection hex radius
	if self_unit != null:
		recon_range = maxf(2.0, (self_unit.RECON + self_unit.STAFF) / 10.0)
	var visible_enemies: Array[String] = []
	for other_name: String in _units:
		if other_name == unit_name:
			continue
		var od: Dictionary = _units[other_name]
		if bool(od.get("is_enemy", false)) == self_is_enemy:
			continue  # same faction
		var ec: int = int(od["col"])
		var er: int = int(od["row"])
		var dist := absf(float(ec - col)) + absf(float(er - row))
		if dist <= recon_range:
			var other_unit: Unit = od.get("unit") as Unit
			var name_str := other_name
			if other_unit != null:
				name_str = "%s STR:%.0f%% ORG:%.0f" % [other_name, other_unit.STR, other_unit.ORG]
			visible_enemies.append("%s 位置(%d,%d)" % [name_str, ec, er])
	if not visible_enemies.is_empty():
		info += "\n可见敌军：" + "；".join(visible_enemies)

	return info


# ── Movement execution ────────────────────────────────────────────────────────

func _execute_next_move(unit_name: String) -> void:
	var d: Dictionary = _units.get(unit_name, {})
	if d.is_empty():
		return
	var move_queue: Array = d["move_queue"]
	if move_queue.is_empty():
		if d["is_moving"]:
			d["is_moving"] = false
			_update_marker_pos_for(unit_name)
			movement_finished.emit(unit_name)
		return
	d["is_moving"] = true
	var next: Array = move_queue.pop_front() as Array
	var nc: int = int(next[0])
	var nr: int = int(next[1])
	var u: Unit = d["unit"] as Unit
	var col: int = int(d["col"])
	var row: int = int(d["row"])

	var from_tile := _get_tile_node(col, row)
	var to_tile   := _get_tile_node(nc, nr)
	if from_tile != null and u != null:
		from_tile.on_unit_leave(u)
	if to_tile != null and u != null:
		to_tile.on_unit_enter(u)

	var travel_time := _travel_time_for(unit_name, col, row, nc, nr)
	var target_pos  := _unit_world_pos(nc, nr)

	var marker_root: Node3D = d["marker_root"]
	_face_marker_towards(marker_root, target_pos)
	var tween := create_tween()
	d["current_tween"] = tween
	tween.tween_property(marker_root, "position", target_pos, travel_time)
	tween.tween_callback(func():
		d["col"] = nc
		d["row"] = nr
		d["current_tween"] = null
		# If frozen (battle started while this step was animating): stop here
		if _frozen_units.has(unit_name):
			d["is_moving"] = false
			movement_finished.emit(unit_name)
			return
		# Check for combat collision with opposite-faction unit at same hex
		var d_is_enemy: bool = bool(d.get("is_enemy", false))
		for other_name: String in _units:
			if other_name == unit_name:
				continue
			var od: Dictionary = _units[other_name]
			if int(od["col"]) == nc and int(od["row"]) == nr:
				if bool(od.get("is_enemy", false)) != d_is_enemy:
					unit_collision.emit(unit_name, other_name)
					return  # freeze_unit will emit movement_finished for the mover
		_execute_next_move(unit_name)
	)


func _travel_time_for(unit_name: String, fc: int, fr: int, tc: int, tr: int) -> float:
	var d: Dictionary = _units.get(unit_name, {})
	var u: Unit = d.get("unit") as Unit
	var spd: float = maxf(u.SPEED if u != null else 10.0, 0.1)
	var dir := _get_direction(fc, fr, tc, tr)
	var base := 5.0 if (dir >= 0 and (_roads[fr][fc] & (1 << dir))) else 10.0
	return base * 10.0 / spd


# ── Coordinate labels ─────────────────────────────────────────────────────────

func _create_coord_labels() -> void:
	for c in range(_grid_cols):
		var lbl := Label3D.new()
		lbl.text = str(c)
		lbl.font_size = 48
		lbl.pixel_size = 0.012
		lbl.modulate = Color(1.0, 0.92, 0.4, 1.0)
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		var pos := hex_to_world(c, 0)
		pos.z -= V_STEP * 1.4
		pos.y = 0.5
		lbl.position = pos
		_generated_root.add_child(lbl)

	for r in range(_grid_rows):
		var lbl := Label3D.new()
		lbl.text = str(r)
		lbl.font_size = 48
		lbl.pixel_size = 0.012
		lbl.modulate = Color(0.4, 0.92, 1.0, 1.0)
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		var pos := hex_to_world(0, r)
		pos.x -= H_STEP * 1.4
		pos.y = 0.5
		lbl.position = pos
		_generated_root.add_child(lbl)


# ── Hover overlay (highlight + coord label) ────────────────────────────────────

func _create_hover_overlay() -> void:
	var cyl := CylinderMesh.new()
	cyl.top_radius    = 0.90
	cyl.bottom_radius = 0.90
	cyl.height        = 0.02
	cyl.radial_segments = 6
	_highlight_mat = StandardMaterial3D.new()
	_highlight_mat.transparency   = BaseMaterial3D.TRANSPARENCY_ALPHA
	_highlight_mat.shading_mode   = BaseMaterial3D.SHADING_MODE_UNSHADED
	_highlight_mat.no_depth_test  = true
	_highlight_mat.cull_mode      = BaseMaterial3D.CULL_DISABLED
	_highlight_mat.albedo_color   = Color(0.22, 0.55, 1.0, 0.35)
	_hover_highlight = MeshInstance3D.new()
	_hover_highlight.mesh              = cyl
	_hover_highlight.material_override = _highlight_mat
	_hover_highlight.visible           = false
	add_child(_hover_highlight)

	_hover_label = Label3D.new()
	_hover_label.font_size   = 48
	_hover_label.pixel_size  = 0.006
	_hover_label.modulate    = Color(1.0, 1.0, 0.3, 1.0)
	_hover_label.billboard   = BaseMaterial3D.BILLBOARD_ENABLED
	_hover_label.no_depth_test = true
	_hover_label.visible     = false
	add_child(_hover_label)




func world_to_hex(world_pos: Vector3) -> Vector2i:
	var cx := (_grid_cols - 1) * H_STEP * 0.5
	var cz := (_grid_rows - 1) * V_STEP * 0.5
	var row_f := (world_pos.z + cz) / V_STEP
	var row: int   = clampi(int(round(row_f)), 0, _grid_rows - 1)
	var offset := ROW_OFFSET if row % 2 == 1 else 0.0
	var col_f := (world_pos.x + cx - offset) / H_STEP
	var col: int   = clampi(int(round(col_f)), 0, _grid_cols - 1)
	var best  := Vector2i(col, row)
	var best_d := world_pos.distance_squared_to(hex_to_world(col, row))
	for r in range(max(0, row - 1), min(_grid_rows, row + 2)):
		for c in range(max(0, col - 1), min(_grid_cols, col + 2)):
			var d := world_pos.distance_squared_to(hex_to_world(c, r))
			if d < best_d:
				best_d = d
				best = Vector2i(c, r)
	return best


# ── Tooltip ───────────────────────────────────────────────────────────────────

func _create_tooltip() -> void:
	_tooltip_canvas = CanvasLayer.new()
	_tooltip_canvas.layer = 20
	_tooltip = PanelContainer.new()
	_tooltip.visible = false
	_tooltip.custom_minimum_size = Vector2(220, 0)
	_tooltip_canvas.add_child(_tooltip)
	_tooltip_label = RichTextLabel.new()
	_tooltip_label.bbcode_enabled = true
	_tooltip_label.fit_content = true
	_tooltip_label.custom_minimum_size = Vector2(210, 0)
	_tooltip.add_child(_tooltip_label)
	get_tree().root.add_child(_tooltip_canvas)


# ── Pathfinding ───────────────────────────────────────────────────────────────

func _astar(fc: int, fr: int, tc: int, tr: int) -> Array:
	if fc == tc and fr == tr:
		return []
	var start := Vector2i(fc, fr)
	var goal  := Vector2i(tc, tr)
	var open_set: Dictionary = {start: _hex_dist(fc, fr, tc, tr) * ASTAR_ROAD}
	var g_score: Dictionary  = {start: 0.0}
	var came_from: Dictionary = {}

	while not open_set.is_empty():
		var current := _min_f(open_set)
		if current == goal:
			var path: Array = []
			while came_from.has(current):
				path.push_front([current.x, current.y])
				current = came_from[current]
			return path
		open_set.erase(current)
		var cur_g: float = g_score[current]
		for dir in range(6):
			var nb := get_neighbor(current.x, current.y, dir)
			if not _in_bounds(nb.x, nb.y):
				continue
			if _is_impassable(_terrain[nb.y][nb.x]):
				continue
			var edge_cost := ASTAR_ROAD if (_roads[current.y][current.x] & (1 << dir)) else ASTAR_GRASS
			var tg := cur_g + edge_cost
			if not g_score.has(nb) or tg < g_score[nb]:
				g_score[nb] = tg
				came_from[nb] = current
				open_set[nb] = tg + _hex_dist(nb.x, nb.y, tc, tr) * ASTAR_ROAD
	return []


func _min_f(d: Dictionary) -> Vector2i:
	var best: Vector2i
	var best_v := INF
	for k in d:
		if d[k] < best_v:
			best_v = d[k]
			best = k
	return best


func _hex_dist(ac: int, ar: int, bc: int, br: int) -> float:
	var aq := ac - (ar - (ar & 1)) / 2
	var as_ := ar
	var ay := -aq - as_
	var bq := bc - (br - (br & 1)) / 2
	var bs := br
	var by := -bq - bs
	return max(abs(aq - bq), max(abs(ay - by), abs(as_ - bs)))


# ── Debug text (queue overlay) ────────────────────────────────────────────────

func set_unit_debug_text(unit_name: String, text: String) -> void:
	_unit_debug_texts[unit_name] = text


# ── Victory city ──────────────────────────────────────────────────────────────

func set_victory_city(col: int, row: int) -> void:
	_victory_city = Vector2i(col, row)
	_rebuild_victory_marker()


func get_victory_city() -> Vector2i:
	return _victory_city


func _rebuild_victory_marker() -> void:
	if is_instance_valid(_victory_city_marker):
		_victory_city_marker.queue_free()
	_victory_city_marker = null
	if _victory_city.x < 0 or not _in_bounds(_victory_city.x, _victory_city.y):
		return
	var root := Node3D.new()
	root.name = "VictoryCityMarker"
	var wpos := hex_to_world(_victory_city.x, _victory_city.y)
	root.position = Vector3(wpos.x, 1.1, wpos.z)
	# Golden glowing ring
	var ring_mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius    = 0.82
	cyl.bottom_radius = 0.82
	cyl.height        = 0.06
	cyl.radial_segments = 6
	var mat := StandardMaterial3D.new()
	mat.albedo_color      = Color(1.0, 0.85, 0.1, 0.5)
	mat.emission_enabled  = true
	mat.emission          = Color(1.0, 0.7, 0.0) * 1.2
	mat.transparency      = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test     = true
	ring_mesh.mesh              = cyl
	ring_mesh.material_override = mat
	root.add_child(ring_mesh)
	# Star label
	var lbl := Label3D.new()
	lbl.text          = "★胜利目标"
	lbl.font_size     = 56
	lbl.pixel_size    = 0.006
	lbl.modulate      = Color(1.0, 0.9, 0.1, 1.0)
	lbl.billboard     = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.position      = Vector3(0.0, 0.7, 0.0)
	root.add_child(lbl)
	_enable_shadows_on_subtree(root)
	add_child(root)
	_victory_city_marker = root


# ── Supply convoy markers ─────────────────────────────────────────────────────

func add_convoy_marker(convoy_id: String, col: int, row: int, color: Color) -> void:
	if _convoy_markers.has(convoy_id):
		return
	if not is_instance_valid(_generated_root):
		return
	if SUPPLY_MARKER_SCENE == null:
		push_warning("HexMap: SupplyMarker scene is missing.")
		return
	var root := SUPPLY_MARKER_SCENE.instantiate() as SupplyMarker
	if root == null:
		push_warning("HexMap: failed to instantiate SupplyMarker scene.")
		return
	root.position = hex_to_world(col, row)
	_generated_root.add_child(root)
	root.configure(convoy_id, color)
	_enable_shadows_on_subtree(root)
	_convoy_markers[convoy_id] = root


func update_convoy_marker(convoy_id: String, col: int, row: int, on_arrived: Callable = Callable()) -> void:
	var root: Node3D = _convoy_markers.get(convoy_id) as Node3D
	if not is_instance_valid(root):
		if on_arrived.is_valid():
			on_arrived.call()
		return
	var target_pos := hex_to_world(col, row)
	if root is SupplyMarker:
		(root as SupplyMarker).face_towards(target_pos)
	else:
		_face_marker_towards(root, target_pos)
	var tween := create_tween()
	tween.tween_property(root, "position", target_pos, 1.0)
	if on_arrived.is_valid():
		tween.tween_callback(on_arrived)


func remove_convoy_marker(convoy_id: String) -> void:
	var root: Node3D = _convoy_markers.get(convoy_id) as Node3D
	if is_instance_valid(root):
		root.queue_free()
	_convoy_markers.erase(convoy_id)


# ── Passable column helper (for supply convoy spawning) ───────────────────────

func find_random_passable_in_col(col: int) -> int:
	var passable: Array = []
	for r in range(_grid_rows):
		if _in_bounds(col, r) and not _is_impassable(_terrain[r][col]):
			passable.append(r)
	if passable.is_empty():
		# Fallback: any passable row anywhere
		for r in range(_grid_rows):
			for c in range(_grid_cols):
				if not _is_impassable(_terrain[r][c]):
					return r
		return 0
	return passable[randi() % passable.size()]
