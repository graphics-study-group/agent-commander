extends VBoxContainer

const UnitAgentScript      = preload("res://scripts/unit_agent.gd")
const CommanderAgentScript = preload("res://scripts/commander_agent.gd")
const EnemyAgentScript     = preload("res://scripts/enemy_agent.gd")
const BattleAgentScript    = preload("res://scripts/battle_agent.gd")
const RULES_PATH := "user://gm_rules.txt"

# Each entry: {unit, agent, color, stat_label, select_btn, collapse_btn}
var _units_list: Array = []
var _selected_idx: int = 0
var _gm_mode := false
var _pending_responses := 0

var _commander_agent: Node = null
var _enemy_agent: Node = null
var _enemy_entries: Array = []
var _target_option: OptionButton = null
var _debug_mode: bool = false

# battle_id → {agent, attacker_units: Array[String], defender_units: Array[String], attacker_is_player, col, row}
var _active_battles: Dictionary = {}
# unit_name → real_unfreeze_time (winner cleanup pause)
var _battle_cleanup_timers: Dictionary = {}

var _unit_select_group := ButtonGroup.new()

# Supply convoy system
# {id, target_unit, is_player, col, row, path, path_idx, step_elapsed}
var _convoys: Array = []
var _next_convoy_id: int = 0
var _supply_day_elapsed: float = 0.0

# Victory condition
var _initial_enemy_str: float = 0.0
var _victory_occupation_time: float = 0.0
var _victory_achieved: bool = false
var _game_over: bool = false
var _initial_player_str: float = 0.0

@onready var _stats_container: VBoxContainer = $UnitStatsContainer
@onready var _output:          RichTextLabel = $OutputContainer/OutputText
@onready var _status:          Label         = $StatusLabel
@onready var _input_text:      TextEdit      = $InputContainer/InputText
@onready var _send_btn:        Button        = $InputContainer/SendButton
@onready var _gm_toggle:       CheckButton   = $InputContainer/GMToggle


func _ready() -> void:
	add_to_group("commander_ui")

	# Build target selector and insert as first child of InputContainer
	_target_option = OptionButton.new()
	_target_option.add_item("全军")
	_target_option.set_item_metadata(0, -1)
	_target_option.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_target_option.custom_minimum_size = Vector2(90, 0)
	$InputContainer.add_child(_target_option)
	$InputContainer.move_child(_target_option, 0)

	_send_btn.pressed.connect(_on_send)
	_gm_toggle.toggled.connect(_on_gm_toggled)

	# Time speed slider
	var time_row := HBoxContainer.new()
	var time_lbl := Label.new()
	time_lbl.text = "时间流速:"
	time_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	time_row.add_child(time_lbl)
	var time_slider := HSlider.new()
	time_slider.min_value = 1.0
	time_slider.max_value = 300.0
	time_slider.value = 1.0
	time_slider.step = 1.0
	time_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_row.add_child(time_slider)
	var time_pct_lbl := Label.new()
	time_pct_lbl.text = "1%"
	time_pct_lbl.custom_minimum_size = Vector2(45, 0)
	time_pct_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	time_row.add_child(time_pct_lbl)
	time_slider.value_changed.connect(func(v: float):
		Engine.time_scale = v / 100.0
		time_pct_lbl.text = "%d%%" % int(v)
	)
	Engine.time_scale = 0.01
	add_child(time_row)
	move_child(time_row, $InputContainer.get_index())

	_append("[color=gray]== 战略统帅 ==\n用自然语言下达战术命令，按 Enter 或「发送」提交，Shift+Enter 换行。\n切换「裁判」模式可修改游戏设定。[/color]")

	call_deferred("_setup_agent")


func _create_unit_stat_panels() -> void:
	for child in _stats_container.get_children():
		child.queue_free()

	_unit_select_group.pressed.connect(func(btn: BaseButton):
		for i in range(_units_list.size()):
			if _units_list[i]["select_btn"] == btn:
				_selected_idx = i
				break
	)

	for i in range(_units_list.size()):
		_add_unit_panel(_units_list[i])


func _add_unit_panel(entry: Dictionary) -> void:
	var unit: Unit = entry["unit"]

	var hbox := HBoxContainer.new()
	_stats_container.add_child(hbox)
	entry["panel_hbox"] = hbox

	var sel_btn := Button.new()
	sel_btn.text = unit.unit_name
	sel_btn.toggle_mode = true
	sel_btn.button_group = _unit_select_group
	sel_btn.button_pressed = (_units_list.find(entry) == 0)
	sel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sel_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	hbox.add_child(sel_btn)
	entry["select_btn"] = sel_btn

	var col_btn := Button.new()
	col_btn.text = "▼"
	col_btn.custom_minimum_size = Vector2(32, 0)
	hbox.add_child(col_btn)
	entry["collapse_btn"] = col_btn

	var lbl := RichTextLabel.new()
	lbl.bbcode_enabled = true
	lbl.fit_content = true
	lbl.custom_minimum_size = Vector2(0, 90)
	lbl.text = unit.get_display_text()
	lbl.visible = false
	_stats_container.add_child(lbl)
	entry["stat_label"] = lbl

	col_btn.text = "▶"
	col_btn.pressed.connect(func():
		lbl.visible = not lbl.visible
		col_btn.text = "▼" if lbl.visible else "▶"
	)


func _rebuild_target_option() -> void:
	_target_option.clear()
	_target_option.add_item("全军")
	_target_option.set_item_metadata(0, -1)
	for i in range(_units_list.size()):
		var u: Unit = _units_list[i]["unit"]
		_target_option.add_item(u.unit_name)
		_target_option.set_item_metadata(_target_option.item_count - 1, i)


