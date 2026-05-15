extends Node3D

const TILE_SCENE_PATH := "res://assets/HexagonalPrism.glb"
const TILE_SCALE      := 0.97
const GRID_COLS       := 16
const GRID_ROWS       := 16
const H_STEP          := 0.866
const V_STEP          := 0.75
const ROW_OFFSET      := 0.433

const HEX_DIST_KM     := 40.0   # km between adjacent hex centers
# A* relative weights (road is 2× faster than grass)
const ASTAR_GRASS     := 10.0
const ASTAR_ROAD      := 5.0

enum Terrain { GRASSLAND, MOUNTAIN, LAKE }

# Neighbor offsets [dc, dr] for each of the 6 directions
const OFFSETS_EVEN := [[0,-1],[1,0],[0,1],[-1,1],[-1,0],[-1,-1]]
const OFFSETS_ODD  := [[1,-1],[1,0],[1,1],[0,1],[-1,0],[0,-1]]

var _terrain: Array = []   # [row][col] -> Terrain
var _roads:   Array = []   # [row][col] -> int bitmask (bit i = road in dir i)

var _unit: Unit
var _unit_col := 8
var _unit_row := 8

var _marker: MeshInstance3D
var _tooltip_canvas: CanvasLayer
var _tooltip: PanelContainer
var _tooltip_label: RichTextLabel

var _move_queue: Array = []
var _is_moving  := false
var _speed_buff_kmh   := 0.0  # temporary extra speed in km/h
var _speed_buff_hexes := 0    # hexes remaining for buff


func _ready() -> void:
	add_to_group("hex_map")
	_generate_terrain()
	_generate_roads()
	_find_start_pos()
	_generate_grid()
	_draw_roads()
	_create_marker()
	call_deferred("_init_refs")


func _process(_delta: float) -> void:
	if _marker == null or _tooltip == null:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var screen_pos := camera.unproject_position(_marker.global_position)
	var mouse_pos  := get_viewport().get_mouse_position()
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


# ── Terrain & road generation ─────────────────────────────────────────────────

func _generate_terrain() -> void:
	_terrain.resize(GRID_ROWS)
	for r in range(GRID_ROWS):
		_terrain[r] = []
		_terrain[r].resize(GRID_COLS)
		for c in range(GRID_COLS):
			var v := randf()
			if v < 0.15:
				_terrain[r][c] = Terrain.MOUNTAIN
			elif v < 0.30:
				_terrain[r][c] = Terrain.LAKE
			else:
				_terrain[r][c] = Terrain.GRASSLAND


func _find_start_pos() -> void:
	var best_dist := INF
	for r in range(GRID_ROWS):
		for c in range(GRID_COLS):
			if _terrain[r][c] == Terrain.GRASSLAND:
				var d := _hex_dist(c, r, GRID_COLS / 2, GRID_ROWS / 2)
				if d < best_dist:
					best_dist = d
					_unit_col = c
					_unit_row = r


func _generate_roads() -> void:
	_roads.resize(GRID_ROWS)
	for r in range(GRID_ROWS):
		_roads[r] = []
		_roads[r].resize(GRID_COLS)
		for c in range(GRID_COLS):
			_roads[r][c] = 0

	var attempts := GRID_COLS * GRID_ROWS
	for _i in range(attempts):
		var col := randi() % GRID_COLS
		var row := randi() % GRID_ROWS
		if _terrain[row][col] != Terrain.GRASSLAND:
			continue
		var dir := randi() % 6
		var nb  := get_neighbor(col, row, dir)
		if not _in_bounds(nb.x, nb.y):
			continue
		if _terrain[nb.y][nb.x] != Terrain.GRASSLAND:
			continue
		_roads[row][col]     |= (1 << dir)
		_roads[nb.y][nb.x]  |= (1 << ((dir + 3) % 6))


# ── Hex geometry ──────────────────────────────────────────────────────────────

func hex_to_world(col: int, row: int) -> Vector3:
	var cx := (GRID_COLS - 1) * H_STEP * 0.5
	var cz := (GRID_ROWS - 1) * V_STEP * 0.5
	var x  := col * H_STEP + (ROW_OFFSET if row % 2 == 1 else 0.0) - cx
	var z  := row * V_STEP - cz
	return Vector3(x, 0.0, z)


