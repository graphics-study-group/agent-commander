class_name SupplyMarker
extends Node3D

@onready var _visual: UnitVisualBase = $Visual
@onready var _name_label: Label3D = $NameLabel


func configure(convoy_id: String, color: Color) -> void:
	name = "Convoy_%s" % convoy_id
	if is_instance_valid(_name_label):
		_name_label.text = "Supply"
	if is_instance_valid(_visual):
		_visual.faction_color = color
		_visual.refresh_faction_color()
	_apply_visual_glow(color)


func _apply_visual_glow(color: Color) -> void:
	if not is_instance_valid(_visual):
		return
	for node in _iter_descendants(_visual):
		if not (node is GeometryInstance3D):
			continue
		var gi := node as GeometryInstance3D
		var mat: StandardMaterial3D = null
		if gi is MeshInstance3D:
			var mi := gi as MeshInstance3D
			var src := mi.get_active_material(0)
			if src is StandardMaterial3D:
				mat = (src as StandardMaterial3D).duplicate(true)
		if mat == null:
			mat = StandardMaterial3D.new()
		mat.emission_enabled = true
		mat.emission = color * 0.45
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		gi.material_override = mat


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
