class_name BattleAgent
extends Node

signal combat_report(battle_id: String, narrative: String)
signal combat_ended(battle_id: String, winner_name: String)
signal stats_updated(unit_name: String)
signal debug_log(msg: String)

const DeepSeekAPI = preload("res://scripts/deepseek_api.gd")

# Adjust this constant to change round duration (real-wall-clock seconds)
const ROUND_INTERVAL := 10.0

var battle_id: String = ""
var _attacker_units: Array = []   # Array[Unit]
var _defender_units: Array = []   # Array[Unit]
var _attacker_is_player: bool
var _defender_is_player: bool
var _battle_col: int
var _battle_row: int
var _hex_map: Node
var _terrain_type: int = 0

var _api: Node
var _round: int = 0
var _is_active: bool = false
var _is_processing: bool = false
var _round_elapsed: float = 0.0  # game-time seconds elapsed since round start
var _winner_name: String = ""
var _end_narrative: String = ""
var _pending_commands: Array = []  # [{unit_name, source, message}]
var _reinforcement_log: Array = []  # strings injected into next round context

# ── Tool definitions ──────────────────────────────────────────────────────────

const TOOLS: Array = [
	{
		"type": "function",
		"function": {
			"name": "modify_unit_stats",
			"description": "修改参战双方之一的属性值（增量，非绝对值）。可在同一轮内多次调用以模拟不同伤害类型。",
			"parameters": {
				"type": "object",
				"properties": {
					"unit_name": {"type": "string", "description": "要修改的单位名称"},
					"changes":   {"type": "object", "description": "属性增量字典，如 {\"ORG\": -8, \"MORALE\": -3}"},
					"reason":    {"type": "string", "description": "修改原因（用于战斗记录）"}
				},
				"required": ["unit_name", "changes", "reason"]
			}
		}
	},
	{
		"type": "function",
		"function": {
			"name": "end_battle",
			"description": "宣布战斗结束并进行最终结算。必须先调用 modify_unit_stats 完成所有战后属性结算（逃兵、士气恢复上限、熟练度等），再调用此工具。",
			"parameters": {
				"type": "object",
				"properties": {
					"winner":    {"type": "string", "description": "获胜方阵营：'attacker'=进攻方获胜，'defender'=防御方获胜，'draw'=平局"},
					"narrative": {"type": "string", "description": "战斗结束的最终叙述（60-150字），包含战果总结"}
				},
				"required": ["winner", "narrative"]
			}
		}
	}
]

# ── Setup ─────────────────────────────────────────────────────────────────────

func setup(
		attacker_units: Array, defender_units: Array,
		attacker_is_player: bool, defender_is_player: bool,
		battle_col: int, battle_row: int,
		hex_map: Node, extra_rules: String = "") -> void:
	_attacker_units     = attacker_units
	_defender_units     = defender_units
	_attacker_is_player = attacker_is_player
	_defender_is_player = defender_is_player
	_battle_col         = battle_col
	_battle_row         = battle_row
	_hex_map            = hex_map
	if _hex_map != null and _hex_map.has_method("get_tile_type_at"):
		_terrain_type = _hex_map.get_tile_type_at(battle_col, battle_row)

	_api = DeepSeekAPI.new()
	add_child(_api)
	_api.agent_type = "battle_agent"
	_api.model = "deepseek-v4-pro"
	_api.set_system_prompt(_build_system_prompt(extra_rules))
	_api.tools = TOOLS
	_api.response_received.connect(_on_final_response)
	_api.tool_calls_received.connect(_on_tool_calls)
	_api.request_failed.connect(_on_error)


func _ready() -> void:
	set_process(false)


func start() -> void:
	_is_active = true
	_round_elapsed = ROUND_INTERVAL  # trigger immediately on first frame
	set_process(true)


# ── Public command ingestion ──────────────────────────────────────────────────

func reinforce(unit: Unit, is_attacker_side: bool) -> void:
	if is_attacker_side:
		_attacker_units.append(unit)
	else:
		_defender_units.append(unit)
	var side_str := "进攻方（无地形加成）" if is_attacker_side else "防御方（增援，无地形加成）"
	_reinforcement_log.append("【增援到达】%s 已加入 %s。" % [unit.unit_name, side_str])


func receive_player_command(unit_name: String, message: String) -> void:
	_pending_commands.append({"unit_name": unit_name, "source": "玩家", "message": message})


func receive_enemy_command(unit_name: String, message: String) -> void:
	_pending_commands.append({"unit_name": unit_name, "source": "敌方AI", "message": message})


# ── Round loop ────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _is_active:
		return
	_round_elapsed += delta  # accumulates game time (affected by Engine.time_scale)
	if not _is_processing and _round_elapsed >= ROUND_INTERVAL:
		_start_next_round()


func _start_next_round() -> void:
	if not _is_active or _is_processing:
		return
	_is_processing = true
	_round_elapsed = 0.0
	_round += 1
	var ctx := _build_round_context()
	_pending_commands.clear()
	_api.send_message(ctx)


