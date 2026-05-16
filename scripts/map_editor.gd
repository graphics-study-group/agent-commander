extends Node3D

const SAVE_RES_PATH := "res://maps/default_map.tres"
const SAVE_USER_PATH := "user://maps/default_map.tres"

@onready var _hex_map: Node = $HexagonalMap
@onready var _status_label: Label = $UILayer/EditorUI/VBox/StatusLabel
@onready var _regen_btn: Button = $UILayer/EditorUI/VBox/GenerateButton
@onready var _save_btn: Button = $UILayer/EditorUI/VBox/SaveButton


func _ready() -> void:
	_regen_btn.pressed.connect(_on_generate_pressed)
	_save_btn.pressed.connect(_on_save_pressed)
	_on_generate_pressed()


func _on_generate_pressed() -> void:
	if _hex_map != null and _hex_map.has_method("regenerate_random_map"):
		_hex_map.regenerate_random_map()
		_status_label.text = "Random map generated."
	else:
		_status_label.text = "Hex map node is missing regenerate API."


func _on_save_pressed() -> void:
	if _hex_map == null or not _hex_map.has_method("export_map_data"):
		_status_label.text = "Hex map node is missing export API."
		return

	var map_data: Resource = _hex_map.export_map_data()
	if map_data == null:
		_status_label.text = "Export failed: no map data."
		return

	var err := ResourceSaver.save(map_data, SAVE_RES_PATH)
	if err != OK:
		_status_label.text = "Save failed (res): %d" % err
		return

	DirAccess.make_dir_recursive_absolute("user://maps")
	var user_err := ResourceSaver.save(map_data, SAVE_USER_PATH)
	if user_err == OK:
		_status_label.text = "Saved: %s and %s" % [SAVE_RES_PATH, SAVE_USER_PATH]
	else:
		_status_label.text = "Saved: %s (user export failed: %d)" % [SAVE_RES_PATH, user_err]
