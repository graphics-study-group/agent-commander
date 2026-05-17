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

@export var auto_generate_on_ready := true
@export_file("*.tres", "*.res") var startup_map_path := ""

var _grid_cols := GRID_COLS
var _grid_rows := GRID_ROWS
var _terrain: Array = []
var _roads: Array = []
var _tile_nodes: Array = []

var _unit: Unit
var _unit_col := 8
var _unit_row := 8

var _generated_root: Node3D
var _marker: MeshInstance3D
var _tooltip_canvas: CanvasLayer
var _tooltip: PanelContainer
var _tooltip_label: RichTextLabel

var _move_queue: Array = []
var _is_moving := false
var _speed_buff_kmh := 0.0
var _speed_buff_hexes := 0


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
	if _marker == null or _tooltip == null:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var screen_pos := camera.unproject_position(_marker.global_position)
	var mouse_pos := get_viewport().get_mouse_position()
	if screen_pos.distance_to(mouse_pos) < 44.0 and _unit != null:
		_tooltip.visible = true
		_tooltip_label.text = _unit.get_display_text()
		var vp := get_viewport().get_visible_rect().size
		var tp := Vector2(screen_pos.x + 14.0, screen_pos.y - _tooltip.size.y - 8.0)
		tp.x = clamp(tp.x, 4.0, vp.x - _tooltip.size.x - 4.0)
		tp.y = clamp(tp.y, 4.0, vp.y - _tooltip.size.y - 4.0)
		_tooltip.position = tp
	else:
		_tooltip.visible = false


func _exit_tree() -> void:
	if is_instance_valid(_tooltip_canvas):
		_tooltip_canvas.queue_free()


func _init_refs() -> void:
	var ui := get_tree().get_first_node_in_group("commander_ui")
	if ui != null:
		_unit = ui.get("unit") as Unit
		ui.move_command.connect(_on_move_command)
		ui.pathfind_command.connect(_on_pathfind_command)
	_create_tooltip()


func regenerate_random_map() -> void:
	regenerate_map(GRID_COLS, GRID_ROWS, false)


func regenerate_map(cols: int, rows: int, all_plain: bool = false) -> void:
	_grid_cols = maxi(cols, 1)
	_grid_rows = maxi(rows, 1)
	if all_plain:
		_generate_plain_terrain()
	else:
		_generate_terrain()
	_generate_roads()
	_find_start_pos()
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

	_unit_col = data.spawn_col
	_unit_row = data.spawn_row
	if _is_impassable(_terrain[_unit_row][_unit_col]):
		_find_start_pos()

	_rebuild_visuals()
	return true


func export_map_data() -> MapData:
	var data := MapData.new()
	data.version = 2
	data.cols = _grid_cols
	data.rows = _grid_rows
	data.set_tile_types_grid(_terrain)
	data.roads = _copy_grid(_roads)
	data.spawn_col = _unit_col
	data.spawn_row = _unit_row
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
	_clear_generated_root()
	_generate_tiles()
	_create_marker()
	_update_marker_pos()


func _clear_generated_root() -> void:
	if is_instance_valid(_generated_root):
		_generated_root.queue_free()
	_generated_root = Node3D.new()
	_generated_root.name = "GeneratedMap"
	add_child(_generated_root)
	_tile_nodes = []


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


func _find_start_pos() -> void:
	var best_dist := INF
	for r in range(_grid_rows):
		for c in range(_grid_cols):
			if not _is_impassable(_terrain[r][c]):
				var d := _hex_dist(c, r, _grid_cols / 2, _grid_rows / 2)
				if d < best_dist:
					best_dist = d
					_unit_col = c
					_unit_row = r


func _generate_roads() -> void:
	_roads.resize(_grid_rows)
	for r in range(_grid_rows):
		_roads[r] = []
		_roads[r].resize(_grid_cols)
		for c in range(_grid_cols):
			_roads[r][c] = 0

	var attempts := _grid_cols * _grid_rows
	for _i in range(attempts):
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


func set_tile_type_at(col: int, row: int, tile_type: int) -> bool:
	if not _in_bounds(col, row):
		return false
	var normalized_type := clampi(tile_type, Terrain.PLAIN, Terrain.CITY)
	if int(_terrain[row][col]) == normalized_type:
		return false
	_terrain[row][col] = normalized_type
	if _is_impassable(_terrain[_unit_row][_unit_col]):
		_find_start_pos()
		_update_marker_pos()
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


func _create_marker() -> void:
	_marker = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.18
	cyl.bottom_radius = 0.18
	cyl.height = 0.45
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.55, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.1, 0.3, 0.8)
	_marker.mesh = cyl
	_marker.material_override = mat
	_generated_root.add_child(_marker)


