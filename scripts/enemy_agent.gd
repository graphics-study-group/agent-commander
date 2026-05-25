class_name EnemyAgent
extends Node

signal response_ready(narrative: String)
signal debug_log(msg: String)

const DeepSeekAPI = preload("res://scripts/deepseek_api.gd")
const TOKEN_WARN_CHARS := 3_000_000
const IDLE_REASSESS_INTERVAL := 30.0  # real wall-clock seconds

var _api: Node
var _hex_map: Node
var _extra_rules: String = ""
var _player_entries: Array = []  # [{unit, agent, ...}] read-only context
var _enemy_entries: Array = []   # [{unit, agent}] we command these

var _is_processing: bool = false
var _last_reassess_time: float = 0.0
var _inbox: Array = []
var _next_event_id: int = 0
var debug_mode: bool = false: set = _set_debug_mode

# ── Tool definitions ──────────────────────────────────────────────────────────

const TOOLS: Array = [
	{
		"type": "function",
		"function": {
			"name": "calculate_path",
			"description": "计算指定我方部队从当前位置到目标格的最短路径（避开山/水）。在 enqueue_action(move) 前必须先调用。",
			"parameters": {
				"type": "object",
				"properties": {
					"unit_name": {"type": "string", "description": "我方部队名称"},
					"to_col":    {"type": "integer", "description": "目标列 (0-15)"},
					"to_row":    {"type": "integer", "description": "目标行 (0-15)"}
				},
				"required": ["unit_name", "to_col", "to_row"]
			}
		}
	},
	{
		"type": "function",
		"function": {
			"name": "enqueue_action",
			"description": "将动作加入指定我方部队的执行队列，或对 modify_stats 立即执行（immediate=true）。\ntype 格式：\n· move         {col:X, row:Y}          移动一格（原子操作）；先 calculate_path 得到路径，再对每一步分别调用一次本工具入队\n· wait         {seconds:N}\n· modify_stats {changes:{STAT:delta,...}, reason:\"原因\", delay_seconds:N, duration:N}  delay_seconds=延迟N秒生效；duration=-1永久，duration>0自动还原（严禁归零）\n· emit_event   {event_type:\"类型\", event_info:{}}\nimmediate 仅对 modify_stats 有效：true=绕过队列立即生效（适用于急行军等即时效果）。\nretain 对 move/wait/emit_event 有效；modify_stats 由 duration 自动决定。",
			"parameters": {
				"type": "object",
				"properties": {
					"unit_name": {"type": "string", "description": "目标我方部队名称"},
					"type":      {"type": "string"},
					"params":    {"type": "object"},
					"retain":    {"type": "boolean", "description": "完成后是否保留。默认false。"},
					"immediate": {"type": "boolean", "description": "仅 modify_stats 可用。true=绕过队列立即生效。默认false。"}
				},
				"required": ["unit_name", "type", "params"]
			}
		}
	},
	{
		"type": "function",
		"function": {
			"name": "delete_queue_item",
			"description": "取消指定我方部队执行队列中的某个 pending 动作。running 动作（原子执行中）无法取消。",
			"parameters": {
				"type": "object",
				"properties": {
					"unit_name": {"type": "string", "description": "目标部队名称"},
					"id":        {"type": "integer", "description": "要取消的队列项 id"}
				},
				"required": ["unit_name", "id"]
			}
		}
	},
	{
		"type": "function",
		"function": {
			"name": "clear_exec_queue",
			"description": "取消指定我方部队队列中所有 pending 动作。running 动作（原子执行中）不受影响，自然完成。",
			"parameters": {
				"type": "object",
				"properties": {
					"unit_name": {"type": "string", "description": "目标部队名称"}
				},
				"required": ["unit_name"]
			}
		}
	},
	{
		"type": "function",
		"function": {
			"name": "name_point",
			"description": "为地图上某个格子设置地名，供后续指令以地名指代方位。",
			"parameters": {
				"type": "object",
				"properties": {
					"col":  {"type": "integer", "description": "目标列"},
					"row":  {"type": "integer", "description": "目标行"},
					"name": {"type": "string",  "description": "地名（2-6字）"}
				},
				"required": ["col", "row", "name"]
			}
		}
	},
	{
		"type": "function",
		"function": {
			"name": "send_combat_order",
			"description": "向正在进行的战斗发送战术命令（仅当己方部队正在交战时可用）。可指挥部队撤退、坚守、调整战术等。",
			"parameters": {
				"type": "object",
				"properties": {
					"battle_id": {"type": "string", "description": "战斗ID（来自 combat_start 事件）"},
					"unit_name": {"type": "string", "description": "己方交战部队名称"},
					"order":     {"type": "string", "description": "战术命令内容，如：立即撤退、坚守阵地、集中火力攻击ORG等"}
				},
				"required": ["battle_id", "unit_name", "order"]
			}
		}
	}
]

