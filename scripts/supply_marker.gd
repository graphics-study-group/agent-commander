class_name SupplyMarker
extends Node3D

const VISUAL_GROUND_OFFSET_Y := 1.0

@onready var _visual: UnitVisualBase = $Visual


func _ready() -> void:
	_resolve_visual_if_needed()
	_snap_visual_to_ground()


func configure(convoy_id: String, color: Color) -> void:
	name = "Convoy_%s" % convoy_id
	_resolve_visual_if_needed()
	if is_instance_valid(_visual):
		_visual.faction_color = color
		_visual.refresh_faction_color()


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
