class_name MapData
extends Resource

@export var version: int = 1
@export var cols: int = 16
@export var rows: int = 16
@export var tile_types: Array = []
@export var terrain: Array = []
@export var roads: Array = []
@export var spawn_col: int = 8
@export var spawn_row: int = 8
@export var cell_region: Array = []
@export var player_unit_count: int = 2
@export var enemy_unit_count: int = 2


func validate() -> String:
	if cols <= 0 or rows <= 0:
		return "invalid map size"
	var tiles := get_tile_types_grid()
	if tiles.size() != rows:
		return "tile row count mismatch"
	if roads.size() != rows:
		return "roads row count mismatch"
	for r in range(rows):
		if not (tiles[r] is Array) or (tiles[r] as Array).size() != cols:
			return "tile column count mismatch"
		if not (roads[r] is Array) or (roads[r] as Array).size() != cols:
			return "roads column count mismatch"
		for c in range(cols):
			var t := int((tiles[r] as Array)[c])
			if t < 0 or t > 4:
				return "tile value out of range"
			var m := int((roads[r] as Array)[c])
			if m < 0 or m > 63:
				return "road bitmask out of range"
	if spawn_col < 0 or spawn_col >= cols or spawn_row < 0 or spawn_row >= rows:
		return "spawn position out of bounds"
	return ""


func is_valid_map() -> bool:
	return validate().is_empty()


func get_tile_types_grid() -> Array:
	if tile_types.size() > 0:
		return tile_types
	return terrain


func set_tile_types_grid(grid: Array) -> void:
	tile_types = _copy_grid(grid)
	terrain = _copy_grid(grid)


func _copy_grid(src: Array) -> Array:
	var out: Array = []
	for row in src:
		out.append((row as Array).duplicate())
	return out
