extends VBoxContainer

const DeepSeekAPI = preload("res://scripts/deepseek_api.gd")

# Movement commands (direction 0-5 = NE/E/SE/SW/W/NW, steps ≥ 1)
signal move_command(direction: int, steps: int)
# Pathfinding command (target hex coordinates)
signal pathfind_command(col: int, row: int)

const SYSTEM_PROMPT := """你是一个战场指令解析系统，以"传令兵汇报"口吻呈现战场实况。玩家用自然语言下达命令，你的职责是将其转换为结构化指令，并给出简短叙述。

【属性说明与范围——数值变化必须在此范围内】
ATK 攻击力(0-200)  DEF 防御力(0-200)
ORG 组织度(0-100)：部队凝聚力/战斗力
MORALE 士气(0-100)：战斗意志
PROF 熟练度(0-100)  RECON 侦察力(0-100)
STR 兵力%(0-100)  SUPPLY 补给天数(0-7)
SPEED 移动速度(km/h, 0-20)：相邻格距离40km，实时行进时间=40÷速度(秒)，道路速度×2
STAFF 参谋能力(0-100)

【高强度操作参考代价（单次操作，绝不能将属性归零！）】
强行军：ORG -5~-15，MORALE -3~-8，SUPPLY -0.3~-0.8；并可附带临时速度加成
强攻/夜袭：ORG -10~-20，MORALE -5~-15，STR -2~-5，SUPPLY -0.5~-1

【数值规则——严格遵守】
- 普通移动、侦察、驻扎等日常指令：unit_changes 必须为 {}
- 指令模糊/矛盾/明显错误：仅 STAFF -1，其余不变
- 高强度操作代价按上表小幅扣除，可附 speed_buff 给予临时速度提升
- 【严禁】将任何属性一次性清零或接近归零
- unit_changes 中填写【变化量】（正数增加，负数减少），而非最终值
- 【严禁】在无预设敌军时描述交战、伤亡；可有低烈度随机事件

【移动指令——程序负责路径计算，你无需也不能计算路径】
1. 方向前进：{"type":"MOVE_DIR","direction":<0-5>,"steps":<格数>}
   方向：0=东北  1=东  2=东南  3=西南  4=西  5=西北
2. 目标移动（仅当玩家明确指定坐标时使用）：{"type":"MOVE_TO","col":<0-15>,"row":<0-15>}

【叙事要求】
- 40-100字，以传令兵汇报口吻，描述命令内容与当前态势
- 只可引用消息中提供的当前位置地形数据，【严禁】捏造或推测沿途及目标地形

返回格式（只输出 JSON，不加代码块标记）：
{
  "narrative": "传令兵汇报（40-100字）",
  "unit_changes": {},
  "move_action": {},
  "speed_buff": {"kmh": <额外速度>, "hexes": <持续格数>}
}
move_action 无移动则省略。speed_buff 仅在高强度行军时附加，参考值：急行军 +4~8 km/h 持续3~6格。"""

var unit: Unit
var _api: Node

@onready var _unit_stats: RichTextLabel = $UnitStats
@onready var _output:     RichTextLabel = $OutputContainer/OutputText
@onready var _status:     Label         = $StatusLabel
@onready var _input_text: TextEdit      = $InputContainer/InputText
@onready var _send_btn:   Button        = $InputContainer/SendButton


func _ready() -> void:
	add_to_group("commander_ui")

	unit = Unit.new()
	unit.unit_name = "第1装甲旅"
	unit.ATK    = 75.0
	unit.DEF    = 60.0
	unit.ORG    = 85.0
	unit.MORALE = 70.0
	unit.PROF   = 65.0
	unit.RECON  = 40.0
	unit.STR    = 90.0
	unit.SUPPLY = 7.0
	unit.SPEED  = 4.0
	unit.STAFF  = 55.0

	_api = DeepSeekAPI.new()
	add_child(_api)
	_api.set_system_prompt(SYSTEM_PROMPT)
	_api.response_received.connect(_on_response)
	_api.request_failed.connect(_on_error)

	_send_btn.pressed.connect(_on_send)

	_update_stats()
	_append("[color=gray]== 战略统帅 ==\n用自然语言输入战术命令，按「发送」或 Ctrl+Enter 提交。[/color]")


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER and event.ctrl_pressed:
			get_viewport().set_input_as_handled()
			_on_send()


