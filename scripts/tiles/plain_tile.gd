class_name PlainTile
extends TileBase

@export var road_hex_radius := 1.0
@export var road_height := 0.28
@export var road_width := 0.16


func get_terrain_name() -> String:
	return "Plain"


func _on_tile_configured() -> void:
	_update_road_renderer()


func _on_road_data_changed() -> void:
	_update_road_renderer()


func _update_road_renderer() -> void:
	var rr := get_node_or_null("VisualRoot/RoadRenderer") as HexRoadRenderer
	if rr == null:
		return
	rr.set_hex_metrics(road_hex_radius, road_height)
	rr.set_road_width_value(road_width)
	rr.setup_roads(get_neighbor_types(), road_mask, get_neighbor_road_masks())
