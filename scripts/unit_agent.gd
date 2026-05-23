class_name UnitAgent
extends Node

signal response_ready(narrative: String)
signal stats_changed(payload: Dictionary)
signal speed_buff_applied(kmh: float, hexes: int)
signal debug_log(msg: String)

const DeepSeekAPI = preload("res://scripts/deepseek_api.gd")
const TOKEN_WARN_CHARS := 3_000_000  # ~1M tokens at ~3 chars/token

var unit: Unit
var _api: Node
var _hex_map: Node
var _extra_rules: String = ""

var _inbox: Array = []       # {id, type, info, timestamp}
var _exec_queue: Array = []  # {id, type, params, status, retain, created_at}
var _is_processing: bool = false
var _exec_running: bool = false
var _next_event_id: int = 0
var _next_queue_id: int = 0
var debug_mode: bool = false

# ── Tool definitions ──────────────────────────────────────────────────────────

const TOOLS: Array = [
	{
		"type": "function",
		"function": {
			"name": "calculate_path",
			"description": "立即计算当前位置到目标格的最短路径（避开山/水）。在 enqueue_action(move) 前必须先调用。",
			"parameters": {
				"type": "object",
				"properties": {
					"to_col": {"type": "integer", "description": "目标列 (0-15)"},
					"to_row": {"type": "integer", "description": "目标行 (0-15)"}
				},
				"required": ["to_col", "to_row"]
			}
		}
	},
	{
		"type": "function",
		"function": {
			"name": "enqueue_action",
			"description": "将一个动作加入执行队列按序执行。\ntype 及对应 params 格式：\n· move         {path:[{col,row},...]}  路径来自 calculate_path\n· wait         {seconds:N}             等待N秒\n· modify_stats {changes:{STAT:delta,...}, reason:\"原因\"}  修改本部队属性（严禁归零）\n· speed_buff   {kmh:N, hexes:N}        临时速度加成\n· emit_event   {event_type:\"类型\", event_info:{}}  完成后向自身发送事件（可实现周期任务）\nretain=true 表示完成后保留在队列快照中（有持续影响的操作如DEF增益须设true）。",
			"parameters": {
				"type": "object",
				"properties": {
					"type":   {"type": "string"},
					"params": {"type": "object"},
					"retain": {"type": "boolean", "description": "完成后是否保留在快照。默认false。"}
				},
				"required": ["type", "params"]
			}
		}
	},
	{
		"type": "function",
		"function": {
			"name": "delete_queue_item",
			"description": "取消执行队列中指定 id 的动作（pending 或 running 均可；已完成的会被忽略）。",
			"parameters": {
				"type": "object",
				"properties": {
					"id": {"type": "integer", "description": "要取消的队列项 id"}
				},
				"required": ["id"]
			}
		}
	},
	{
		"type": "function",
		"function": {
			"name": "clear_exec_queue",
			"description": "取消执行队列中所有 pending/running 动作并立即停止移动。",
			"parameters": {"type": "object", "properties": {}}
		}
	},
	{
		"type": "function",
		"function": {
			"name": "dispatch_event",
			"description": "向另一支部队的 agent 发送事件（用于跨单位交互，如通知增援、传递补给等）。目标 agent 会被唤醒并自行决策如何响应。",
			"parameters": {
				"type": "object",
				"properties": {
					"target_unit": {"type": "string", "description": "目标部队名称"},
					"event_type":  {"type": "string", "description": "事件类型，如 stat_override / reinforce / supply"},
					"event_info":  {"type": "object", "description": "事件详情"},
					"reason":      {"type": "string", "description": "发送原因（告知目标 agent）"}
				},
				"required": ["target_unit", "event_type", "event_info", "reason"]
			}
		}
	},
	{
		"type": "function",
		"function": {
			"name": "name_point",
			"description": "为地图上某个格子设置地名（如山口、渡口、要塞等关键地点），供后续指令以地名指代方位。",
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
			"name": "rename_unit",
			"description": "修改本部队的代号/番号。仅限以下情况：统帅明确指示改名、部队拆分/合并产生新番号。严禁基于自身判断或叙事风格随意更名。",
			"parameters": {
				"type": "object",
				"properties": {
					"new_name": {"type": "string", "description": "新番号"}
				},
				"required": ["new_name"]
			}
		}
	}
]