func _setup_agent() -> void:
	var hex_map := get_tree().get_first_node_in_group("hex_map")

	var player_count := 2
	var enemy_count  := 2
	if hex_map != null:
		player_count = maxi(1, hex_map.player_unit_count)
		enemy_count  = maxi(1, hex_map.enemy_unit_count)

	# Load templates (populated from map data, or auto-generated defaults)
	var templates: Array = []
	if hex_map != null and hex_map.has_method("ensure_unit_templates"):
		hex_map.ensure_unit_templates()
		templates = hex_map.get_unit_templates()

	var player_tmpls := templates.filter(func(t): return not bool(t.get("is_enemy", false)))
	var enemy_tmpls  := templates.filter(func(t): return bool(t.get("is_enemy", false)))

	# ── Player units ──
	var player_color := Color(0.25, 0.55, 1.0)

	for i in range(player_count):
		var u := _unit_from_template(player_tmpls, i, false)
		_units_list.append({
			"unit": u, "agent": null, "color": player_color,
			"stat_label": null, "select_btn": null, "collapse_btn": null, "panel_hbox": null
		})

	_create_unit_stat_panels()

	for i in range(_units_list.size()):
		var entry: Dictionary = _units_list[i]
		var unit: Unit        = entry["unit"]
		var tmpl: Dictionary  = player_tmpls[i] if i < player_tmpls.size() else {}
		var col: int          = int(tmpl.get("col", 0))
		var row: int          = int(tmpl.get("row", (4 + i * 3) % 16))

		if hex_map != null and hex_map.has_method("register_unit"):
			hex_map.register_unit(unit, player_color, col, row, false)
		entry["spawn_pos"] = Vector2i(col, row)

		var agent: Node = UnitAgentScript.new()
		add_child(agent)
		agent.setup(unit, hex_map, _load_rules())

		var unit_name  := unit.unit_name
		var stat_label: RichTextLabel = entry["stat_label"]

		agent.response_ready.connect(func(narrative: String):
			_pending_responses -= 1
			if _pending_responses <= 0:
				_send_btn.disabled = false
				_status.text = ""
			_append("\n[color=yellow][%s 电台]:[/color] %s" % [unit_name, _md_to_bbcode(narrative)])
		)

		agent.stats_changed.connect(func(payload: Dictionary):
			var changes: Dictionary = payload.get("changes", payload)
			var reason: String      = payload.get("reason", "")
			if is_instance_valid(stat_label):
				stat_label.text = unit.get_display_text()
			if hex_map != null and hex_map.has_method("update_unit_org"):
				hex_map.update_unit_org(unit.unit_name, unit.ORG)
			var delta_text := _format_changes(unit, changes)
			if reason.is_empty():
				_append("[color=green]  >> [%s] 数值变化: %s[/color]" % [unit.unit_name, delta_text])
			else:
				_append("[color=green]  >> [%s] 数值变化 [%s]: %s[/color]" % [unit.unit_name, reason, delta_text])
		)

		agent.debug_log.connect(func(msg: String):
			_append("[color=gray]%s[/color]" % msg)
		)

		entry["agent"] = agent
		_units_list[i] = entry

		_target_option.add_item(unit_name)
		_target_option.set_item_metadata(_target_option.item_count - 1, i)

	# ── Commander agent ──
	_commander_agent = CommanderAgentScript.new()
	add_child(_commander_agent)
	_commander_agent.setup(_units_list, hex_map, _load_rules())

	_commander_agent.routing_complete.connect(func(count: int):
		_pending_responses += count
		if _pending_responses <= 0:
			_send_btn.disabled = false
			_status.text = ""
	)

	_commander_agent.response_ready.connect(func(narrative: String):
		_pending_responses -= 1
		if _pending_responses <= 0:
			_send_btn.disabled = false
			_status.text = ""
		_append("\n[color=orange][传令兵]:[/color] %s" % _md_to_bbcode(narrative))
	)

	# ── Enemy units ──
	var enemy_color := Color(0.85, 0.15, 0.15)
	var max_col: int = (hex_map.get_map_size().x - 1) if (hex_map != null and hex_map.has_method("get_map_size")) else 15

	for i in range(enemy_count):
		var eu := _unit_from_template(enemy_tmpls, i, true)
		var etmpl: Dictionary = enemy_tmpls[i] if i < enemy_tmpls.size() else {}
		var ecol: int = int(etmpl.get("col", max_col))
		var erow: int = int(etmpl.get("row", (4 + i * 3) % 16))

		if hex_map != null and hex_map.has_method("register_unit"):
			hex_map.register_unit(eu, enemy_color, ecol, erow, true)

		var eagent: Node = UnitAgentScript.new()
		add_child(eagent)
		eagent.setup(eu, hex_map, _load_rules())

		# Silent health bar update for enemy units
		eagent.stats_changed.connect(func(_payload: Dictionary):
			if hex_map != null and hex_map.has_method("update_unit_org"):
				hex_map.update_unit_org(eu.unit_name, eu.ORG)
		)

		_enemy_entries.append({"unit": eu, "agent": eagent, "spawn_pos": Vector2i(max_col, erow)})

	# ── Enemy agent ──
	_initial_enemy_str = 0.0
	for entry in _enemy_entries:
		var eu: Unit = entry.get("unit") as Unit
		if eu != null:
			_initial_enemy_str += eu.STR

	_initial_player_str = 0.0
	for entry in _units_list:
		var pu: Unit = entry.get("unit") as Unit
		if pu != null:
			_initial_player_str += pu.STR

	_enemy_agent = EnemyAgentScript.new()
	add_child(_enemy_agent)
	_enemy_agent.setup(_units_list, _enemy_entries, hex_map, _load_rules())

	_enemy_agent.response_ready.connect(func(narrative: String):
		_append("[color=red][敌方传令兵]:[/color] %s" % _md_to_bbcode(narrative))
	)

	_enemy_agent.debug_log.connect(func(msg: String):
		_append("[color=gray]%s[/color]" % msg)
	)

	# Trigger initial enemy strategy assessment
	_enemy_agent.receive_event("game_start", {"message": "游戏开始，制定红方初始战略部署"})

	# Hex coordinate right-click → insert into chat
	if hex_map != null and hex_map.has_signal("hex_coord_selected"):
		hex_map.hex_coord_selected.connect(func(col: int, row: int):
			_input_text.insert_text_at_caret("(%d,%d)" % [col, row])
		)

	# Combat collision detection
	if hex_map != null and hex_map.has_signal("unit_collision"):
		hex_map.unit_collision.connect(_on_unit_collision)


