extends Node3D

const MAP_PATH := "res://maps/default_map.tres"

@onready var _hex_map: Node = $HexagonalMap
@onready var _ui_layer: CanvasLayer = $UILayer


func _ready() -> void:
	if _hex_map == null:
		push_warning("HexagonalMap node not found.")
		return
	if not _hex_map.has_method("load_map_from_path"):
		push_warning("HexagonalMap node has no load_map_from_path API.")
		return

	var map_path := _resolve_map_path()
	var ok: bool = _hex_map.load_map_from_path(map_path)
	if not ok:
		push_warning("Failed to load map from %s, fallback random map is used." % map_path)
		if _hex_map.has_method("regenerate_random_map"):
			_hex_map.regenerate_random_map()

	_setup_options_overlay()


func _resolve_map_path() -> String:
	var app_state := get_node_or_null("/root/AppState")
	if app_state == null:
		return MAP_PATH
	var selected := String(app_state.get("selected_map_path"))
	if selected.is_empty():
		return MAP_PATH
	return selected


func _setup_options_overlay() -> void:
	var cmd_ui := get_node_or_null("UILayer/CommanderUI") as Control

	# ── Gear button ──────────────────────────────────────────────────────────
	var gear_btn := Button.new()
	gear_btn.text = "⚙ 选项"
	gear_btn.custom_minimum_size = Vector2(80, 32)
	gear_btn.position = Vector2(8, 8)
	_ui_layer.add_child(gear_btn)

	# ── Popup panel ───────────────────────────────────────────────────────────
	var popup := PanelContainer.new()
	popup.custom_minimum_size = Vector2(180, 0)
	popup.position = Vector2(8, 48)
	popup.visible = false
	_ui_layer.add_child(popup)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	popup.add_child(vbox)

	# Font size row
	var font_lbl := Label.new()
	font_lbl.text = "字体大小"
	vbox.add_child(font_lbl)

	var font_hbox := HBoxContainer.new()
	vbox.add_child(font_hbox)

	var font_group := ButtonGroup.new()
	var sizes: Array = [["小", 13], ["中", 16], ["大", 22]]
	for sz: Array in sizes:
		var btn := Button.new()
		btn.text = str(sz[0])
		btn.toggle_mode = true
		btn.button_group = font_group
		btn.button_pressed = (int(sz[1]) == 16)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		font_hbox.add_child(btn)
		btn.pressed.connect(_apply_font_size.bind(cmd_ui, int(sz[1])))

	vbox.add_child(HSeparator.new())

	# Main menu button
	var back_btn := Button.new()
	back_btn.text = "← 主菜单"
	vbox.add_child(back_btn)
	back_btn.pressed.connect(func():
		Engine.time_scale = 1.0
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	)

	gear_btn.pressed.connect(func():
		popup.visible = not popup.visible
	)


func _apply_font_size(cmd_ui: Control, size: int) -> void:
	if not is_instance_valid(cmd_ui):
		return
	var t := Theme.new()
	t.default_font_size = size
	cmd_ui.theme = t