func _update_marker_pos() -> void:
	if _marker == null:
		return
	var p := hex_to_world(_unit_col, _unit_row)
	p.y = 1.5
	_marker.position = p


func _on_move_command(direction: int, steps: int) -> void:
	if _is_moving:
		return
	var path: Array = []
	var cc := _unit_col
	var cr := _unit_row
	for _i in range(steps):
		var nb := get_neighbor(cc, cr, direction)
		if not _in_bounds(nb.x, nb.y):
			break
		if _is_impassable(_terrain[nb.y][nb.x]):
			break
		path.append([nb.x, nb.y])
		cc = nb.x
		cr = nb.y
	if not path.is_empty():
		_move_queue = path
		_execute_next_move()


func _on_pathfind_command(target_col: int, target_row: int) -> void:
	if _is_moving:
		return
	var tc := target_col
	var tr := target_row
	if _in_bounds(tc, tr) and _is_impassable(_terrain[tr][tc]):
		var best := Vector2i(-1, -1)
		var best_dist := INF
		for dir in range(6):
			var nb := get_neighbor(tc, tr, dir)
			if _in_bounds(nb.x, nb.y) and not _is_impassable(_terrain[nb.y][nb.x]):
				var d := _hex_dist(nb.x, nb.y, _unit_col, _unit_row)
				if d < best_dist:
					best_dist = d
					best = nb
		if best.x < 0:
			return
		tc = best.x
		tr = best.y
	var path := _astar(_unit_col, _unit_row, tc, tr)
	if not path.is_empty():
		_move_queue = path
		_execute_next_move()


func _execute_next_move() -> void:
	if _move_queue.is_empty():
		_is_moving = false
		return
	_is_moving = true
	var next := _move_queue.pop_front() as Array
	var nc: int = next[0]
	var nr: int = next[1]

	var from_tile := _get_tile_node(_unit_col, _unit_row)
	var to_tile := _get_tile_node(nc, nr)
	if from_tile != null and _unit != null:
		from_tile.on_unit_leave(_unit)
	if to_tile != null and _unit != null:
		to_tile.on_unit_enter(_unit)

	var travel_time := _travel_time(_unit_col, _unit_row, nc, nr)
	var target_pos := hex_to_world(nc, nr)
	target_pos.y = 0.3

	var tw := create_tween()
	tw.tween_property(_marker, "position", target_pos, travel_time)
	tw.tween_callback(func():
		_unit_col = nc
		_unit_row = nr
		if _speed_buff_hexes > 0:
			_speed_buff_hexes -= 1
			if _speed_buff_hexes <= 0:
				_speed_buff_kmh = 0.0
		_execute_next_move()
	)


func _travel_time(fc: int, fr: int, tc: int, tr: int) -> float:
	var base_spd: float = (_unit.SPEED if _unit != null else 4.0) + _speed_buff_kmh
	var spd := maxf(base_spd, 0.1)
	var dir := _get_direction(fc, fr, tc, tr)
	if dir >= 0 and (_roads[fr][fc] & (1 << dir)):
		spd *= 2.0
	return HEX_DIST_KM / spd


func apply_speed_buff(extra_kmh: float, hexes: int) -> void:
	_speed_buff_kmh = extra_kmh
	_speed_buff_hexes = hexes


func _astar(fc: int, fr: int, tc: int, tr: int) -> Array:
	if fc == tc and fr == tr:
		return []
	var start := Vector2i(fc, fr)
	var goal := Vector2i(tc, tr)
	var open_set: Dictionary = {start: _hex_dist(fc, fr, tc, tr) * ASTAR_ROAD}
	var g_score: Dictionary = {start: 0.0}
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


func get_position_info() -> String:
	const TERRAIN_NAMES := ["平原", "树林", "山地", "水域", "城市"]
	const DIR_NAMES := ["东北", "东", "东南", "西南", "西", "西北"]
	var cur: String = TERRAIN_NAMES[_terrain[_unit_row][_unit_col]]
	var road_mask: int = _roads[_unit_row][_unit_col]
	var info := "部队当前位置：(%d,%d) 地块：%s" % [_unit_col, _unit_row, cur]
	var neighbors: Array[String] = []
	for d in range(6):
		var nb := get_neighbor(_unit_col, _unit_row, d)
		if _in_bounds(nb.x, nb.y):
			var has_road := " [有路]" if (road_mask & (1 << d)) else ""
			neighbors.append("%s(%d,%d):%s%s" % [
				DIR_NAMES[d], nb.x, nb.y,
				TERRAIN_NAMES[_terrain[nb.y][nb.x]], has_road
			])
	info += "\n相邻格：" + ", ".join(neighbors)
	return info


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