# ── Unit factory helpers ──────────────────────────────────────────────────────

func _unit_from_template(tmpls: Array, i: int, is_enemy: bool) -> Unit:
	var u := Unit.new()
	if i < tmpls.size():
		var t: Dictionary = tmpls[i]
		u.unit_name = t.get("name", ("红%d部" % (i + 1)) if is_enemy else ("第%d部队" % (i + 1)))
		u.ATK = float(t.get("ATK", 68.0 if is_enemy else 70.0))
		u.DEF = float(t.get("DEF", 58.0 if is_enemy else 60.0))
		u.ORG = float(t.get("ORG", 80.0 if is_enemy else 85.0))
		u.MORALE = float(t.get("MORALE", 70.0 if is_enemy else 72.0))
		u.PROF = float(t.get("PROF", 60.0 if is_enemy else 63.0))
		u.RECON = float(t.get("RECON", 48.0 if is_enemy else 45.0))
		u.STR = float(t.get("STR", 85.0 if is_enemy else 88.0))
		u.SUPPLY = float(t.get("SUPPLY", 3.0))
		u.SPEED = float(t.get("SPEED", 5.0 if is_enemy else 4.5))
		u.STAFF = float(t.get("STAFF", 50.0 if is_enemy else 52.0))
	elif is_enemy:
		u = _make_enemy_unit(i)
	else:
		u = _make_player_unit(i)
	return u


func _make_player_unit(i: int) -> Unit:
	var names := ["第1装甲旅", "第2机步旅", "第3步兵旅", "第4炮兵旅", "第5特战旅"]
	var u := Unit.new()
	u.unit_name = names[i] if i < names.size() else ("第%d部队" % (i + 1))
	u.ATK = 70.0; u.DEF = 60.0; u.ORG = 85.0; u.MORALE = 72.0
	u.PROF = 63.0; u.RECON = 45.0; u.STR = 88.0; u.SUPPLY = 3.0
	u.SPEED = 4.5; u.STAFF = 52.0
	return u


func _make_enemy_unit(i: int) -> Unit:
	var names := ["赤甲一部", "赤甲二部", "赤甲三部", "赤甲四部", "赤甲五部"]
	var u := Unit.new()
	u.unit_name = names[i] if i < names.size() else ("红%d部" % (i + 1))
	u.ATK = 68.0; u.DEF = 58.0; u.ORG = 80.0; u.MORALE = 70.0
	u.PROF = 60.0; u.RECON = 48.0; u.STR = 85.0; u.SUPPLY = 3.0
	u.SPEED = 5.0; u.STAFF = 50.0
	return u


func _spread_start_rows(count: int) -> Array:
	if count <= 0:
		return []
	if count == 1:
		return [8]
	var rows: Array = []
	for i in range(count):
		rows.append(int(2.0 + 11.0 * float(i) / float(count - 1)))
	return rows


# ── Army split ────────────────────────────────────────────────────────────────

func do_split(source_unit: Unit, _source_agent: Node, fragments: Array,
		api_history: Array) -> Dictionary:
	if source_unit == null or fragments.size() < 2:
		return {"error": "参数无效"}

	var hex_map := get_tree().get_first_node_in_group("hex_map")
	var extra_rules := _load_rules()

	# Source position
	var src_pos := Vector2i(4, 8)
	if hex_map != null and hex_map.has_method("get_unit_pos"):
		src_pos = hex_map.get_unit_pos(source_unit.unit_name)

	# Find source entry
	var src_entry: Dictionary = {}
	var src_idx := -1
	for i in range(_units_list.size()):
		if _units_list[i].get("unit") == source_unit:
			src_entry = _units_list[i]
			src_idx = i
			break
	if src_entry.is_empty():
		return {"error": "未找到源部队"}

	# Remove source UI panel
	var hbox: Node = src_entry.get("panel_hbox")
	var lbl_node: Node = src_entry.get("stat_label")
	if is_instance_valid(hbox):
		hbox.queue_free()
	if is_instance_valid(lbl_node):
		lbl_node.queue_free()

	# Remove source from map
	if hex_map != null and hex_map.has_method("unregister_unit"):
		hex_map.unregister_unit(source_unit.unit_name)

	_units_list.remove_at(src_idx)

	# Create fragment units and agents
	var player_color := Color(0.25, 0.55, 1.0)
	var new_names: Array = []

	for frag in fragments:
		var fname: String = frag.get("name", "子部队")
		var frac: float = clampf(float(frag.get("str_fraction", 1.0 / fragments.size())), 0.01, 1.0)

		var fu := Unit.new()
		fu.unit_name = fname
		fu.ATK    = source_unit.ATK
		fu.DEF    = source_unit.DEF
		fu.ORG    = source_unit.ORG
		fu.MORALE = source_unit.MORALE
		fu.PROF   = source_unit.PROF
		fu.RECON  = source_unit.RECON
		fu.STR    = source_unit.STR * frac
		fu.SUPPLY = source_unit.SUPPLY * frac
		fu.SPEED  = source_unit.SPEED
		fu.STAFF  = source_unit.STAFF

		if hex_map != null and hex_map.has_method("register_unit"):
			hex_map.register_unit(fu, player_color, src_pos.x, src_pos.y, false)

		var fagent: Node = UnitAgentScript.new()
		add_child(fagent)
		fagent.setup(fu, hex_map, extra_rules)
		fagent.debug_mode = _debug_mode
		fagent.inject_history(api_history)

		var new_entry := {
			"unit": fu, "agent": fagent, "color": player_color,
			"stat_label": null, "select_btn": null, "collapse_btn": null, "panel_hbox": null
		}
		_units_list.append(new_entry)
		_add_unit_panel(new_entry)

		var unit_name_cap := fname
		fagent.response_ready.connect(func(narrative: String):
			_pending_responses -= 1
			if _pending_responses <= 0:
				_send_btn.disabled = false
				_status.text = ""
			_append("\n[color=yellow][%s 电台]:[/color] %s" % [unit_name_cap, _md_to_bbcode(narrative)])
		)

		fagent.stats_changed.connect(func(payload: Dictionary):
			var changes: Dictionary = payload.get("changes", payload)
			var reason_str: String  = payload.get("reason", "")
			var sl: RichTextLabel = new_entry.get("stat_label") as RichTextLabel
			if is_instance_valid(sl):
				sl.text = fu.get_display_text()
			if hex_map != null and hex_map.has_method("update_unit_org"):
				hex_map.update_unit_org(fu.unit_name, fu.ORG)
			var delta_text := _format_changes(fu, changes)
			if reason_str.is_empty():
				_append("[color=green]  >> [%s] 数值变化: %s[/color]" % [fu.unit_name, delta_text])
			else:
				_append("[color=green]  >> [%s] 数值变化 [%s]: %s[/color]" % [fu.unit_name, reason_str, delta_text])
		)

		fagent.debug_log.connect(func(msg: String):
			_append("[color=gray]%s[/color]" % msg)
		)

		new_names.append(fname)

	_rebuild_target_option()

	if _commander_agent != null and _commander_agent.has_method("reload_rules"):
		_commander_agent.reload_rules(extra_rules)

	# Notify new units
	for i in range(_units_list.size() - fragments.size(), _units_list.size()):
		var fagent: Node = _units_list[i]["agent"]
		if fagent != null:
			fagent.receive_event("unit_split", {
				"message": "本部队由[%s]拆分而来，继承其作战记忆，现独立指挥。" % source_unit.unit_name
			})

	return {"split": true, "source": source_unit.unit_name, "fragments": new_names}


