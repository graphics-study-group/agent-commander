extends VBoxContainer

const UnitAgentScript     = preload("res://scripts/unit_agent.gd")
const CommanderAgentScript = preload("res://scripts/commander_agent.gd")
const RULES_PATH := "user://gm_rules.txt"

# Each entry: {unit, agent, color, stat_label, select_btn, collapse_btn}
var _units_list: Array = []
var _selected_idx: int = 0
var _gm_mode := false
var _pending_responses := 0

var _commander_agent: Node = null
var _target_option: OptionButton = null
var _debug_mode: bool = false

var _unit_select_group := ButtonGroup.new()

@onready var _stats_container: VBoxContainer = $UnitStatsContainer
@onready var _output:          RichTextLabel = $OutputContainer/OutputText
@onready var _status:          Label         = $StatusLabel
@onready var _input_text:      TextEdit      = $InputContainer/InputText
@onready var _send_btn:        Button        = $InputContainer/SendButton
@onready var _gm_toggle:       CheckButton   = $InputContainer/GMToggle

const _UNIT_COLORS: Array = [
	Color(0.25, 0.55, 1.0),
	Color(1.0, 0.55, 0.1),
]


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

	var u1 := Unit.new()
	u1.unit_name = "第1装甲旅"
	u1.ATK = 75.0; u1.DEF = 60.0; u1.ORG = 85.0; u1.MORALE = 70.0
	u1.PROF = 65.0; u1.RECON = 40.0; u1.STR = 90.0; u1.SUPPLY = 7.0
	u1.SPEED = 4.0; u1.STAFF = 55.0

	var u2 := Unit.new()
	u2.unit_name = "第2机步旅"
	u2.ATK = 60.0; u2.DEF = 55.0; u2.ORG = 90.0; u2.MORALE = 75.0
	u2.PROF = 60.0; u2.RECON = 50.0; u2.STR = 85.0; u2.SUPPLY = 6.0
	u2.SPEED = 5.0; u2.STAFF = 50.0

	_units_list = [
		{"unit": u1, "agent": null, "color": _UNIT_COLORS[0],
		 "stat_label": null, "select_btn": null, "collapse_btn": null},
		{"unit": u2, "agent": null, "color": _UNIT_COLORS[1],
		 "stat_label": null, "select_btn": null, "collapse_btn": null},
	]

	_send_btn.pressed.connect(_on_send)
	_gm_toggle.toggled.connect(_on_gm_toggled)
	_create_unit_stat_panels()

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
		var entry: Dictionary = _units_list[i]
		var unit: Unit = entry["unit"]

		var hbox := HBoxContainer.new()
		_stats_container.add_child(hbox)

		var sel_btn := Button.new()
		sel_btn.text = unit.unit_name
		sel_btn.toggle_mode = true
		sel_btn.button_group = _unit_select_group
		sel_btn.button_pressed = (i == 0)
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
		_stats_container.add_child(lbl)
		entry["stat_label"] = lbl

		col_btn.pressed.connect(func():
			lbl.visible = not lbl.visible
			col_btn.text = "▼" if lbl.visible else "▶"
		)

		_units_list[i] = entry


func _setup_agent() -> void:
	var hex_map := get_tree().get_first_node_in_group("hex_map")

	# Staggered start positions: unit1 near left-center, unit2 near right-center
	var start_cols := [4, 11]

	for i in range(_units_list.size()):
		var entry: Dictionary = _units_list[i]
		var unit: Unit = entry["unit"]
		var color: Color = entry["color"]

		if hex_map != null and hex_map.has_method("register_unit"):
			hex_map.register_unit(unit, color, start_cols[i], 8)

		var agent: Node = UnitAgentScript.new()
		add_child(agent)
		agent.setup(unit, hex_map, _load_rules())

		var unit_name := unit.unit_name
		var stat_label: RichTextLabel = entry["stat_label"]

		agent.response_ready.connect(func(narrative: String):
			_pending_responses -= 1
			if _pending_responses <= 0:
				_send_btn.disabled = false
				_status.text = ""
			_append("\n[color=yellow][%s 传令兵]:[/color] %s" % [unit_name, _md_to_bbcode(narrative)])
		)

		agent.stats_changed.connect(func(payload: Dictionary):
			var changes: Dictionary = payload.get("changes", payload)
			var reason: String = payload.get("reason", "")
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

		agent.speed_buff_applied.connect(func(kmh: float, hexes: int):
			_append("[color=lime]  >> [%s] 速度临时提升 +%.0f km/h，持续%d格[/color]" % [
				unit.unit_name, kmh, hexes])
		)

		agent.debug_log.connect(func(msg: String):
			_append("[color=gray]%s[/color]" % msg)
		)

		entry["agent"] = agent
		_units_list[i] = entry

		# Add unit name to target selector
		_target_option.add_item(unit_name)
		_target_option.set_item_metadata(_target_option.item_count - 1, i)

	# Commander agent — routes 全军 commands via LLM
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
		_append("\n[color=orange][指挥部]:[/color] %s" % _md_to_bbcode(narrative))
	)


func on_unit_renamed(old_name: String, new_name: String) -> void:
	for entry: Dictionary in _units_list:
		var u: Unit = entry["unit"]
		if u.unit_name == new_name:
			var sel_btn: Button = entry["select_btn"]
			if is_instance_valid(sel_btn):
				sel_btn.text = new_name
			# Update target selector label
			for idx in range(_target_option.item_count):
				if _target_option.get_item_metadata(idx) == _units_list.find(entry):
					_target_option.set_item_text(idx, new_name)
					break
			break


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
		for entry: Dictionary in _units_list:
			var a: Node = entry["agent"]
			if a != null:
				a.debug_mode = _debug_mode
		var state := "开启" if _debug_mode else "关闭"
		_append("[color=gray][系统] DEBUG模式已%s[/color]" % state)
		return

	if _gm_mode:
		_handle_gm_input(msg)
		return

	if _units_list.is_empty():
		return

	var sel_idx := _target_option.selected if _target_option != null else 0
	var sel_meta: int = _target_option.get_item_metadata(sel_idx) if _target_option != null else -1

	_send_btn.disabled = true
	_status.text = "指令传达中..."

	if sel_meta == -1:
		# 全军模式：Commander agent routes via LLM
		_append("\n[color=cyan][统帅 → 全军]:[/color] %s" % msg)
		_pending_responses += 1  # 1 for commander's own response; routing_complete adds unit count
		_status.text = "指挥部分析中..."
		if _commander_agent != null:
			_commander_agent.send_command(msg)
		else:
			_pending_responses -= 1
			_send_btn.disabled = false
			_status.text = ""
	else:
		# Direct to specific unit
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

	if rules.is_empty():
		_append("[color=gray]  当前无额外设定。[/color]")
	else:
		_append("[color=gray]  当前设定列表：\n%s[/color]" % rules)
	_status.text = ""


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


func _md_to_bbcode(text: String) -> String:
	# Block-level: headers and list items (line by line)
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
	# Inline: bold **text** (must run before italic)
	var re := RegEx.new()
	re.compile("\\*\\*(.+?)\\*\\*")
	out = re.sub(out, "[b]$1[/b]", true)
	# Inline: italic *text*
	re.compile("\\*(.+?)\\*")
	out = re.sub(out, "[i]$1[/i]", true)
	# Inline: code `text`
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