# ── Setup ─────────────────────────────────────────────────────────────────────

func setup(p_unit: Unit, hex_map: Node, extra_rules: String = "") -> void:
	unit         = p_unit
	_hex_map     = hex_map
	_extra_rules = extra_rules

	_api = DeepSeekAPI.new()
	add_child(_api)
	_api.set_system_prompt(_build_system_prompt())
	_api.tools = TOOLS
	_api.response_received.connect(_on_final_response)
	_api.tool_calls_received.connect(_on_tool_calls)
	_api.request_failed.connect(_on_error)

	add_to_group("unit_agent")


func reload_rules(rules: String) -> void:
	_extra_rules = rules
	_api.set_system_prompt(_build_system_prompt())


# ── Public event API ──────────────────────────────────────────────────────────

func receive_event(event_type: String, event_info: Dictionary) -> void:
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


# ── API trigger ───────────────────────────────────────────────────────────────

func _trigger_api_call() -> void:
	if _inbox.is_empty() or _is_processing:
		return
	_is_processing = true

	var events := _inbox.duplicate()
	_inbox.clear()

	var ctx := _build_event_context(events)
	ctx += "\n" + _build_queue_context()
	if _hex_map != null and _hex_map.has_method("get_position_info") and unit != null:
		ctx += "\n" + _hex_map.get_position_info(unit.unit_name)
	if unit != null:
		ctx += "\n当前部队状态：" + unit.get_state_summary()

	var approx_chars: int = ctx.length() + _api.get_approx_chars()
	if approx_chars > TOKEN_WARN_CHARS:
		push_warning("UnitAgent[%s]: input ~%dK chars, may exceed 1M tokens" % [
			unit.unit_name if unit else "?", approx_chars / 1000])
		response_ready.emit("[警告] 上下文过长（约%d万字），建议重置对话" % (approx_chars / 10000))

	_api.send_message(ctx)


func _build_event_context(events: Array) -> String:
	if events.is_empty():
		return ""
	var now := Time.get_unix_time_from_system()
	var lines: Array[String] = ["【收件箱 (%d条新事件)】" % events.size()]
	for ev: Dictionary in events:
		var age := "%.0fs前" % (now - float(ev.get("timestamp", now)))
		var info_str := JSON.stringify(ev.get("info", {}))
		lines.append("  [#%d %s %s] %s" % [ev.get("id", 0), age, ev.get("type", ""), info_str])
	return "\n".join(lines)


func _build_queue_context() -> String:
	var visible: Array = []
	for item: Dictionary in _exec_queue:
		var st: String = item.get("status", "pending")
		if st in ["pending", "running"] or (st == "completed" and item.get("retain", false)):
			visible.append(item)
	if visible.is_empty():
		return "【执行队列：空】"
	var lines: Array[String] = ["【执行队列 (%d项)】" % visible.size()]
	for item: Dictionary in visible:
		var st: String = item.get("status", "")
		var p_str := JSON.stringify(item.get("params", {}))
		lines.append("  #%d [%s] %s %s" % [item.get("id", 0), st, item.get("type", ""), p_str])
	return "\n".join(lines)


# ── Tool call loop ────────────────────────────────────────────────────────────