# ── Rename callback ───────────────────────────────────────────────────────────

func on_unit_renamed(old_name: String, new_name: String) -> void:
	for entry: Dictionary in _units_list:
		var u: Unit = entry["unit"]
		if u.unit_name == new_name:
			var sel_btn: Button = entry["select_btn"]
			if is_instance_valid(sel_btn):
				sel_btn.text = new_name
			for idx in range(_target_option.item_count):
				if _target_option.get_item_metadata(idx) == _units_list.find(entry):
					_target_option.set_item_text(idx, new_name)
					break
			break


# ── Input handling ────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _input_text.has_focus() and not _input_text.get_global_rect().has_point(event.global_position):
			_input_text.release_focus()
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER and not event.shift_pressed:
			if _input_text.has_focus():
				get_viewport().set_input_as_handled()
				_on_send()


func _on_gm_toggled(on: bool) -> void:
	_gm_mode = on
	if on:
		_input_text.placeholder_text = "输入裁判设定... (Enter 提交，\"清除所有设定\" 重置)"
		_status.text = "[裁判模式] 设定持久保存，重启后依然生效"
	else:
		_input_text.placeholder_text = "输入战术指令... (Enter 发送，Shift+Enter 换行)"
		_status.text = ""


func _on_send() -> void:
	var msg := _input_text.text.strip_edges()
	if msg.is_empty():
		return
	_input_text.text = ""
	_input_text.release_focus()

	# Slash commands
	if msg == "/debug":
		_debug_mode = not _debug_mode
		var dbg_hex_map := get_tree().get_first_node_in_group("hex_map")
		if dbg_hex_map != null:
			dbg_hex_map.debug_mode = _debug_mode
		for entry: Dictionary in _units_list:
			var a: Node = entry["agent"]
			if a != null:
				a.debug_mode = _debug_mode
		if _enemy_agent != null:
			_enemy_agent.debug_mode = _debug_mode
		if _commander_agent != null and _commander_agent.has_method("reload_rules"):
			_commander_agent.debug_mode = _debug_mode
			_commander_agent.reload_rules(_load_rules())
		var state := "开启" if _debug_mode else "关闭"
		_append("[color=gray][系统] DEBUG模式已%s[/color]" % state)
		return

	if _gm_mode:
		_handle_gm_input(msg)
		return

	if _units_list.is_empty():
		return

	var sel_idx  := _target_option.selected if _target_option != null else 0
	var sel_meta: int = _target_option.get_item_metadata(sel_idx) if _target_option != null else -1

	_send_btn.disabled = true
	_status.text = "指令传达中..."

	if sel_meta == -1:
		_append("\n[color=cyan][统帅 → 全军]:[/color] %s" % msg)
		_pending_responses += 1
		_status.text = "指挥部分析中..."
		if _commander_agent != null:
			_commander_agent.send_command(msg)
		else:
			_pending_responses -= 1
			_send_btn.disabled = false
			_status.text = ""
	else:
		var entry: Dictionary = _units_list[sel_meta]
		var unit: Unit = entry["unit"]
		var agent: Node = entry["agent"]
		_append("\n[color=cyan][统帅 → %s]:[/color] %s" % [unit.unit_name, msg])
		if agent != null:
			_pending_responses += 1
			agent.receive_event("player_command", {"message": msg})
		else:
			_send_btn.disabled = false
			_status.text = ""
		# Forward to battle agent if this unit is in combat
		var battle_entry := _get_battle_for_unit(unit.unit_name)
		if not battle_entry.is_empty():
			var ba: Node = battle_entry.get("agent") as Node
			if ba != null and ba.has_method("receive_player_command"):
				ba.receive_player_command(unit.unit_name, msg)


func _handle_gm_input(msg: String) -> void:
	if msg == "清除所有设定":
		_clear_rules()
		_append("\n[color=magenta][裁判]:[/color] 所有设定已清除。")
	else:
		_save_rule(msg)
		_append("\n[color=magenta][裁判]:[/color] 设定已保存：%s" % msg)

	var rules := _load_rules()
	for entry: Dictionary in _units_list:
		var agent: Node = entry["agent"]
		if agent != null and agent.has_method("reload_rules"):
			agent.reload_rules(rules)
	if _commander_agent != null:
		_commander_agent.reload_rules(rules)
	if _enemy_agent != null:
		_enemy_agent.reload_rules(rules)

	if rules.is_empty():
		_append("[color=gray]  当前无额外设定。[/color]")
	else:
		_append("[color=gray]  当前设定列表：\n%s[/color]" % rules)
	_status.text = ""


# ── Rules persistence ─────────────────────────────────────────────────────────

