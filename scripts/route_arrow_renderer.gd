class_name RouteArrowRenderer
extends Node3D

const H_STEP := 1.732
const V_STEP := 1.5
const ROW_OFFSET := 0.866

@export var route_height: float = 1.08
@export var emissive_strength: float = 2.2
@export var triangle_length: float = 0.34
@export var triangle_width: float = 0.22
@export var triangle_spacing: float = 0.42
@export var end_arrow_scale: float = 1.8

@onready var _mesh_instance: MeshInstance3D = $RouteMesh

var _route_material: StandardMaterial3D
var _faction_color: Color = Color(0.25, 0.55, 1.0, 1.0)


func _ready() -> void:
	set_as_top_level(true)
	global_transform = Transform3D.IDENTITY
	_ensure_material()
	clear_route()


func set_faction_color(color: Color) -> void:
	_faction_color = color
	_ensure_material()
	if _route_material != null:
		_route_material.albedo_color = Color(_faction_color.r, _faction_color.g, _faction_color.b, 1.0)
		_route_material.emission = _faction_color
		_route_material.emission_energy_multiplier = emissive_strength


func set_route_from_tiles(tile_points: Array, grid_cols: int, grid_rows: int, faction_color: Color) -> void:
	set_faction_color(faction_color)
	if tile_points.size() < 2:
		clear_route()
		return
	var world_points: Array = []
	for step in tile_points:
		var cr := _extract_col_row(step)
		if cr.x < 0 or cr.y < 0:
			continue
		world_points.append(_hex_to_world(cr.x, cr.y, grid_cols, grid_rows))
	set_route_from_world(world_points, faction_color)


func set_route_from_world(world_points: Array, faction_color: Color) -> void:
	set_faction_color(faction_color)
	if world_points.size() < 2:
		clear_route()
		return
	var points: Array[Vector3] = []
	for p in world_points:
		var wp := _extract_world_point(p)
		if wp == Vector3.INF:
			continue
		wp.y = route_height
		points.append(wp)
	_build_route_mesh(points)


func clear_route() -> void:
	if not is_instance_valid(_mesh_instance):
		return
	_mesh_instance.mesh = null
	visible = false


func _build_route_mesh(points: Array[Vector3]) -> void:
	if not is_instance_valid(_mesh_instance):
		return
	if points.size() < 2:
		clear_route()
		return

	global_transform = Transform3D.IDENTITY

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var last_dir := Vector3.FORWARD
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var dir := _append_segment_triangles(st, a, b)
		if dir.length_squared() > 0.0:
			last_dir = dir

	var end_point := points[points.size() - 1]
	var end_side := Vector3(-last_dir.z, 0.0, last_dir.x)
	_append_arrow_triangle(
		st,
		end_point - last_dir * triangle_length * 0.45,
		last_dir,
		end_side,
		triangle_length * end_arrow_scale,
		triangle_width * end_arrow_scale * 1.1
	)

	var mesh := st.commit()
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = _route_material
	visible = true


func _append_segment_triangles(st: SurfaceTool, a: Vector3, b: Vector3) -> Vector3:
	var delta := b - a
	delta.y = 0.0
	var seg_len := delta.length()
	if seg_len < 0.001:
		return Vector3.ZERO

	var dir := delta / seg_len
	var side := Vector3(-dir.z, 0.0, dir.x)
	var start_offset := triangle_spacing * 0.35
	var end_offset := seg_len - triangle_length * 0.65

	if end_offset < start_offset:
		var c := a + dir * (seg_len * 0.5)
		_append_arrow_triangle(st, c, dir, side, triangle_length, triangle_width)
		return dir

	var dist := start_offset
	while dist <= end_offset:
		var center := a + dir * dist
		_append_arrow_triangle(st, center, dir, side, triangle_length, triangle_width)
		dist += triangle_spacing

	return dir


func _append_arrow_triangle(st: SurfaceTool, center: Vector3, dir: Vector3, side: Vector3, tri_len: float, tri_width: float) -> void:
	var tip := center + dir * (tri_len * 0.55)
	var base_center := center - dir * (tri_len * 0.45)
	var left := base_center + side * (tri_width * 0.5)
	var right := base_center - side * (tri_width * 0.5)
	_append_triangle(st, tip, left, right)


func _append_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_normal(Vector3.UP)
	st.add_vertex(a)
	st.set_normal(Vector3.UP)
	st.add_vertex(b)
	st.set_normal(Vector3.UP)
	st.add_vertex(c)


func _extract_col_row(step: Variant) -> Vector2i:
	if step is Vector2i:
		return step as Vector2i
	if step is Array:
		var arr := step as Array
		if arr.size() >= 2:
			return Vector2i(int(arr[0]), int(arr[1]))
	if step is Dictionary:
		var d := step as Dictionary
		if d.has("col") and d.has("row"):
			return Vector2i(int(d["col"]), int(d["row"]))
	return Vector2i(-1, -1)


func _extract_world_point(p: Variant) -> Vector3:
	if p is Vector3:
		return p as Vector3
	if p is Array:
		var arr := p as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if p is Dictionary:
		var d := p as Dictionary
		if d.has("x") and d.has("y") and d.has("z"):
			return Vector3(float(d["x"]), float(d["y"]), float(d["z"]))
	return Vector3.INF


func _hex_to_world(col: int, row: int, grid_cols: int, grid_rows: int) -> Vector3:
	var cx := (grid_cols - 1) * H_STEP * 0.5
	var cz := (grid_rows - 1) * V_STEP * 0.5
	var x := col * H_STEP + (ROW_OFFSET if row % 2 == 1 else 0.0) - cx
	var z := row * V_STEP - cz
	return Vector3(x, route_height, z)


func _ensure_material() -> void:
	if _route_material != null:
		return
	_route_material = StandardMaterial3D.new()
	_route_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_route_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_route_material.albedo_color = Color(_faction_color.r, _faction_color.g, _faction_color.b, 1.0)
	_route_material.emission_enabled = true
	_route_material.emission = _faction_color
	_route_material.emission_energy_multiplier = emissive_strength
	if is_instance_valid(_mesh_instance):
		_mesh_instance.material_override = _route_material