func get_neighbor(col: int, row: int, dir: int) -> Vector2i:
	var off: Array = OFFSETS_ODD[dir] if row % 2 == 1 else OFFSETS_EVEN[dir]
	return Vector2i(col + int(off[0]), row + int(off[1]))


func _in_bounds(col: int, row: int) -> bool:
	return col >= 0 and col < GRID_COLS and row >= 0 and row < GRID_ROWS


func _get_direction(fc: int, fr: int, tc: int, tr: int) -> int:
	var off: Array = OFFSETS_ODD if fr % 2 == 1 else OFFSETS_EVEN
	for d in range(6):
		var entry: Array = off[d]
		if fc + int(entry[0]) == tc and fr + int(entry[1]) == tr:
			return d
	return -1


# ── Grid rendering ────────────────────────────────────────────────────────────

func _generate_grid() -> void:
	var tile_scene   := load(TILE_SCENE_PATH) as PackedScene
	var mat_grass    := _solid_mat(Color(0.35, 0.65, 0.25))
	var mat_mountain := _solid_mat(Color(0.52, 0.40, 0.28))
	var mat_lake     := _solid_mat(Color(0.20, 0.45, 0.85))

	for row in range(GRID_ROWS):
		for col in range(GRID_COLS):
			var tile := tile_scene.instantiate()
			tile.position = hex_to_world(col, row)
			tile.scale    = Vector3.ONE * TILE_SCALE
			match _terrain[row][col]:
				Terrain.MOUNTAIN: _set_mat_recursive(tile, mat_mountain)
				Terrain.LAKE:     _set_mat_recursive(tile, mat_lake)
				_:                _set_mat_recursive(tile, mat_grass)
			add_child(tile)


func _solid_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	return m


func _set_mat_recursive(node: Node, mat: Material) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = mat
	for child in node.get_children():
		_set_mat_recursive(child, mat)


# ── Road rendering ────────────────────────────────────────────────────────────

func _draw_roads() -> void:
	var verts   := PackedVector3Array()
	var indices := PackedInt32Array()
	var idx     := 0
	const ROAD_W := 0.08

	for row in range(GRID_ROWS):
		for col in range(GRID_COLS):
			var mask: int = _roads[row][col]
			if mask == 0:
				continue
			var center := hex_to_world(col, row)
			center.y = 0.28
			for dir in range(6):
				if not (mask & (1 << dir)):
					continue
				var nb := get_neighbor(col, row, dir)
				if not _in_bounds(nb.x, nb.y):
					continue
				var nb_world := hex_to_world(nb.x, nb.y)
				nb_world.y = 0.28
				var edge_mid := (center + nb_world) * 0.5
				var seg_dir  := (edge_mid - center).normalized()
				var perp     := Vector3(seg_dir.z, 0.0, -seg_dir.x) * (ROAD_W * 0.5)

				verts.append(center - perp)
				verts.append(center + perp)
				verts.append(edge_mid + perp)
				verts.append(edge_mid - perp)
				indices.append(idx);     indices.append(idx + 1); indices.append(idx + 2)
				indices.append(idx);     indices.append(idx + 2); indices.append(idx + 3)
				idx += 4

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX]  = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi  := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color  = Color(0.55, 0.55, 0.55)
	mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mi.material_override = mat
	add_child(mi)


# ── Unit marker ───────────────────────────────────────────────────────────────

func _create_marker() -> void:
	_marker = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius    = 0.18
	cyl.bottom_radius = 0.18
	cyl.height        = 0.45
	var mat := StandardMaterial3D.new()
	mat.albedo_color     = Color(0.25, 0.55, 1.0)
	mat.emission_enabled = true
	mat.emission         = Color(0.1, 0.3, 0.8)
	_marker.mesh              = cyl
	_marker.material_override = mat
	add_child(_marker)
	_update_marker_pos()


func _update_marker_pos() -> void:
	var p := hex_to_world(_unit_col, _unit_row)
	p.y = 0.3
	_marker.position = p


