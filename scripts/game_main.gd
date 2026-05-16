extends Node3D

const MAP_PATH := "res://maps/default_map.tres"

@onready var _hex_map: Node = $HexagonalMap


func _ready() -> void:
	if _hex_map == null:
		push_warning("HexagonalMap node not found.")
		return
	if not _hex_map.has_method("load_map_from_path"):
		push_warning("HexagonalMap node has no load_map_from_path API.")
		return

	var ok: bool = _hex_map.load_map_from_path(MAP_PATH)
	if not ok:
		push_warning("Failed to load map from %s, fallback random map is used." % MAP_PATH)
		if _hex_map.has_method("regenerate_random_map"):
			_hex_map.regenerate_random_map()