func _on_tool_calls(calls: Array) -> void:
	var results: Array = []
	for tool_call: Dictionary in calls:
		var fn:      Dictionary = tool_call.get("function", {})
		var name:    String     = fn.get("name", "")
		var args_str: String    = fn.get("arguments", "{}")
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
			if _hex_map == null:
				return {"error": "地图不可用"}
			var pos := _get_unit_pos()
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
			var item := {
				"id":         _next_queue_id,
				"type":       args.get("type", ""),
				"params":     args.get("params", {}),
				"status":     "pending",
				"retain":     bool(args.get("retain", false)),
				"created_at": Time.get_unix_time_from_system()
			}
			_next_queue_id += 1
			_exec_queue.append(item)
			if debug_mode:
				debug_log.emit("[DEBUG] [%s] 入队 #%d  type=%s  params=%s  retain=%s" % [
					unit.unit_name if unit != null else "?",
					item["id"], item["type"],
					JSON.stringify(item["params"]), item["retain"]
				])
			_maybe_start_exec()
			return {"queued_id": item["id"], "queue_size": _exec_queue.size()}

		"delete_queue_item":
			var target_id := int(args.get("id", -1))
			for item: Dictionary in _exec_queue:
				if int(item.get("id", -1)) == target_id:
					if item.get("status") == "completed":
						return {"skipped": true, "reason": "已完成，无需取消"}
					item["status"] = "cancelled"
					if item.get("type") == "move" and _hex_map != null and unit != null:
						_hex_map.clear_move_queue(unit.unit_name)
					return {"cancelled_id": target_id}
			return {"error": "id %d 未找到" % target_id}

		"clear_exec_queue":
			for item: Dictionary in _exec_queue:
				if item.get("status") in ["pending", "running"]:
					item["status"] = "cancelled"
			if _hex_map != null and _hex_map.has_method("clear_move_queue") and unit != null:
				_hex_map.clear_move_queue(unit.unit_name)
			return {"cleared": true}

		"dispatch_event":
			var target_name: String = args.get("target_unit", "")
			var reason: String      = args.get("reason", "")
			var raw_info = args.get("event_info", {})
			var info: Dictionary = {}
			if raw_info is Dictionary:
				info = raw_info
			elif raw_info is String and not (raw_info as String).is_empty():
				var j2 := JSON.new()
				if j2.parse(raw_info) == OK and j2.get_data() is Dictionary:
					info = j2.get_data()
			info["from_unit"] = unit.unit_name if unit != null else "unknown"
			info["reason"]    = reason
			var event_type: String  = args.get("event_type", "generic")
			var found := false
			for node in get_tree().get_nodes_in_group("unit_agent"):
				var other := node as UnitAgent
				if other != null and other != self and other.unit != null \
						and other.unit.unit_name == target_name:
					other.receive_event(event_type, info)
					found = true
					break
			if not found:
				return {"error": "未找到部队: " + target_name}
			return {"dispatched": true, "target": target_name, "type": event_type}

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

		"rename_unit":
			var new_name: String = args.get("new_name", "")
			if new_name.is_empty():
				return {"error": "名称不能为空"}
			var old_name := unit.unit_name if unit != null else ""
			if _hex_map != null and _hex_map.has_method("rename_unit"):
				_hex_map.rename_unit(old_name, new_name)
			if unit != null:
				unit.unit_name = new_name
			var ui := get_tree().get_first_node_in_group("commander_ui")
			if ui != null and ui.has_method("on_unit_renamed"):
				ui.on_unit_renamed(old_name, new_name)
			return {"ok": true, "old_name": old_name, "new_name": new_name}

	return {"error": "未知工具: " + fn_name}


# ── Exec queue runner ─────────────────────────────────────────────────────────

func _maybe_start_exec() -> void:
	if not _exec_running:
		_run_exec_queue()


func _run_exec_queue() -> void:
	_exec_running = true
	while true:
		var item := _find_next_pending()
		if item.is_empty():
			break
		item["status"] = "running"
		await _execute_item(item)
		if item.get("status") == "cancelled":
			_exec_queue.erase(item)
		elif item.get("retain", false):
			item["status"] = "completed"
		else:
			_exec_queue.erase(item)
	_exec_running = false


func _find_next_pending() -> Dictionary:
	for item: Dictionary in _exec_queue:
		if item.get("status") == "pending":
			return item
	return {}


