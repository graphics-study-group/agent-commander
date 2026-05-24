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
var _attacker_unit: Unit
var _defender_unit: Unit
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
					"winner":    {"type": "string", "description": "获胜方单位名称，或 'draw' 表示平局"},
					"narrative": {"type": "string", "description": "战斗结束的最终叙述（60-150字），包含战果总结"}
				},
				"required": ["winner", "narrative"]
			}
		}
	}
]

# ── Setup ─────────────────────────────────────────────────────────────────────

func setup(
		attacker_unit: Unit, defender_unit: Unit,
		attacker_is_player: bool, defender_is_player: bool,
		battle_col: int, battle_row: int,
		hex_map: Node, extra_rules: String = "") -> void:
	_attacker_unit      = attacker_unit
	_defender_unit      = defender_unit
	_attacker_is_player = attacker_is_player
	_defender_is_player = defender_is_player
	_battle_col         = battle_col
	_battle_row         = battle_row
	_hex_map            = hex_map
	if _hex_map != null and _hex_map.has_method("get_tile_type_at"):
		_terrain_type = _hex_map.get_tile_type_at(battle_col, battle_row)

	_api = DeepSeekAPI.new()
	add_child(_api)
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
	var atk := _attacker_unit
	var def := _defender_unit
	var lines: Array[String] = []
	lines.append("【第%d轮战斗结算开始（约10秒）】" % _round)
	lines.append("")
	lines.append("进攻方 %s（无地形加成）：%s" % [
		atk.unit_name if atk != null else "?",
		atk.get_state_summary() if atk != null else "数据缺失"
	])
	lines.append("防御方 %s（享有地形加成）：%s" % [
		def.unit_name if def != null else "?",
		def.get_state_summary() if def != null else "数据缺失"
	])
	lines.append("")
	if not _pending_commands.is_empty():
		lines.append("【本轮战术指令】")
		for cmd: Dictionary in _pending_commands:
			lines.append("  (%s) %s 指令：%s" % [
				cmd.get("source", "?"), cmd.get("unit_name", "?"), cmd.get("message", "")
			])
		lines.append("")
	lines.append("请结算本轮约10秒的战斗，使用 modify_unit_stats 施加数值变化，然后输出40-80字战况叙述。若战斗结束，先完成战后结算的属性修改，再调用 end_battle。")
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
			if _attacker_unit != null and _attacker_unit.unit_name == unit_name:
				target = _attacker_unit
			elif _defender_unit != null and _defender_unit.unit_name == unit_name:
				target = _defender_unit
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
	var atk_name     := _attacker_unit.unit_name if _attacker_unit != null else "进攻方"
	var def_name     := _defender_unit.unit_name if _defender_unit != null else "防御方"

	var extra_section := ""
	if not extra_rules.is_empty():
		extra_section = "\n\n【裁判额外设定（最高优先级）】\n" + extra_rules

	return """你是战略沙盘的【战斗仲裁官】，负责公正地逐轮结算一场战斗。每次调用仅结算约10秒战斗过程。

【战场基本信息】
进攻方：%s（%s）——刚抵达，无地形加成
防御方：%s（%s）——原驻守，享受地形加成
战斗格地形：%s%s

【军队战斗结算规则（完整版）】
________________________________________
一、基础属性：ATK攻击力、DEF防御力、ORG组织度（生命值）、MORALE士气、PROF熟练度、RECON侦察力、STR兵力（100%%=满编）、SUPPLY补给值(0-7)、SPEED速度、STAFF参谋能力。

二、战前准备
先手值=RECON+STAFF+SPEED。先手高方获得15秒"战术压制"（攻击+10%%，敌方防御-10%%）。防守方若处于防御地形可无视先手直接获得阵地坚守。

进攻方突击强度 = ATK × ∏(Buff)
  · 侧翼加成：+20%%；统帅在场：+15%%；侦察优势：多出每10%%增加2%%攻击力
  · 补给不足：SUPPLY每-1，攻击力-15%%

防御方防御强度 = DEF × ∏(Buff) × ∏(地形乘数)
  · 山地/森林/雨天：×2.0；村镇/建筑：×2.5；防守状态：×1.25；营垒：×2.0
  · 侧翼暴露：-20%%；士气<30%%：-25%%

三、伤害计算（每10秒一轮）
DPS = 突击强度 × (STR/100) × (MORALE/100)
实际承受伤害 = DPS / 防御强度 × 随机因子(0.85~1.15)
伤害分配：80%%先打ORG；ORG归零后100%%打STR。
每损失1%%STR → MORALE-1；每损失10%%ORG → MORALE-2（从满额算起）。

四、行为逻辑
A. 坚守：ORG>0且MORALE>25时执行默认指令。死守时ORG下降-30%%，但每损失10%%STR额外MORALE-3。
B. 有序撤退（触发条件须同时满足）：ORG<40%% 且 MORALE>20%% 且 random(0,100)<STAFF+统帅影响。
   进入"且战且退"15秒（速度-50%%，防御+20%%，攻击-40%%），成功后转"败退重整"。
   失败惩罚：参谋检定失败或期间ORG归零→转崩溃。
C. 崩溃（满足其一即可）：MORALE≤20%%；ORG归零超15秒；10秒内STR损失>25%%。
   表现：防御降至0，攻击降至0，向后溃散，传染周围友军MORALE-7。

五、战后结算（调用end_battle前，先用modify_unit_stats完成以下结算）
A. 兵力损失：有序撤退方额外STR-2%%；崩溃方额外STR-(10%%+STAFF×0.1)。
B. 组织度：有序撤退→恢复 5%%+PROF×0.1 /秒；崩溃→ORG恢复变1%%/秒（持续60s）。
   （本局这两条用modify_stats设置duration的修改来体现即可，可以用大概数值）
C. 士气：胜利/坚守+15；有序撤退-10；崩溃-25（且上限限制在40%%直到安全区域）；僵持-5。
D. 熟练度：参与+1；胜利+3；歼灭战（突击强度比>5）+5；高参谋能力部队参谋能力+1。
E. 补给：崩溃/死守被全歼时，胜方获得败方当前SUPPLY的60%%。%s

【行为规则】
1. 每次调用结算约10秒；可多次调用 modify_unit_stats。
2. 严格按照公式计算，加入随机因子模拟不确定性，不可无故偏袒任何一方。
3. 战术指令须合理影响结算（如撤退指令影响撤退成功率，攻击指令影响突击强度等）。
4. 判定战斗结束后，先完成所有战后结算的属性修改，再调用 end_battle。
5. winner为获胜方名称，平局为"draw"。""" % [
		atk_name, atk_side,
		def_name, def_side,
		terrain_name, terrain_buff,
		extra_section
	]


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
