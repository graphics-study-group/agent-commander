class_name WaterTile
extends TileBase


func is_passable() -> bool:
	return false


func get_terrain_name() -> String:
	return "Water"
