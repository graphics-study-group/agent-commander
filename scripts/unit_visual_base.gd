@tool
class_name UnitVisualBase
extends Node3D

@export var faction_color: Color = Color(0.25, 0.55, 1.0, 1.0):
	set(value):
		faction_color = value
		_apply_faction_color()

var _refresh_timer: float = 0.0
var _last_signature: String = ""
var _material_cache: Dictionary = {}

func _ready() -> void:
	child_entered_tree.connect(_on_child_tree_changed)
	child_exiting_tree.connect(_on_child_tree_changed)
	set_process(Engine.is_editor_hint())
	_apply_faction_color()

func _notification(what: int) -> void:
	if what == NOTIFICATION_CHILD_ORDER_CHANGED:
		_apply_faction_color()

func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	_refresh_timer += delta
	if _refresh_timer < 0.2:
		return
	_refresh_timer = 0.0
	var sig := _build_signature()
	if sig != _last_signature:
		_last_signature = sig
		_apply_faction_color()

func refresh_faction_color() -> void:
	_apply_faction_color()

func _on_child_tree_changed(_node: Node) -> void:
	_apply_faction_color()

func _apply_faction_color() -> void:
	if not is_inside_tree():
		return
	for child in _iter_descendants(self):
		if not _needs_faction_color(child):
			continue
		if child is GeometryInstance3D:
			var instance_child := child as GeometryInstance3D
			var mat := _get_or_create_material(instance_child)
			mat.albedo_color = faction_color
			instance_child.material_override = mat

func _build_signature() -> String:
	var parts: Array[String] = [str(faction_color)]
	for child in _iter_descendants(self):
		if child.has_meta("needs_faction_color"):
			var meta_val: Variant = child.get_meta("needs_faction_color")
			parts.append("%s:%s:%d" % [child.get_path(), str(meta_val), child.get_class().hash()])
	return "|".join(parts)

func _iter_descendants(root: Node) -> Array:
	var result: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			if c is Node:
				result.append(c)
				stack.append(c)
	return result

func _needs_faction_color(node: Node) -> bool:
	if not node.has_meta("needs_faction_color"):
		return false
	var meta_val: Variant = node.get_meta("needs_faction_color")
	return typeof(meta_val) == TYPE_BOOL and bool(meta_val)

func _get_or_create_material(instance_node: GeometryInstance3D) -> StandardMaterial3D:
	var key := instance_node.get_instance_id()
	if _material_cache.has(key):
		return _material_cache[key] as StandardMaterial3D
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = false
	mat.metallic = 0.0
	mat.roughness = 1.0
	_material_cache[key] = mat
	return mat