# ── Movement commands ─────────────────────────────────────────────────────────

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
		var t: int = _terrain[nb.y][nb.x]
		if t == Terrain.MOUNTAIN or t == Terrain.LAKE:
			break  # stop at boundary, do not enter impassable hex
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
	# If target is impassable, reroute to the nearest passable neighbor of the target
	if _in_bounds(tc, tr):
		var t: int = _terrain[tr][tc]
		if t == Terrain.MOUNTAIN or t == Terrain.LAKE:
			var best := Vector2i(-1, -1)
			var best_dist := INF
			for dir in range(6):
				var nb := get_neighbor(tc, tr, dir)
				if _in_bounds(nb.x, nb.y) and _terrain[nb.y][nb.x] == Terrain.GRASSLAND:
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

	var travel_time := _travel_time(_unit_col, _unit_row, nc, nr)
	var target_pos  := hex_to_world(nc, nr)
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
		spd *= 2.0  # roads are 2× faster
	# travel time (real seconds) = 40 km / speed (km/h) — 1 game-hour == 1 real-second
	return HEX_DIST_KM / spd


func apply_speed_buff(extra_kmh: float, hexes: int) -> void:
	_speed_buff_kmh   = extra_kmh
	_speed_buff_hexes = hexes


# ── A* pathfinding ────────────────────────────────────────────────────────────

func _astar(fc: int, fr: int, tc: int, tr: int) -> Array:
	if fc == tc and fr == tr:
		return []
	var start := Vector2i(fc, fr)
	var goal  := Vector2i(tc, tr)
	var open_set:   Dictionary = {start: _hex_dist(fc, fr, tc, tr) * ASTAR_ROAD}
	var g_score:    Dictionary = {start: 0.0}
	var came_from:  Dictionary = {}

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
			# Mountains and lakes excluded from pathfinding (speed reserved as 0 for future)
			var t: int = _terrain[nb.y][nb.x]
			if t == Terrain.MOUNTAIN or t == Terrain.LAKE:
				continue
			var edge_cost := ASTAR_ROAD if (_roads[current.y][current.x] & (1 << dir)) else ASTAR_GRASS
			var tg := cur_g + edge_cost
			if not g_score.has(nb) or tg < g_score[nb]:
				g_score[nb]   = tg
				came_from[nb] = current
				open_set[nb]  = tg + _hex_dist(nb.x, nb.y, tc, tr) * ASTAR_ROAD
	return []


func _min_f(d: Dictionary) -> Vector2i:
	var best: Vector2i
	var best_v := INF
	for k in d:
		if d[k] < best_v:
			best_v = d[k]
			best   = k
	return best


func _hex_dist(ac: int, ar: int, bc: int, br: int) -> float:
	# Offset → cube coords (odd-r shift)
	var aq := ac - (ar - (ar & 1)) / 2
	var as_ := ar
	var ay := -aq - as_
	var bq := bc - (br - (br & 1)) / 2
	var bs := br
	var by := -bq - bs
	return max(abs(aq - bq), max(abs(ay - by), abs(as_ - bs)))


# ── Map query ─────────────────────────────────────────────────────────────────

func get_position_info() -> String:
	const TERRAIN_NAMES := ["平地", "山脉", "湖泊"]
	const DIR_NAMES     := ["东北", "东", "东南", "西南", "西", "西北"]
	var cur: String = TERRAIN_NAMES[_terrain[_unit_row][_unit_col]]
	var road_mask: int = _roads[_unit_row][_unit_col]
	var info := "部队当前位置：(%d,%d) 地形：%s" % [_unit_col, _unit_row, cur]
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


# ── Tooltip ───────────────────────────────────────────────────────────────────

func _create_tooltip() -> void:
	_tooltip_canvas       = CanvasLayer.new()
	_tooltip_canvas.layer = 20
	_tooltip              = PanelContainer.new()
	_tooltip.visible             = false
	_tooltip.custom_minimum_size = Vector2(220, 0)
	_tooltip_canvas.add_child(_tooltip)
	_tooltip_label = RichTextLabel.new()
	_tooltip_label.bbcode_enabled      = true
	_tooltip_label.fit_content         = true
	_tooltip_label.custom_minimum_size = Vector2(210, 0)
	_tooltip.add_child(_tooltip_label)
	get_tree().root.add_child(_tooltip_canvas)