# ── Setup ─────────────────────────────────────────────────────────────────────

func _set_debug_mode(value: bool) -> void:
	debug_mode = value
	if _api != null:
		_api.set_system_prompt(_build_system_prompt())


func setup(player_entries: Array, enemy_entries: Array,
		hex_map: Node, extra_rules: String = "") -> void:
	_player_entries = player_entries
	_enemy_entries  = enemy_entries
	_hex_map        = hex_map
	_extra_rules    = extra_rules

	_api = DeepSeekAPI.new()
	add_child(_api)
	_api.agent_type = "enemy_agent"
	_api.set_system_prompt(_build_system_prompt())
	_api.tools = TOOLS
	_api.response_received.connect(_on_final_response)
	_api.tool_calls_received.connect(_on_tool_calls)
	_api.request_failed.connect(_on_error)

	set_process(true)
	_last_reassess_time = Time.get_unix_time_from_system()


func reload_rules(rules: String) -> void:
	_extra_rules = rules
	_api.set_system_prompt(_build_system_prompt())


# ── Public event API ──────────────────────────────────────────────────────────

func receive_event(event_type: String, event_info: Dictionary) -> void:
	_last_reassess_time = Time.get_unix_time_from_system()
	var event := {
		"id":        _next_event_id,
		"type":      event_type,
		"info":      event_info,
		"timestamp": Time.get_unix_time_from_system()
	}
	_next_event_id += 1
	_inbox.append(event)
	if not _is_processing:
		_trigger_api_call()


# ── Idle reassess timer ───────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if _is_processing or _api == null:
		return
	var now := Time.get_unix_time_from_system()
	if now - _last_reassess_time >= IDLE_REASSESS_INTERVAL:
		_last_reassess_time = now
		receive_event("idle_reassess", {"trigger": "30秒无新事件，自动重新评估战场态势"})


# ── API trigger ───────────────────────────────────────────────────────────────

func _trigger_api_call() -> void:
	if _inbox.is_empty() or _is_processing:
		return
	_is_processing = true

	var events := _inbox.duplicate()
	_inbox.clear()

	var ctx := _build_event_context(events)
	ctx += "\n\n" + _build_all_units_context()

	var approx_chars: int = ctx.length() + _api.get_approx_chars()
	if approx_chars > TOKEN_WARN_CHARS:
		push_warning("EnemyAgent: input ~%dK chars, may exceed 1M tokens" % (approx_chars / 1000))

	_api.send_message(ctx)


func _build_event_context(events: Array) -> String:
	if events.is_empty():
		return ""
	var now := Time.get_unix_time_from_system()
	var lines: Array[String] = ["【事件 (%d条)】" % events.size()]
	for ev: Dictionary in events:
		var age := "%.0fs前" % (now - float(ev.get("timestamp", now)))
		var info_str := JSON.stringify(ev.get("info", {}))
		lines.append("  [#%d %s %s] %s" % [ev.get("id", 0), age, ev.get("type", ""), info_str])
	return "\n".join(lines)


