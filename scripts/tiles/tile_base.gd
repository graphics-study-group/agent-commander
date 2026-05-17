class_name TileBase
extends Node3D

signal unit_entered(unit: Object)
signal unit_exited(unit: Object)

var grid_col := 0
var grid_row := 0
var terrain_type := 0
var road_mask := 0
var map_ref: Node

func _ready() -> void:
	_on_tile_configured()
	_on_road_data_changed()


func configure(col: int, row: int, tile_type: int, roads: int, map_node: Node) -> void:
	grid_col = col
	grid_row = row
	terrain_type = tile_type
	map_ref = map_node
	road_mask = roads
	_on_tile_configured()
	_on_road_data_changed()


func set_road_mask(roads: int) -> void:
	road_mask = roads
	_on_road_data_changed()


func has_any_road() -> bool:
	return road_mask != 0


func has_road_in_direction(dir: int) -> bool:
	if dir < 0 or dir > 5:
		return false
	return (road_mask & (1 << dir)) != 0


func get_neighbor_coord(dir: int) -> Vector2i:
	if map_ref == null or not map_ref.has_method("get_neighbor"):
		return Vector2i(-1, -1)
	return map_ref.call("get_neighbor", grid_col, grid_row, dir)


func get_neighbor_tile_type(dir: int) -> int:
	if map_ref == null or not map_ref.has_method("get_tile_type_at"):
		return -1
	var nb := get_neighbor_coord(dir)
	return int(map_ref.call("get_tile_type_at", nb.x, nb.y))


func get_neighbor_road_mask(dir: int) -> int:
	if map_ref == null or not map_ref.has_method("get_road_mask_at"):
		return 0
	var nb := get_neighbor_coord(dir)
	return int(map_ref.call("get_road_mask_at", nb.x, nb.y))


func set_selected(selected: bool) -> void:
	scale = Vector3.ONE * (1.05 if selected else 1.0)


func on_unit_enter(unit: Object) -> void:
	unit_entered.emit(unit)


func on_unit_leave(unit: Object) -> void:
	unit_exited.emit(unit)


func is_passable() -> bool:
	return true


func get_terrain_name() -> String:
	return "Plain"


func _on_tile_configured() -> void:
	pass


func _on_road_data_changed() -> void:
	pass
