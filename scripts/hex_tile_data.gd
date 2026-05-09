class_name HexTileData
extends Resource

enum TileType {
	PLAIN,
	MOUNTAIN,
	ROAD,
}

@export var coord: Vector2i = Vector2i.ZERO
@export var tile_type: TileType = TileType.PLAIN