func _build_round_context() -> String:
	var lines: Array[String] = []
	lines.append("【第%d轮战斗结算开始（约10秒）】" % _round)
	lines.append("")

	var atk_side := "玩家方（蓝方）" if _attacker_is_player else "敌方（红方）"
	lines.append("进攻方（%s，无地形加成）：" % atk_side)
	for u: Unit in _attacker_units:
		if u != null:
			lines.append("  %s：%s" % [u.unit_name, u.get_state_summary()])

	lines.append("")
	var def_side := "玩家方（蓝方）" if _defender_is_player else "敌方（红方）"
	lines.append("防御方（%s）：" % def_side)
	for i in range(_defender_units.size()):
		var u: Unit = _defender_units[i]
		if u != null:
			var terrain_note := "（原驻守，享地形加成）" if i == 0 else "（增援，无地形加成）"
			lines.append("  %s%s：%s" % [u.unit_name, terrain_note, u.get_state_summary()])

	lines.append("")

	if not _reinforcement_log.is_empty():
		for note: String in _reinforcement_log:
			lines.append(note)
		_reinforcement_log.clear()
		lines.append("")

	if not _pending_commands.is_empty():
		lines.append("【本轮战术指令】")
		for cmd: Dictionary in _pending_commands:
			lines.append("  (%s) %s 指令：%s" % [
				cmd.get("source", "?"), cmd.get("unit_name", "?"), cmd.get("message", "")
			])
		lines.append("")

	lines.append("请结算本轮约10秒的战斗，使用 modify_unit_stats 施加数值变化（每轮伤害乘以×10倍率），然后输出40-80字战况叙述。若战斗结束，先完成战后结算的属性修改，再调用 end_battle（winner 填 'attacker'/'defender'/'draw'）。")
	return "\n".join(lines)


# ── Tool call loop ────────────────────────────────────────────────────────────

func _on_tool_calls(calls: Array) -> void:
	var results: Array = []
	for tool_call: Dictionary in calls:
		var fn: Dictionary   = tool_call.get("function", {})
		var name: String     = fn.get("name", "")
		var args_str: String = fn.get("arguments", "{}")
		var j := JSON.new()
		var args: Dictionary = {}
		if j.parse(args_str) == OK and j.get_data() is Dictionary:
			args = j.get_data()
		var result := _execute_tool(name, args)
		results.append({
			"role":         "tool",
			"tool_call_id": tool_call.get("id", ""),
			"name":         name,
			"content":      JSON.stringify(result)
		})
	_api.send_tool_results(results)


func _execute_tool(fn_name: String, args: Dictionary) -> Dictionary:
	match fn_name:
		"modify_unit_stats":
			var unit_name: String = args.get("unit_name", "")
			var raw_changes       = args.get("changes", {})
			var changes: Dictionary = {}
			if raw_changes is Dictionary:
				changes = raw_changes
			elif raw_changes is String:
				var j2 := JSON.new()
				if j2.parse(raw_changes as String) == OK and j2.get_data() is Dictionary:
					changes = j2.get_data()
			var reason: String = args.get("reason", "")

			var target: Unit = null
			for u: Unit in _attacker_units:
				if u != null and u.unit_name == unit_name:
					target = u
					break
			if target == null:
				for u: Unit in _defender_units:
					if u != null and u.unit_name == unit_name:
						target = u
						break
			if target == null:
				return {"error": "未找到单位: " + unit_name}

			target.apply_changes(changes)
			stats_updated.emit(unit_name)
			return {"ok": true, "unit": unit_name, "applied": changes, "reason": reason}

		"end_battle":
			var winner: String    = args.get("winner", "draw")
			var narrative: String = args.get("narrative", "战斗结束。")
			_winner_name   = winner
			_end_narrative = narrative
			_is_active     = false
			return {"ok": true, "winner": winner}

	return {"error": "未知工具: " + fn_name}


# ── Response handlers ─────────────────────────────────────────────────────────

func _on_final_response(narrative: String) -> void:
	_is_processing = false
	if not _is_active:
		var final_text := "【战斗结束】%s" % _end_narrative
		combat_report.emit(battle_id, final_text)
		combat_ended.emit(battle_id, _winner_name)
		return

	combat_report.emit(battle_id, "【第%d轮战报】%s" % [_round, narrative])


func _on_error(error: String) -> void:
	_is_processing = false
	combat_report.emit(battle_id, "[战场通讯故障] " + error)


# ── System prompt ─────────────────────────────────────────────────────────────

func _build_system_prompt(extra_rules: String = "") -> String:
	var terrain_name := _get_terrain_name(_terrain_type)
	var terrain_buff := _get_terrain_buff_note(_terrain_type)
	var atk_side     := "玩家方（蓝方）" if _attacker_is_player else "敌方（红方）"
	var def_side     := "玩家方（蓝方）" if _defender_is_player else "敌方（红方）"

	var extra_section := ""
	if not extra_rules.is_empty():
		extra_section = "\n\n【裁判额外设定（最高优先级）】\n" + extra_rules

	return PromptLoader.get_template("battle_agent", "system") \
		.replace("{atk_side}", atk_side) \
		.replace("{def_side}", def_side) \
		.replace("{terrain_name}", terrain_name) \
		.replace("{terrain_buff}", terrain_buff) \
		.replace("{extra_section}", extra_section)


func _get_terrain_name(terrain_type: int) -> String:
	match terrain_type:
		0: return "平原"
		1: return "森林"
		2: return "山地"
		3: return "水域"
		4: return "城市"
	return "平原"


func _get_terrain_buff_note(terrain_type: int) -> String:
	match terrain_type:
		1: return "（防御方防御力×2.0）"
		2: return "（防御方防御力×2.0）"
		4: return "（防御方防御力×2.5）"
	return "（无地形加成）"
