class_name HexTilePlain
extends "res://scripts/hex_tile_base.gd"

@export var hover_color: Color = Color(0.95, 0.95, 0.95, 1.0)
@export var selected_color: Color = Color(0.72, 0.72, 0.72, 1.0)

var _hover_material: StandardMaterial3D
var _selected_material: StandardMaterial3D

func _ready() -> void:
	_hover_material = create_overlay_material(hover_color)
	_selected_material = create_overlay_material(selected_color)
	super._ready()

func apply_default_visual(mesh: MeshInstance3D) -> void:
	mesh.material_overlay = null

func apply_hover_visual(mesh: MeshInstance3D) -> void:
	mesh.material_overlay = _hover_material

func apply_selected_visual(mesh: MeshInstance3D) -> void:
	mesh.material_overlay = _selected_material
	print("Plain tile selected at ", self.tile_coord)
