class_name SupplyMarker
extends Node3D

const VISUAL_GROUND_OFFSET_Y := 1.0

@onready var _visual: UnitVisualBase = $Visual
@onready var _route_renderer: RouteArrowRenderer = $RouteArrowRenderer

var _route_color: Color = Color(0.25, 0.55, 1.0, 1.0)


func _ready() -> void:
	_resolve_visual_if_needed()
	_resolve_route_renderer_if_needed()
	_snap_visual_to_ground()


func configure(convoy_id: String, color: Color) -> void:
	name = "Convoy_%s" % convoy_id
	_route_color = color
	_resolve_visual_if_needed()
	_resolve_route_renderer_if_needed()
	if is_instance_valid(_visual):
		_visual.faction_color = color
		_visual.refresh_faction_color()
	if is_instance_valid(_route_renderer):
		_route_renderer.set_faction_color(color)


func set_route_color(color: Color) -> void:
	_route_color = color
	_resolve_route_renderer_if_needed()
	if is_instance_valid(_route_renderer):
		_route_renderer.set_faction_color(color)


func set_route_tiles(path_tiles: Array, grid_cols: int, grid_rows: int) -> void:
	_resolve_route_renderer_if_needed()
	if not is_instance_valid(_route_renderer):
		return
	_route_renderer.set_route_from_tiles(path_tiles, grid_cols, grid_rows, _route_color)


func clear_route() -> void:
	_resolve_route_renderer_if_needed()
	if not is_instance_valid(_route_renderer):
		return
	_route_renderer.clear_route()


func face_towards(target_world_pos: Vector3) -> void:
	var from := global_position
	var flat_target := Vector3(target_world_pos.x, from.y, target_world_pos.z)
	if from.distance_squared_to(flat_target) < 0.000001:
		return
	# Keep rotation on horizontal plane only.
	look_at(flat_target, Vector3.UP)

func _iter_descendants(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			if c is Node:
				out.append(c)
				stack.append(c)
	return out

func _snap_visual_to_ground() -> void:
	_resolve_visual_if_needed()
	if not is_instance_valid(_visual):
		return
	var p := _visual.position
	p.y = VISUAL_GROUND_OFFSET_Y
	_visual.position = p


func _resolve_visual_if_needed() -> void:
	if is_instance_valid(_visual):
		return
	_visual = get_node_or_null("Visual") as UnitVisualBase


func _resolve_route_renderer_if_needed() -> void:
	if is_instance_valid(_route_renderer):
		return
	_route_renderer = get_node_or_null("RouteArrowRenderer") as RouteArrowRenderer