func _save_rule(rule: String) -> void:
	var fa: FileAccess
	if FileAccess.file_exists(RULES_PATH):
		fa = FileAccess.open(RULES_PATH, FileAccess.READ_WRITE)
		if fa != null:
			fa.seek_end()
	else:
		fa = FileAccess.open(RULES_PATH, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_line(rule)
	fa.close()


func _clear_rules() -> void:
	var fa := FileAccess.open(RULES_PATH, FileAccess.WRITE)
	if fa != null:
		fa.close()


func _load_rules() -> String:
	if not FileAccess.file_exists(RULES_PATH):
		return ""
	var fa := FileAccess.open(RULES_PATH, FileAccess.READ)
	if fa == null:
		return ""
	var content := fa.get_as_text().strip_edges()
	fa.close()
	return content


# ── Markdown → BBCode ─────────────────────────────────────────────────────────

func _md_to_bbcode(text: String) -> String:
	var lines := text.split("\n")
	for i in range(lines.size()):
		var line := lines[i]
		if line.begins_with("### "):
			lines[i] = "[b]" + line.substr(4) + "[/b]"
		elif line.begins_with("## "):
			lines[i] = "[b]" + line.substr(3) + "[/b]"
		elif line.begins_with("# "):
			lines[i] = "[b]" + line.substr(2) + "[/b]"
		elif line.begins_with("- ") or line.begins_with("* "):
			lines[i] = "• " + line.substr(2)
		elif line.strip_edges() == "---":
			lines[i] = "─────────"
	var out := "\n".join(lines)
	var re := RegEx.new()
	re.compile("\\*\\*(.+?)\\*\\*")
	out = re.sub(out, "[b]$1[/b]", true)
	re.compile("\\*(.+?)\\*")
	out = re.sub(out, "[i]$1[/i]", true)
	re.compile("`([^`]+)`")
	out = re.sub(out, "[code]$1[/code]", true)
	return out


func _append(text: String) -> void:
	_output.append_text(text + "\n")


func _format_changes(unit: Unit, changes: Dictionary) -> String:
	var parts: Array[String] = []
	for key: String in changes.keys():
		var new_val := float(unit.get(key))
		var delta   := float(changes[key])
		var old_val := new_val - delta
		var color   := "green" if delta > 0 else "red"
		parts.append("[color=%s]%s %.0f→%.0f(%s%.0f)[/color]" % [
			color, key, old_val, new_val, "+" if delta >= 0 else "", delta
		])
	return "  ".join(parts)


# ── _process ─────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	# Winner cleanup timers (wall-clock)
	if not _battle_cleanup_timers.is_empty():
		var now := Time.get_unix_time_from_system()
		var to_unfreeze: Array = []
		for unit_name: String in _battle_cleanup_timers:
			if now >= float(_battle_cleanup_timers[unit_name]):
				to_unfreeze.append(unit_name)
		for unit_name: String in to_unfreeze:
			_battle_cleanup_timers.erase(unit_name)
			var hm := get_tree().get_first_node_in_group("hex_map")
			if hm != null and hm.has_method("unfreeze_unit"):
				hm.unfreeze_unit(unit_name)

	# Supply day (game time)
	_supply_day_elapsed += delta
	if _supply_day_elapsed >= 150.0:
		_supply_day_elapsed -= 150.0
		_on_supply_day()

	# Advance convoys
	_advance_convoys(delta)

	# Victory condition
	if _game_over:
		return
	if not _victory_achieved:
		_check_victory(delta)


# ── Combat collision handler ──────────────────────────────────────────────────

func _on_unit_collision(mover_name: String, resident_name: String) -> void:
	# If mover is already in a battle (shouldn't happen since frozen, but guard anyway)
	if not _get_battle_id_for_unit(mover_name).is_empty():
		return
	# If resident is in a battle, mover is reinforcing
	var existing_bid := _get_battle_id_for_unit(resident_name)
	if not existing_bid.is_empty():
		_reinforce_battle(existing_bid, mover_name)
		return
	# New battle
	_start_battle(mover_name, resident_name)


func _start_battle(attacker_name: String, defender_name: String) -> void:
	var hex_map := get_tree().get_first_node_in_group("hex_map")

	var atk_unit := _find_any_unit(attacker_name)
	var def_unit := _find_any_unit(defender_name)
	if atk_unit == null or def_unit == null:
		return

	var atk_is_player := _is_player_unit(attacker_name)
	var def_is_player := _is_player_unit(defender_name)

	var battle_pos := Vector2i.ZERO
	if hex_map != null and hex_map.has_method("get_unit_pos"):
		battle_pos = hex_map.get_unit_pos(attacker_name)

	var bid := "battle_%s_vs_%s" % [attacker_name, defender_name]

	var ba: Node = BattleAgentScript.new()
	add_child(ba)
	ba.battle_id = bid
	ba.setup([atk_unit], [def_unit], atk_is_player, def_is_player,
		battle_pos.x, battle_pos.y, hex_map, _load_rules())

	ba.combat_report.connect(_on_combat_report)
	ba.combat_ended.connect(_on_combat_ended)
	ba.stats_updated.connect(_on_battle_stats_updated)
	ba.debug_log.connect(func(msg: String): _append("[color=gray]%s[/color]" % msg))

	_active_battles[bid] = {
		"agent":            ba,
		"attacker_units":   [attacker_name],
		"defender_units":   [defender_name],
		"attacker_is_player": atk_is_player,
		"col":              battle_pos.x,
		"row":              battle_pos.y
	}

	# Freeze both units on the map
	if hex_map != null and hex_map.has_method("freeze_unit"):
		hex_map.freeze_unit(attacker_name)
		hex_map.freeze_unit(defender_name)

	# Notify unit agents
	var atk_agent := _find_any_agent(attacker_name)
	var def_agent := _find_any_agent(defender_name)
	if atk_agent != null and atk_agent.has_method("enter_battle"):
		atk_agent.enter_battle(bid)
	if def_agent != null and def_agent.has_method("enter_battle"):
		def_agent.enter_battle(bid)

	# Notify enemy agent if one side is enemy
	if _enemy_agent != null:
		if not atk_is_player or not def_is_player:
			var enemy_unit_name := defender_name if atk_is_player else attacker_name
			_enemy_agent.receive_event("combat_start", {
				"battle_id":    bid,
				"enemy_unit":   enemy_unit_name,
				"opponent":     attacker_name if not atk_is_player else defender_name,
				"message":      "你的部队 %s 与敌方部队 %s 进入战斗，你可以通过 send_combat_order 发送战术指令。" % [
					enemy_unit_name,
					attacker_name if not atk_is_player else defender_name
				]
			})

	var side_a := "蓝方" if atk_is_player else "红方"
	var side_b := "蓝方" if def_is_player else "红方"
	_append("\n[color=orange][⚔ 战斗开始][/color] %s（%s）vs %s（%s）" % [
		attacker_name, side_a, defender_name, side_b
	])
	ba.start()


func _reinforce_battle(battle_id: String, mover_name: String) -> void:
	var b: Dictionary = _active_battles.get(battle_id, {})
	if b.is_empty():
		return
	var ba: Node = b.get("agent") as Node
	if ba == null:
		return
	var mover_unit := _find_any_unit(mover_name)
	if mover_unit == null:
		return

	var hex_map := get_tree().get_first_node_in_group("hex_map")

	# Determine which side mover joins (same faction = same side)
	var mover_is_player := _is_player_unit(mover_name)
	var attacker_is_player: bool = b.get("attacker_is_player", false)
	var is_attacker_side := (mover_is_player == attacker_is_player)

	if is_attacker_side:
		b["attacker_units"].append(mover_name)
	else:
		b["defender_units"].append(mover_name)

	# Freeze reinforcing unit
	if hex_map != null and hex_map.has_method("freeze_unit"):
		hex_map.freeze_unit(mover_name)

	# Notify unit_agent
	var mover_agent := _find_any_agent(mover_name)
	if mover_agent != null and mover_agent.has_method("enter_battle"):
		mover_agent.enter_battle(battle_id)

	# Notify battle_agent
	if ba.has_method("reinforce"):
		ba.reinforce(mover_unit, is_attacker_side)

	# Notify enemy agent
	if _enemy_agent != null:
		var side_str := "进攻方" if is_attacker_side else "防御方"
		_enemy_agent.receive_event("combat_reinforcement", {
			"battle_id": battle_id,
			"unit_name": mover_name,
			"side":      "attacker" if is_attacker_side else "defender",
			"message":   "部队 %s 加入了战斗 %s 的%s。" % [mover_name, battle_id, side_str]
		})

	var mover_side_lbl := "蓝方" if mover_is_player else "红方"
	var side_lbl := "进攻方" if is_attacker_side else "防御方"
	_append("\n[color=orange][⚔ 增援到达][/color] %s（%s）加入 %s" % [mover_name, mover_side_lbl, side_lbl])


func _on_combat_report(battle_id: String, narrative: String) -> void:
	_append("\n[color=orange][战报·%s][/color] %s" % [battle_id, narrative])
	var b: Dictionary = _active_battles.get(battle_id, {})
	if not b.is_empty():
		for n: String in b.get("attacker_units", []):
			_refresh_stat_label_for(n)
		for n: String in b.get("defender_units", []):
			_refresh_stat_label_for(n)


func _on_combat_ended(battle_id: String, winner_side: String) -> void:
	var b: Dictionary = _active_battles.get(battle_id, {})
	if b.is_empty():
		return

	var attacker_units: Array = b.get("attacker_units", [])
	var defender_units: Array = b.get("defender_units", [])
	var all_units: Array = attacker_units + defender_units

	var winner_units: Array
	var loser_units: Array
	match winner_side:
		"attacker":
			winner_units = attacker_units.duplicate()
			loser_units  = defender_units.duplicate()
		"defender":
			winner_units = defender_units.duplicate()
			loser_units  = attacker_units.duplicate()
		_:  # draw
			winner_units = []
			loser_units  = []

	var hex_map := get_tree().get_first_node_in_group("hex_map")
	var battle_col: int = b.get("col", 0)
	var battle_row: int = b.get("row", 0)

	for unit_name: String in all_units:
		var is_winner := unit_name in winner_units
		var is_draw   := winner_side == "draw"
		var outcome   := "draw" if is_draw else ("victory" if is_winner else "defeat")

		var agent := _find_any_agent(unit_name)
		if agent != null and agent.has_method("exit_battle"):
			agent.exit_battle(outcome, battle_id)

		if is_draw:
			if hex_map != null and hex_map.has_method("unfreeze_unit"):
				hex_map.unfreeze_unit(unit_name)
		elif is_winner:
			# Winners: freeze briefly then auto-unfreeze
			if hex_map != null and hex_map.has_method("freeze_unit"):
				hex_map.freeze_unit(unit_name)
			_battle_cleanup_timers[unit_name] = Time.get_unix_time_from_system() + 5.0
		else:
			# Losers: unfreeze, retreat to separate random adjacent hex, speed boost
			if hex_map != null and hex_map.has_method("unfreeze_unit"):
				hex_map.unfreeze_unit(unit_name)
			var adj := Vector2i(-1, -1)
			if hex_map != null and hex_map.has_method("find_adjacent_passable"):
				adj = hex_map.find_adjacent_passable(battle_col, battle_row)
			if adj != Vector2i(-1, -1) and hex_map != null and hex_map.has_method("set_move_path"):
				hex_map.set_move_path(unit_name, [[adj.x, adj.y]])
			if agent != null and agent.has_method("apply_stats_immediate"):
				agent.apply_stats_immediate({
					"changes": {"SPEED": 5}, "reason": "撤退加速", "duration": 20.0
				})

	# Notify enemy agent
	if _enemy_agent != null:
		_enemy_agent.receive_event("combat_update", {
			"battle_id":    battle_id,
			"winner_side":  winner_side,
			"winner_units": winner_units,
			"loser_units":  loser_units,
			"message":      "战斗 %s 结束，胜方：%s" % [battle_id, winner_side]
		})

	for unit_name: String in all_units:
		_refresh_stat_label_for(unit_name)

	_append("\n[color=orange][⚔ 战斗结束][/color] 胜方：%s" % winner_side)

	var ba: Node = b.get("agent") as Node
	_active_battles.erase(battle_id)
	if ba != null:
		ba.queue_free()


func _on_battle_stats_updated(unit_name: String) -> void:
	_refresh_stat_label_for(unit_name)
	# Update health bar on map
	var hex_map := get_tree().get_first_node_in_group("hex_map")
	if hex_map != null and hex_map.has_method("update_unit_org"):
		var u := _find_any_unit(unit_name)
		if u != null:
			hex_map.update_unit_org(unit_name, u.ORG)


# ── Combat forwarding helpers ─────────────────────────────────────────────────

func forward_enemy_combat_order(battle_id: String, unit_name: String, order: String) -> Dictionary:
	var b: Dictionary = _active_battles.get(battle_id, {})
	if b.is_empty():
		return {"error": "战斗 %s 不存在或已结束" % battle_id}
	var ba: Node = b.get("agent") as Node
	if ba == null:
		return {"error": "战斗agent不可用"}
	ba.receive_enemy_command(unit_name, order)
	return {"ok": true, "forwarded": order}


func _get_battle_for_unit(unit_name: String) -> Dictionary:
	for bid: String in _active_battles:
		var b: Dictionary = _active_battles[bid]
		if unit_name in b.get("attacker_units", []) or unit_name in b.get("defender_units", []):
			return b
	return {}


func _get_battle_id_for_unit(unit_name: String) -> String:
	for bid: String in _active_battles:
		var b: Dictionary = _active_battles[bid]
		if unit_name in b.get("attacker_units", []) or unit_name in b.get("defender_units", []):
			return bid
	return ""


# ── Unit lookup helpers ───────────────────────────────────────────────────────

func _is_player_unit(unit_name: String) -> bool:
	for entry: Dictionary in _units_list:
		var u: Unit = entry.get("unit") as Unit
		if u != null and u.unit_name == unit_name:
			return true
	return false


func _find_any_unit(unit_name: String) -> Unit:
	for entry: Dictionary in _units_list:
		var u: Unit = entry.get("unit") as Unit
		if u != null and u.unit_name == unit_name:
			return u
	for entry: Dictionary in _enemy_entries:
		var u: Unit = entry.get("unit") as Unit
		if u != null and u.unit_name == unit_name:
			return u
	return null


func _find_any_agent(unit_name: String) -> Node:
	for entry: Dictionary in _units_list:
		var u: Unit = entry.get("unit") as Unit
		if u != null and u.unit_name == unit_name:
			return entry.get("agent") as Node
	for entry: Dictionary in _enemy_entries:
		var u: Unit = entry.get("unit") as Unit
		if u != null and u.unit_name == unit_name:
			return entry.get("agent") as Node
	return null


func _refresh_stat_label_for(unit_name: String) -> void:
	for entry: Dictionary in _units_list:
		var u: Unit = entry.get("unit") as Unit
		if u != null and u.unit_name == unit_name:
			var lbl: RichTextLabel = entry.get("stat_label") as RichTextLabel
			if lbl != null and is_instance_valid(lbl):
				lbl.text = u.get_display_text()
			return


# ── Supply convoy system ──────────────────────────────────────────────────────

func _on_supply_day() -> void:
	var hex_map := get_tree().get_first_node_in_group("hex_map")
	# Consume SUPPLY for all units
	for entry: Dictionary in _units_list:
		var u: Unit = entry.get("unit") as Unit
		if u != null:
			u.SUPPLY = maxf(0.0, u.SUPPLY - 1.0)
			var lbl: RichTextLabel = entry.get("stat_label") as RichTextLabel
			if is_instance_valid(lbl):
				lbl.text = u.get_display_text()
	for entry: Dictionary in _enemy_entries:
		var u: Unit = entry.get("unit") as Unit
		if u != null:
			u.SUPPLY = maxf(0.0, u.SUPPLY - 1.0)
	# Spawn convoys
	for entry: Dictionary in _units_list:
		var u: Unit = entry.get("unit") as Unit
		if u != null:
			_spawn_convoy(u, true, entry, hex_map)
	for entry: Dictionary in _enemy_entries:
		var u: Unit = entry.get("unit") as Unit
		if u != null:
			_spawn_convoy(u, false, entry, hex_map)


func _spawn_convoy(target_unit: Unit, is_player: bool, entry: Dictionary, hex_map: Node) -> void:
	if hex_map == null or not hex_map.has_method("calc_path"):
		return
	var spawn_pos: Vector2i = entry.get("spawn_pos", Vector2i(-1, -1))
	if spawn_pos == Vector2i(-1, -1):
		return
	var target_pos: Vector2i = hex_map.get_unit_pos(target_unit.unit_name)
	# Verify path exists
	var path: Array = hex_map.calc_path(spawn_pos.x, spawn_pos.y, target_pos.x, target_pos.y)
	if path.is_empty() and not (spawn_pos == target_pos):
		return
	var convoy_id := _next_convoy_id
	_next_convoy_id += 1
	_convoys.append({
		"id":               convoy_id,
		"target_unit_name": target_unit.unit_name,
		"is_player":        is_player,
		"col":              spawn_pos.x,
		"row":              spawn_pos.y,
		"step_elapsed":     0.0
	})
	if hex_map.has_method("add_convoy_marker"):
		var convoy_color := Color(0.25, 0.55, 1.0) if is_player else Color(0.85, 0.15, 0.15)
		hex_map.add_convoy_marker(str(convoy_id), spawn_pos.x, spawn_pos.y, convoy_color)


func _advance_convoys(game_delta: float) -> void:
	if _convoys.is_empty():
		return
	var hex_map := get_tree().get_first_node_in_group("hex_map")
	if hex_map == null or not hex_map.has_method("calc_path"):
		return

	var to_remove: Array = []

	for convoy: Dictionary in _convoys:
		# Check if any enemy is already on this convoy hex (unit walked onto it)
		var cur_col_c := int(convoy["col"])
		var cur_row_c := int(convoy["row"])
		var is_player_c: bool = convoy["is_player"]
		var interceptors_c := _enemy_entries if is_player_c else _units_list
		var instant_intercepted := false
		for ientry: Dictionary in interceptors_c:
			var iu: Unit = ientry.get("unit") as Unit
			if iu == null: continue
			var ipos: Vector2i = hex_map.get_unit_pos(iu.unit_name)
			if ipos.x == cur_col_c and ipos.y == cur_row_c:
				iu.SUPPLY = minf(7.0, iu.SUPPLY + 1.0)
				to_remove.append(convoy)
				instant_intercepted = true
				break
		if instant_intercepted:
			continue
		convoy["step_elapsed"] = float(convoy.get("step_elapsed", 0.0)) + game_delta
		if float(convoy["step_elapsed"]) < 10.0:
			continue
		convoy["step_elapsed"] = 0.0

		var target_unit := _find_any_unit(convoy["target_unit_name"])
		if target_unit == null:
			to_remove.append(convoy)
			continue

		var cur_col := int(convoy["col"])
		var cur_row := int(convoy["row"])
		var target_pos: Vector2i = hex_map.get_unit_pos(target_unit.unit_name)

		# Already at target — deliver
		if cur_col == target_pos.x and cur_row == target_pos.y:
			target_unit.SUPPLY = minf(7.0, target_unit.SUPPLY + 1.0)
			_refresh_stat_label_for(target_unit.unit_name)
			to_remove.append(convoy)
			continue

		# Calculate next step
		var path: Array = hex_map.calc_path(cur_col, cur_row, target_pos.x, target_pos.y)
		if path.is_empty():
			to_remove.append(convoy)
			continue

		# Determine next cell (path may or may not include current pos)
		var step_idx := 0
		if path.size() > 0:
			var first = path[0]
			if int(first[0]) == cur_col and int(first[1]) == cur_row:
				step_idx = 1
		if step_idx >= path.size():
			to_remove.append(convoy)
			continue

		var nxt = path[step_idx]
		var next_col := int(nxt[0])
		var next_row := int(nxt[1])

		convoy["col"] = next_col
		convoy["row"] = next_row
		if hex_map.has_method("update_convoy_marker"):
			hex_map.update_convoy_marker(str(convoy["id"]), next_col, next_row)

		# Check interception by enemy units at new position
		var is_player: bool = convoy["is_player"]
		var interceptors := _enemy_entries if is_player else _units_list
		var intercepted := false
		for ientry: Dictionary in interceptors:
			var iu: Unit = ientry.get("unit") as Unit
			if iu == null:
				continue
			var ipos: Vector2i = hex_map.get_unit_pos(iu.unit_name)
			if ipos.x == next_col and ipos.y == next_row:
				iu.SUPPLY = minf(7.0, iu.SUPPLY + 1.0)
				intercepted = true
				to_remove.append(convoy)
				break
		if intercepted:
			continue

		# Check if reached target
		if next_col == target_pos.x and next_row == target_pos.y:
			target_unit.SUPPLY = minf(7.0, target_unit.SUPPLY + 1.0)
			_refresh_stat_label_for(target_unit.unit_name)
			to_remove.append(convoy)

	for convoy: Dictionary in to_remove:
		_convoys.erase(convoy)
		if hex_map.has_method("remove_convoy_marker"):
			hex_map.remove_convoy_marker(str(convoy["id"]))


# ── Victory condition ─────────────────────────────────────────────────────────

func _check_victory(delta: float) -> void:
	var hex_map := get_tree().get_first_node_in_group("hex_map")
	if hex_map == null or not hex_map.has_method("get_victory_city"):
		return
	var victory_city: Vector2i = hex_map.get_victory_city()
	if victory_city == Vector2i(-1, -1):
		return

	var player_at_city := false
	for entry: Dictionary in _units_list:
		var u: Unit = entry.get("unit") as Unit
		if u == null: continue
		if hex_map.get_unit_pos(u.unit_name) == victory_city and _get_battle_id_for_unit(u.unit_name).is_empty():
			player_at_city = true
			break

	var enemy_at_city := false
	for entry: Dictionary in _enemy_entries:
		var u: Unit = entry.get("unit") as Unit
		if u == null: continue
		if hex_map.get_unit_pos(u.unit_name) == victory_city and _get_battle_id_for_unit(u.unit_name).is_empty():
			enemy_at_city = true
			break

	if player_at_city:
		_victory_occupation_time += delta
		if _victory_occupation_time >= 1050.0:
			var enemy_str: float = 0.0
			for e: Dictionary in _enemy_entries:
				var u: Unit = e.get("unit") as Unit
				if u != null: enemy_str += u.STR
			if _initial_enemy_str > 0.0 and enemy_str < _initial_enemy_str * 0.5:
				_trigger_game_over("blue")
	elif enemy_at_city:
		_victory_occupation_time -= delta
		if _victory_occupation_time <= -1050.0:
			var player_str: float = 0.0
			for e: Dictionary in _units_list:
				var u: Unit = e.get("unit") as Unit
				if u != null: player_str += u.STR
			if _initial_player_str > 0.0 and player_str < _initial_player_str * 0.5:
				_trigger_game_over("red")
	else:
		_victory_occupation_time = move_toward(_victory_occupation_time, 0.0, delta)


func _trigger_game_over(winner: String) -> void:
	_victory_achieved = true
	_game_over = true
	_send_btn.disabled = true
	if _target_option != null:
		_target_option.disabled = true
	var label: String = "蓝方胜利" if winner == "blue" else "红方胜利"
	_show_victory_overlay(label)


func _show_victory_overlay(label_text: String) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	get_tree().root.add_child(layer)

	var panel := ColorRect.new()
	panel.color = Color(0.0, 0.0, 0.0, 0.72)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 32)
	layer.add_child(vbox)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var is_blue := label_text.begins_with("蓝")
	lbl.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0) if is_blue else Color(1.0, 0.3, 0.3))
	lbl.add_theme_font_size_override("font_size", 72)
	vbox.add_child(lbl)

	var btn := Button.new()
	btn.text = "返回主菜单"
	btn.custom_minimum_size = Vector2(200, 60)
	btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	vbox.add_child(btn)
