class_name WaterTile
extends TileBase


func is_passable() -> bool:
	return false


func get_terrain_name() -> String:
	return "Water"


func _get_terrain_color() -> Color:
	return Color(0.20, 0.45, 0.85)
