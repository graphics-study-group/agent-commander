extends Node

# Path to the active map data resource.
@export var map_resource_path: String = "res://data/maps/example_map.tres"

var _map_data: HexMapData = null

func _ready() -> void:
    load_map(map_resource_path)

func load_map(path: String) -> void:
    if ResourceLoader.exists(path):
        _map_data = load(path) as HexMapData
    else:
        push_warning("HexMapManager: map resource not found at '%s', starting with empty map." % path)
        _map_data = HexMapData.new()

func get_map_data() -> HexMapData:
    return _map_data

func get_tile(q: int, r: int) -> HexTileData:
    return _map_data.get_tile(q, r) if _map_data else null

func set_tile(q: int, r: int, tile: HexTileData) -> void:
    if _map_data:
        _map_data.set_tile(q, r, tile)

func has_tile(q: int, r: int) -> bool:
    return _map_data.has_tile(q, r) if _map_data else false

func get_all_coords() -> Array:
    return _map_data.get_all_coords() if _map_data else []

func get_neighbors(q: int, r: int) -> Array:
    return HexUtils.get_neighbors(q, r)