func _on_send() -> void:
	var msg := _input_text.text.strip_edges()
	if msg.is_empty():
		return

	# Collect live map data to ground the AI in reality
	var map_info := ""
	var hex_map := get_tree().get_first_node_in_group("hex_map")
	if hex_map != null and hex_map.has_method("get_position_info"):
		map_info = hex_map.get_position_info() + "\n"

	var full_msg := "%s当前部队状态：%s\n\n玩家指令：%s" % [map_info, unit.get_state_summary(), msg]

	_append("\n[color=cyan][玩家]:[/color] %s" % msg)
	_input_text.text   = ""
	_send_btn.disabled = true
	_status.text       = "指令传达中..."
	_api.send_message(full_msg)


func _on_response(content: String) -> void:
	_send_btn.disabled = false
	_status.text = ""

	var json_str := _extract_json(content)
	var json := JSON.new()
	if json.parse(json_str) == OK:
		var data: Variant = json.get_data()
		if data is Dictionary:
			var narrative: String = data.get("narrative", content)
			_append("\n[color=yellow][传令兵]:[/color] %s" % narrative)

			var changes = data.get("unit_changes", {})
			if changes is Dictionary and not changes.is_empty():
				var delta_text := _format_changes(changes)
				unit.apply_changes(changes)
				_update_stats()
				_append("[color=green]  >> 数值变化: %s[/color]" % delta_text)

			# Execute temporary speed buff if AI issued one
			var speed_buff = data.get("speed_buff", null)
			if speed_buff is Dictionary:
				var extra := float(speed_buff.get("kmh", 0.0))
				var hexes := int(speed_buff.get("hexes", 0))
				if extra > 0.0 and hexes > 0:
					var hm := get_tree().get_first_node_in_group("hex_map")
					if hm != null and hm.has_method("apply_speed_buff"):
						hm.apply_speed_buff(extra, hexes)
						_append("[color=lime]  >> 速度临时提升 +%.0f km/h，持续%d格[/color]" % [extra, hexes])

				# Execute AI-suggested move action
			var move_act = data.get("move_action", null)
			if move_act is Dictionary:
				_exec_ai_move(move_act)
			return

	_append("\n[color=yellow][传令兵]:[/color] %s" % content)


func _exec_ai_move(act: Dictionary) -> void:
	var t: String = act.get("type", "")
	match t:
		"MOVE_DIR":
			var dir   := int(act.get("direction", -1))
			var steps := int(act.get("steps", 1))
			if dir >= 0 and dir <= 5 and steps >= 1:
				_append("[color=lime]  >> 部队执行命令：方向%d，前进%d格[/color]" % [dir, steps])
				move_command.emit(dir, steps)
		"MOVE_TO":
			var col := int(act.get("col", -1))
			var row := int(act.get("row", -1))
			if col >= 0 and col <= 15 and row >= 0 and row <= 15:
				_append("[color=lime]  >> 部队执行命令：向(%d,%d)进发[/color]" % [col, row])
				pathfind_command.emit(col, row)


func _on_error(error: String) -> void:
	_send_btn.disabled = false
	_status.text = ""
	_append("\n[color=red][错误]: %s[/color]" % error)


func _update_stats() -> void:
	_unit_stats.text = unit.get_display_text()


func _append(text: String) -> void:
	_output.append_text(text + "\n")


func _format_changes(changes: Dictionary) -> String:
	var parts: Array[String] = []
	for key: String in changes.keys():
		var old_val := unit.get(key) as float
		var delta   := float(changes[key])
		var new_val := old_val + delta
		var color   := "green" if delta > 0 else "red"
		parts.append("[color=%s]%s %.0f→%.0f(%s%.0f)[/color]" % [
			color, key, old_val, new_val, ("+" if delta >= 0 else ""), delta
		])
	return "  ".join(parts)


func _extract_json(text: String) -> String:
	var s := text.strip_edges()
	if s.begins_with("```"):
		var nl := s.find("\n")
		var fence_end := s.rfind("```")
		if nl != -1 and fence_end > nl:
			s = s.substr(nl + 1, fence_end - nl - 1).strip_edges()
	var start := s.find("{")
	var end   := s.rfind("}")
	if start != -1 and end > start:
		return s.substr(start, end - start + 1)
	return s
