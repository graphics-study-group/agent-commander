class_name MapData
extends Resource

@export var version: int = 1
@export var cols: int = 16
@export var rows: int = 16
@export var terrain: Array = []
@export var roads: Array = []
@export var spawn_col: int = 8
@export var spawn_row: int = 8


func validate() -> String:
	if cols <= 0 or rows <= 0:
		return "invalid map size"
	if terrain.size() != rows:
		return "terrain row count mismatch"
	if roads.size() != rows:
		return "roads row count mismatch"
	for r in range(rows):
		if not (terrain[r] is Array) or (terrain[r] as Array).size() != cols:
			return "terrain column count mismatch"
		if not (roads[r] is Array) or (roads[r] as Array).size() != cols:
			return "roads column count mismatch"
		for c in range(cols):
			var t := int((terrain[r] as Array)[c])
			if t < 0 or t > 2:
				return "terrain value out of range"
			var m := int((roads[r] as Array)[c])
			if m < 0 or m > 63:
				return "road bitmask out of range"
	if spawn_col < 0 or spawn_col >= cols or spawn_row < 0 or spawn_row >= rows:
		return "spawn position out of bounds"
	return ""


func is_valid_map() -> bool:
	return validate().is_empty()