func _build_all_units_context() -> String:
	var lines: Array[String] = ["【战场态势】"]

	lines.append("蓝方（玩家方）：")
	for e in _player_entries:
		var u: Unit = e.get("unit") as Unit
		if u == null:
			continue
		var pos := Vector2i.ZERO
		if _hex_map != null and _hex_map.has_method("get_unit_pos"):
			pos = _hex_map.get_unit_pos(u.unit_name)
		lines.append("  %s 位置(%d,%d) %s" % [u.unit_name, pos.x, pos.y, u.get_state_summary()])

	lines.append("红方（我方）：")
	for e in _enemy_entries:
		var u: Unit = e.get("unit") as Unit
		var agent: Node = e.get("agent") as Node
		if u == null:
			continue
		var pos := Vector2i.ZERO
		if _hex_map != null and _hex_map.has_method("get_unit_pos"):
			pos = _hex_map.get_unit_pos(u.unit_name)
		lines.append("  %s 位置(%d,%d) %s" % [u.unit_name, pos.x, pos.y, u.get_state_summary()])
		if agent != null and agent.has_method("get_queue_snapshot"):
			var queue: Array = agent.get_queue_snapshot()
			if not queue.is_empty():
				var q_strs: Array[String] = []
				for item: Dictionary in queue:
					q_strs.append("#%d[%s]%s" % [
						item.get("id", 0), item.get("status", ""), item.get("type", "")])
				lines.append("    队列: " + ", ".join(q_strs))

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
		"calculate_path":
			var unit_name: String = args.get("unit_name", "")
			var agent := _find_enemy_agent(unit_name)
			if agent == null:
				return {"error": "未找到我方部队: " + unit_name}
			if _hex_map == null:
				return {"error": "地图不可用"}
			var pos: Vector2i = _hex_map.get_unit_pos(unit_name)
			var tc := int(args.get("to_col", 0))
			var tr := int(args.get("to_row", 0))
			var path: Array = _hex_map.calc_path(pos.x, pos.y, tc, tr)
			if path.is_empty():
				return {"reachable": false, "message": "目标不可达或已在当前位置"}
			var out: Array = []
			for step in path:
				out.append({"col": step[0], "row": step[1]})
			return {"reachable": true, "path": out, "steps": out.size()}

		"enqueue_action":
			var unit_name: String = args.get("unit_name", "")
			var agent := _find_enemy_agent(unit_name)
			if agent == null:
				return {"error": "未找到我方部队: " + unit_name}
			var type: String       = args.get("type", "")
			var params: Dictionary = {}
			var raw_params         = args.get("params", {})
			if raw_params is Dictionary:
				params = raw_params
			elif raw_params is String and not (raw_params as String).is_empty():
				var j2 := JSON.new()
				if j2.parse(raw_params) == OK and j2.get_data() is Dictionary:
					params = j2.get_data()
			var retain: bool    = bool(args.get("retain", false))
			var immediate: bool = bool(args.get("immediate", false))
			if debug_mode:
				debug_log.emit("[DEBUG] [Enemy→%s] enqueue %s params=%s immediate=%s" % [
					unit_name, type, JSON.stringify(params), immediate])
			if immediate and type == "modify_stats":
				return agent.apply_stats_immediate(params)
			return agent.enqueue_external(type, params, retain)

		"delete_queue_item":
			var unit_name: String = args.get("unit_name", "")
			var agent := _find_enemy_agent(unit_name)
			if agent == null:
				return {"error": "未找到我方部队: " + unit_name}
			return agent.delete_queue_external(int(args.get("id", -1)))

		"clear_exec_queue":
			var unit_name: String = args.get("unit_name", "")
			var agent := _find_enemy_agent(unit_name)
			if agent == null:
				return {"error": "未找到我方部队: " + unit_name}
			return agent.clear_queue_external()

		"name_point":
			var col := int(args.get("col", 0))
			var row := int(args.get("row", 0))
			var pname: String = args.get("name", "")
			if pname.is_empty():
				return {"error": "名称不能为空"}
			if _hex_map != null and _hex_map.has_method("name_point"):
				_hex_map.name_point(col, row, pname)
				return {"ok": true, "name": pname}
			return {"error": "地图不可用"}

		"send_combat_order":
			var bid: String       = args.get("battle_id", "")
			var unit_name: String = args.get("unit_name", "")
			var order: String     = args.get("order", "")
			var ui := get_tree().get_first_node_in_group("commander_ui")
			if ui == null:
				return {"error": "UI不可用"}
			if ui.has_method("forward_enemy_combat_order"):
				return ui.forward_enemy_combat_order(bid, unit_name, order)
			return {"error": "战斗系统不可用"}

	return {"error": "未知工具: " + fn_name}


func _find_enemy_agent(unit_name: String) -> Node:
	for e in _enemy_entries:
		var u: Unit = e.get("unit") as Unit
		if u != null and u.unit_name == unit_name:
			return e.get("agent") as Node
	return null


# ── Response handlers ─────────────────────────────────────────────────────────

func _on_final_response(content: String) -> void:
	response_ready.emit(content)
	_is_processing = false
	if not _inbox.is_empty():
		_trigger_api_call()


func _on_error(error: String) -> void:
	response_ready.emit("[通讯故障] " + error)
	_is_processing = false
	if not _inbox.is_empty():
		_trigger_api_call()


# ── System prompt ─────────────────────────────────────────────────────────────

func _build_system_prompt() -> String:
	var map_str := ""
	if _hex_map != null and _hex_map.has_method("get_map_string"):
		map_str = _hex_map.get_map_string() + "\n\n"

	var enemy_names: Array[String] = []
	for e in _enemy_entries:
		var u: Unit = e.get("unit") as Unit
		if u != null:
			enemy_names.append("· " + u.unit_name)

	var rules_section := ""
	if not _extra_rules.is_empty():
		rules_section = "\n\n【裁判额外设定（最高优先级）】\n" + _extra_rules

	var debug_key := "debug_on" if debug_mode else "debug_off"
	var debug_section := "\n\n" + PromptLoader.get_template("enemy_agent", debug_key)

	return PromptLoader.get_template("enemy_agent", "system") \
		.replace("{enemy_names}", "\n".join(enemy_names)) \
		.replace("{map_str}", map_str) \
		.replace("{rules_section}", rules_section) \
		.replace("{debug_section}", debug_section)
