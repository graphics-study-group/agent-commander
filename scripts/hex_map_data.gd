class_name HexMapData
extends Resource

# Dictionary: Vector2i(q, r) -> HexTileData
@export var tiles: Dictionary = {}

func get_tile(q: int, r: int) -> HexTileData:
	return tiles.get(Vector2i(q, r), null)

func set_tile(q: int, r: int, tile: HexTileData) -> void:
	tile.coord = Vector2i(q, r)
	tiles[Vector2i(q, r)] = tile

func has_tile(q: int, r: int) -> bool:
	return tiles.has(Vector2i(q, r))

func remove_tile(q: int, r: int) -> void:
	tiles.erase(Vector2i(q, r))

func get_all_coords() -> Array:
	return tiles.keys()
