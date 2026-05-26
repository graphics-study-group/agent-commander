extends Control

const GAME_SCENE_PATH := "res://scenes/game_main.tscn"
const EDITOR_SCENE_PATH := "res://scenes/map_editor.tscn"
const RES_MAP_DIR := "res://maps"
const USER_MAP_DIR := "user://maps"
const GAME_START_BGM_LEAD_SEC := 0.85

@onready var _map_option: OptionButton = $CenterPanel/Panel/PanelVBox/MapRow/MapOption
@onready var _status_label: Label = $CenterPanel/Panel/PanelVBox/StatusLabel
@onready var _refresh_btn: Button = $CenterPanel/Panel/PanelVBox/Buttons/RefreshButton
@onready var _editor_btn: Button = $CenterPanel/Panel/PanelVBox/Buttons/EditorButton
@onready var _play_btn: Button = $CenterPanel/Panel/PanelVBox/Buttons/PlayButton


func _ready() -> void:
	if _map_option == null or _status_label == null or _refresh_btn == null or _editor_btn == null or _play_btn == null:
		push_error("Main menu UI node binding failed. Check main_menu.tscn node paths.")
		return
	var bgm := get_node_or_null("/root/BgmController")
	if bgm != null and bgm.has_method("play_menu_loop"):
		bgm.call("play_menu_loop")

	_refresh_btn.pressed.connect(_on_refresh_pressed)
	_editor_btn.pressed.connect(_on_editor_pressed)
	_play_btn.pressed.connect(_on_play_pressed)
	_refresh_maps()
	if _map_option.item_count == 0:
		_status_label.text = "No map files found. Open the editor first."
	else:
		_status_label.text = "Select a map, then start the game."


func _refresh_maps() -> void:
	_map_option.clear()
	_add_maps_from_dir(RES_MAP_DIR, "res://")
	_add_maps_from_dir(USER_MAP_DIR, "user://")
	if _map_option.item_count > 0:
		_map_option.select(0)


func _add_maps_from_dir(dir_path: String, prefix: String) -> void:
	var files := DirAccess.get_files_at(dir_path)
	files.sort()
	for file_name in files:
		var ext := file_name.get_extension().to_lower()
		if ext != "tres" and ext != "res":
			continue
		var full_path := prefix + "maps/" + file_name
		var label := "%s [%s]" % [file_name.get_basename(), prefix.trim_suffix("/")]
		_map_option.add_item(label)
		_map_option.set_item_metadata(_map_option.item_count - 1, full_path)


func _on_refresh_pressed() -> void:
	_refresh_maps()
	_status_label.text = "Map list refreshed."


func _on_editor_pressed() -> void:
	var bgm := get_node_or_null("/root/BgmController")
	if bgm != null and bgm.has_method("stop_music_smooth"):
		bgm.call("stop_music_smooth")
	get_tree().change_scene_to_file(EDITOR_SCENE_PATH)


func _on_play_pressed() -> void:
	if _map_option.item_count == 0:
		_status_label.text = "No map available."
		return
	var idx := _map_option.selected
	if idx < 0:
		idx = 0
	var map_path := _map_option.get_item_metadata(idx) as String
	if map_path.is_empty():
		_status_label.text = "Invalid map selection."
		return
	var app_state := get_node_or_null("/root/AppState")
	if app_state != null:
		app_state.set("selected_map_path", map_path)
	var bgm := get_node_or_null("/root/BgmController")
	if bgm != null and bgm.has_method("play_game_loop"):
		bgm.call("play_game_loop")
		await get_tree().create_timer(GAME_START_BGM_LEAD_SEC, true, false, true).timeout
	get_tree().change_scene_to_file(GAME_SCENE_PATH)