func _execute_item(item: Dictionary) -> void:
	var tp: String    = item.get("type", "")
	var p: Dictionary = item.get("params", {})

	match tp:
		"move":
			if _hex_map == null or not _hex_map.has_method("set_move_path") or unit == null:
				return
			var raw: Array = p.get("path", [])
			var steps: Array = []
			for step in raw:
				if step is Dictionary:
					steps.append([int(step.get("col", 0)), int(step.get("row", 0))])
			if steps.is_empty():
				return
			_hex_map.set_move_path(unit.unit_name, steps)
			# Wait specifically for this unit's movement to finish
			while true:
				var emitted_name: String = await _hex_map.movement_finished
				if emitted_name == unit.unit_name:
					break

		"wait":
			var total := float(p.get("seconds", 1.0))
			var elapsed := 0.0
			while elapsed < total:
				if item.get("status") == "cancelled":
					return
				var step := minf(total - elapsed, 1.0)
				await get_tree().create_timer(step).timeout
				elapsed += step

		"modify_stats":
			if unit == null:
				return
			var changes: Dictionary = p.get("changes", {})
			var reason: String      = p.get("reason", "")
			unit.apply_changes(changes)
			stats_changed.emit({"changes": changes, "reason": reason})

		"speed_buff":
			var kmh   := float(p.get("kmh", 0.0))
			var hexes := int(p.get("hexes", 0))
			if kmh > 0 and hexes > 0 and _hex_map != null and unit != null:
				_hex_map.apply_speed_buff(unit.unit_name, kmh, hexes)
				speed_buff_applied.emit(kmh, hexes)

		"emit_event":
			var event_type: String     = p.get("event_type", "timer")
			var event_info: Dictionary = p.get("event_info", {})
			receive_event(event_type, event_info)


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
		map_str = _hex_map.get_map_string()
	var unit_name := unit.unit_name if unit != null else "部队"
	var rules_section := ""
	if not _extra_rules.is_empty():
		rules_section = "\n\n【裁判额外设定（最高优先级）】\n" + _extra_rules

	return """你是战略沙盘中「%s」的AI指挥官。你是事件驱动型agent：平时待机，有事件到来时被唤醒，思考后将行动加入执行队列，最后输出战场叙述。

%s

【坐标系】偶数行不偏移；奇数行右偏半格。方向0=东北 1=东 2=东南 3=西南 4=西 5=西北。格间40km，路上×2，M/W不可通行。

【属性范围】ATK/DEF(0-200) ORG/MORALE/PROF/RECON/STR/STAFF(0-100) SUPPLY(0-7) SPEED(0-20km/h)

【执行队列设计原则】
- 复杂指令拆分为多个 enqueue_action 按序执行
- 建设型操作（防御工事等）：enqueue_action(wait, seconds) + enqueue_action(modify_stats, DEF+N, retain=true)
- retain=true：有持续影响的操作（如DEF增益、SUPPLY变化），完成后留在快照供下次参考
- 发现快照中有 retain=true 的增益且需要取消时（如移动撤离工事），enqueue_action(modify_stats, 扣回对应值)
- 周期任务：enqueue_action(wait) + enqueue_action(emit_event) 实现自循环
- 移动前须 calculate_path；普通移动不修改属性（除非快照中有待撤销的增益）
- 急行军/强攻/夜袭才立即扣耗：ORG -5~-20 MORALE -3~-15 STR -2~-5 SUPPLY -0.3~-1
- 与其他部队交互：dispatch_event（目标agent自行决策响应）
- rename_unit：严禁随意调用；仅当统帅明确下令改名，或部队拆分/合并需要新番号时方可使用
- 严禁捏造地形，严禁将任何属性归零%s

每次响应最后输出40-100字传令兵叙述，说明本次行动及所有数值变化原因。""" % [unit_name, map_str, rules_section]


# ── Helpers ───────────────────────────────────────────────────────────────────

func _get_unit_pos() -> Vector2i:
	if _hex_map == null or unit == null:
		return Vector2i.ZERO
	return _hex_map.get_unit_pos(unit.unit_name)
