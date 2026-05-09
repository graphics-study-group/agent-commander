extends Node3D

@export var plain_tile_scene: PackedScene = preload("res://scenes/HexTilePlain.tscn")
@export var mountain_tile_scene: PackedScene = preload("res://scenes/HexTileMountain.tscn")
@export var road_tile_scene: PackedScene = preload("res://scenes/HexTileRoad.tscn")

# Holds spawned tile nodes indexed by coord for later lookup.
var _tile_nodes: Dictionary = {}

func _ready() -> void:
	render_map()

func render_map() -> void:
	_clear_tiles()
	var map_data: HexMapData = HexMapManager.get_map_data()
	if map_data == null:
		return
	for coord in map_data.get_all_coords():
		var tile: HexTileData = map_data.get_tile(coord.x, coord.y)
		_spawn_tile(tile)

func _spawn_tile(tile: HexTileData) -> void:
	var tile_scene: PackedScene = _get_scene_for_type(tile.tile_type)
	if tile_scene == null:
		push_warning("HexMapRenderer: no scene configured for tile type %s" % [tile.tile_type])
		return
	var node: Node3D = tile_scene.instantiate()
	var world_pos: Vector3 = HexUtils.axial_to_world(tile.coord.x, tile.coord.y)
	node.position = world_pos
	node.name = "Tile_%d_%d" % [tile.coord.x, tile.coord.y]
	add_child(node)
	_tile_nodes[tile.coord] = node

func _get_scene_for_type(tile_type: HexTileData.TileType) -> PackedScene:
	match tile_type:
		HexTileData.TileType.PLAIN:
			return plain_tile_scene
		HexTileData.TileType.MOUNTAIN:
			return mountain_tile_scene
		HexTileData.TileType.ROAD:
			return road_tile_scene
	return null

func _clear_tiles() -> void:
	for child in get_children():
		child.queue_free()
	_tile_nodes.clear()

# Returns the tile Node3D for the given axial coord, or null.
func get_tile_node(q: int, r: int) -> Node3D:
	return _tile_nodes.get(Vector2i(q, r), null)
