class_name MountainTile
extends TileBase


func is_passable() -> bool:
	return false


func get_terrain_name() -> String:
	return "Mountain"


func _get_terrain_color() -> Color:
	return Color(0.52, 0.40, 0.28)
