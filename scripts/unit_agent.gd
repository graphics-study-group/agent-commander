class_name UnitAgent
extends Node

signal response_ready(narrative: String)
signal stats_changed(payload: Dictionary)
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
var _has_split: bool = false
var debug_mode: bool = false: set = _set_debug_mode
var _in_battle: bool = false

var _is_collapsed: bool = false
var _collapse_elapsed: float = 0.0
var _recover_timer: float = 0.0
var _debug_update_elapsed: float = 0.0

# ── Tool definitions ──────────────────────────────────────────────────────────

const TOOLS: Array = [
	{
		"type": "function",
		"function": {
			"name": "enqueue_action",
			"description": "将动作加入执行队列按序执行，或对 modify_stats 立即执行（immediate=true）。\ntype 及对应 params 格式：\n· move_to      {col:X, row:Y}          移动到目标格（游戏自动寻路，逐格执行，可在步间被取消或战斗打断）\n· wait         {seconds:N}             等待N秒\n· modify_stats {changes:{STAT:delta,...}, reason:\"原因\", delay_seconds:N, duration:N}  修改属性；delay_seconds=延迟N秒生效（默认0）；duration=-1永久，duration>0则N秒后自动还原（严禁归零）\n· emit_event   {event_type:\"类型\", event_info:{}}  完成后向自身发送事件（可实现周期任务）\nimmediate 仅对 modify_stats 有效：true=绕过队列立即生效（适用于急行军、临阵强化等即时效果）。\nretain 对 move_to/wait/emit_event 有效；modify_stats 的保留状态由 duration 自动决定。",
			"parameters": {
				"type": "object",
				"properties": {
					"type":      {"type": "string"},
					"params":    {"type": "object"},
					"retain":    {"type": "boolean", "description": "完成后是否保留在快照。默认false。"},
					"immediate": {"type": "boolean", "description": "仅 modify_stats 可用。true=绕过队列立即生效。默认false。"}
				},
				"required": ["type", "params"]
			}
		}
	},
	{
		"type": "function",
		"function": {
			"name": "delete_queue_item",
			"description": "取消执行队列中指定 id 的 pending 动作。running 动作（原子执行中）无法取消——请查看队列快照确认 pending 状态再调用。",
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
			"description": "取消执行队列中所有 pending 动作。running 动作（原子执行中）不受影响，会自然完成。",
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
	},
	{
		"type": "function",
		"function": {
			"name": "split_unit",
			"description": "将本部队拆分为2-4个子部队，每个子部队继承当前部队作战记忆并可独立指挥。STR/SUPPLY按比例分配，其余属性继承不变。仅当统帅明确下令拆分时才可调用。",
			"parameters": {
				"type": "object",
				"properties": {
					"fragments": {
						"type": "array",
						"description": "子部队列表，str_fraction之和须≈1.0",
						"items": {
							"type": "object",
							"properties": {
								"name":         {"type": "string", "description": "新番号"},
								"str_fraction": {"type": "number", "description": "分配的STR/SUPPLY比例（0-1）"}
							},
							"required": ["name", "str_fraction"]
						}
					},
					"reason": {"type": "string", "description": "拆分原因"}
				},
				"required": ["fragments", "reason"]
			}
		}
	}
]

# ── Setup ─────────────────────────────────────────────────────────────────────


func _set_debug_mode(value: bool) -> void:
	debug_mode = value
	if _api != null:
		_api.set_system_prompt(_build_system_prompt())

func setup(p_unit: Unit, hex_map: Node, extra_rules: String = "") -> void:
	unit         = p_unit
	_hex_map     = hex_map
	_extra_rules = extra_rules

	_api = DeepSeekAPI.new()
	add_child(_api)
	_api.agent_type = "sub_agent"
	_api.set_system_prompt(_build_system_prompt())
	_api.tools = TOOLS
	_api.response_received.connect(_on_final_response)
	_api.tool_calls_received.connect(_on_tool_calls)
	_api.request_failed.connect(_on_error)

	add_to_group("unit_agent")
	set_process(true)
	_notify_route_changed()


func reload_rules(rules: String) -> void:
	_extra_rules = rules
	_api.set_system_prompt(_build_system_prompt())


func _process(delta: float) -> void:
	_recover_org(delta)
	if debug_mode:
		_debug_update_elapsed += delta
		if _debug_update_elapsed >= 0.5:
			_debug_update_elapsed = 0.0
			_push_debug_text()


func _recover_org(delta: float) -> void:
	if unit == null or _in_battle:
		return
	if unit.ORG >= 80.0:
		_recover_timer = 0.0
		return
	var rate: float
	if _is_collapsed:
		_collapse_elapsed += delta
		rate = 0.1
		if _collapse_elapsed >= 60.0:
			_is_collapsed = false
	else:
		rate = (5.0 + unit.PROF) * 0.03
	if _hex_map != null and _hex_map.has_method("get_tile_type_at"):
		var pos := _get_unit_pos()
		if _hex_map.get_tile_type_at(pos.x, pos.y) == 4:
			rate *= 3.0
	_recover_timer += delta
	if _recover_timer >= 1.0:
		var gain := minf(rate * _recover_timer, 80.0 - unit.ORG)
		_recover_timer = 0.0
		if gain > 0.001:
			unit.ORG = unit.ORG + gain
			if _hex_map != null and _hex_map.has_method("update_unit_org"):
				_hex_map.update_unit_org(unit.unit_name, unit.ORG)


func _push_debug_text() -> void:
	if _hex_map == null or unit == null:
		return
	if not _hex_map.has_method("set_unit_debug_text"):
		return
	var snapshot := get_queue_snapshot()
	if snapshot.is_empty():
		_hex_map.set_unit_debug_text(unit.unit_name, "空")
		return
	var parts: Array[String] = []
	for item: Dictionary in snapshot:
		parts.append("#%d[%s]%s" % [item.get("id", 0), item.get("status", ""), item.get("type", "")])
	_hex_map.set_unit_debug_text(unit.unit_name, ", ".join(parts))


func enter_battle(battle_id: String) -> void:
	_in_battle = true
	receive_event("combat_start", {
		"battle_id": battle_id,
		"message": "你的部队正在交战。移动指令暂停。玩家指令将转发至战斗仲裁系统，你只需简短确认收到即可。"
	})


func exit_battle(outcome: String, battle_id: String) -> void:
	_in_battle = false
	if outcome == "defeat":
		_is_collapsed = true
		_collapse_elapsed = 0.0
	receive_event("combat_ended", {"battle_id": battle_id, "outcome": outcome})


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


# ── Public queue API (called by enemy agent or other external controllers) ────

func apply_stats_immediate(params: Dictionary) -> Dictionary:
	if unit == null:
		return {"error": "单位不可用"}
	var changes: Dictionary = params.get("changes", {})
	var reason: String      = params.get("reason", "")
	var duration: float     = float(params.get("duration", -1.0))
	unit.apply_changes(changes)
	stats_changed.emit({"changes": changes, "reason": reason})
	if duration > 0.0:
		_start_timed_revert(changes, reason, duration)
	return {"applied_immediate": true, "changes": changes}


func enqueue_external(type: String, params: Dictionary, retain: bool = false) -> Dictionary:
	var item := {
		"id":         _next_queue_id,
		"type":       type,
		"params":     params,
		"status":     "pending",
		"retain":     retain,
		"created_at": Time.get_unix_time_from_system()
	}
	_next_queue_id += 1
	_exec_queue.append(item)
	if debug_mode:
		debug_log.emit("[DEBUG] [%s][ext] 入队 #%d type=%s params=%s" % [
			unit.unit_name if unit != null else "?",
			item["id"], type, JSON.stringify(params)
		])
	_notify_route_changed()
	_maybe_start_exec()
	return {"queued_id": item["id"], "queue_size": _exec_queue.size()}


func delete_queue_external(target_id: int) -> Dictionary:
	for item: Dictionary in _exec_queue:
		if int(item.get("id", -1)) == target_id:
			if item.get("status") == "running":
				if item.get("type") == "move_to":
					item["status"] = "cancelled"
					return {"cancelled_id": target_id}
				return {"error": "正在执行（原子性保护），无法取消"}
			if item.get("status") == "completed":
				return {"skipped": true, "reason": "已完成"}
			item["status"] = "cancelled"
			_notify_route_changed()
			return {"cancelled_id": target_id}
	return {"error": "id %d 未找到" % target_id}


func clear_queue_external() -> Dictionary:
	for item: Dictionary in _exec_queue:
		var st: String = item.get("status", "")
		if st == "pending":
			item["status"] = "cancelled"
		elif st == "running" and item.get("type") == "move_to":
			item["status"] = "cancelled"
	_notify_route_changed()
	return {"cleared": true}


func get_queue_snapshot() -> Array:
	var out: Array = []
	for item: Dictionary in _exec_queue:
		var st: String = item.get("status", "")
		if st in ["pending", "running"] or (st == "completed" and item.get("retain", false)):
			out.append(item)
	return out


func _collect_planned_move_steps() -> Array:
	var out: Array = []
	if _hex_map == null or unit == null:
		return out

	var cursor := _get_unit_pos()
	for item: Dictionary in _exec_queue:
		var st: String = item.get("status", "")
		if not (st == "pending" or st == "running"):
			continue

		var tp: String = item.get("type", "")
		var p: Dictionary = item.get("params", {})
		if not p.has("col") or not p.has("row"):
			continue

		var tc := int(p["col"])
		var tr := int(p["row"])
		if tp == "move_to" and _hex_map.has_method("calc_path"):
			var segment: Array = _hex_map.calc_path(cursor.x, cursor.y, tc, tr)
			if segment.is_empty():
				# Fall back to endpoint when dynamic obstacles make path temporarily unavailable.
				_append_unique_step(out, tc, tr)
				cursor = Vector2i(tc, tr)
				continue
			for step in segment:
				if not (step is Array) or (step as Array).size() < 2:
					continue
				var sc := int(step[0])
				var sr := int(step[1])
				if sc == cursor.x and sr == cursor.y:
					continue
				_append_unique_step(out, sc, sr)
				cursor = Vector2i(sc, sr)
		elif tp == "move":
			_append_unique_step(out, tc, tr)
			cursor = Vector2i(tc, tr)

	return out


func _append_unique_step(out: Array, col: int, row: int) -> void:
	if out.is_empty():
		out.append([col, row])
		return
	var last = out[out.size() - 1]
	if last is Array and (last as Array).size() >= 2 and int(last[0]) == col and int(last[1]) == row:
		return
	out.append([col, row])


func _notify_route_changed() -> void:
	if _hex_map == null or unit == null:
		return
	if not _hex_map.has_method("set_unit_planned_route"):
		return
	_hex_map.set_unit_planned_route(unit.unit_name, _collect_planned_move_steps())


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
			if _in_battle and args.get("type") == "move":
				return {"error": "当前正在交战，移动指令已暂停。交战期间请通过战斗指挥系统下令。"}
			var tp: String = args.get("type", "")
			# Immediate modify_stats: bypass queue entirely
			if bool(args.get("immediate", false)) and tp == "modify_stats":
				if unit == null:
					return {"error": "单位不可用"}
				var prms: Dictionary = args.get("params", {})
				var changes: Dictionary = prms.get("changes", {})
				var reason: String = prms.get("reason", "")
				var duration: float = float(prms.get("duration", -1.0))
				unit.apply_changes(changes)
				stats_changed.emit({"changes": changes, "reason": reason})
				if debug_mode:
					debug_log.emit("[DEBUG] [%s] 立即执行 modify_stats: %s" % [
						unit.unit_name if unit != null else "?", JSON.stringify(changes)])
				if duration > 0.0:
					_start_timed_revert(changes, reason, duration)
				return {"applied_immediate": true, "changes": changes}
			var item := {
				"id":         _next_queue_id,
				"type":       tp,
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
			_notify_route_changed()
			_maybe_start_exec()
			return {"queued_id": item["id"], "queue_size": _exec_queue.size()}

		"delete_queue_item":
			var target_id := int(args.get("id", -1))
			for item: Dictionary in _exec_queue:
				if int(item.get("id", -1)) == target_id:
					if item.get("status") == "running":
						if item.get("type") == "move_to":
							item["status"] = "cancelled"
							return {"cancelled_id": target_id}
						return {"error": "正在执行（原子性保护），无法取消"}
					if item.get("status") == "completed":
						return {"skipped": true, "reason": "已完成，无需取消"}
					item["status"] = "cancelled"
					_notify_route_changed()
					return {"cancelled_id": target_id}
			return {"error": "id %d 未找到" % target_id}

		"clear_exec_queue":
			for item: Dictionary in _exec_queue:
				var st: String = item.get("status", "")
				if st == "pending":
					item["status"] = "cancelled"
				elif st == "running" and item.get("type") == "move_to":
					item["status"] = "cancelled"
			_notify_route_changed()
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

		"split_unit":
			if _has_split:
				return {"error": "此部队已执行过拆分，不可重复拆分"}
			var frags: Array = args.get("fragments", [])
			if frags.size() < 2:
				return {"error": "至少需要拆分为2个子部队"}
			var reason: String = args.get("reason", "")
			var ui2 := get_tree().get_first_node_in_group("commander_ui")
			if ui2 == null:
				return {"error": "UI不可用"}
			var history := get_api_history()
			_has_split = true
			return ui2.do_split(unit, self, frags, history)

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
		_notify_route_changed()
		await _execute_item(item)
		if item.get("status") == "cancelled":
			_exec_queue.erase(item)
		elif item.get("retain", false):
			item["status"] = "completed"
		else:
			_exec_queue.erase(item)
		_notify_route_changed()
	_exec_running = false
	_notify_route_changed()


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
			if _hex_map.has_method("is_unit_frozen") and _hex_map.is_unit_frozen(unit.unit_name):
				return  # Frozen (in battle); LLM will replan after combat_ended event
			var col := int(p.get("col", 0))
			var row := int(p.get("row", 0))
			_hex_map.set_move_path(unit.unit_name, [[col, row]])
			while true:
				var emitted_name: String = await _hex_map.movement_finished
				if emitted_name == unit.unit_name:
					break

		"move_to":
			if _hex_map == null or not _hex_map.has_method("set_move_path") or unit == null:
				return
			if _hex_map.has_method("is_unit_frozen") and _hex_map.is_unit_frozen(unit.unit_name):
				return
			var tc := int(p.get("col", 0))
			var tr := int(p.get("row", 0))
			var pos := _get_unit_pos()
			var path: Array = _hex_map.calc_path(pos.x, pos.y, tc, tr)
			if path.is_empty():
				return
			var start_idx := 0
			if int(path[0][0]) == pos.x and int(path[0][1]) == pos.y:
				start_idx = 1
			for i in range(start_idx, path.size()):
				if item.get("status") == "cancelled":
					return
				if _hex_map.has_method("is_unit_frozen") and _hex_map.is_unit_frozen(unit.unit_name):
					return
				_notify_route_changed()
				var step = path[i]
				_hex_map.set_move_path(unit.unit_name, [[int(step[0]), int(step[1])]])
				while true:
					var emitted_name: String = await _hex_map.movement_finished
					if emitted_name == unit.unit_name:
						break
				_notify_route_changed()

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
			var delay_secs: float   = float(p.get("delay_seconds", 0.0))
			var duration: float     = float(p.get("duration", -1.0))

			# Wait for delay before applying
			if delay_secs > 0.0:
				var elapsed := 0.0
				while elapsed < delay_secs:
					if item.get("status") == "cancelled":
						return
					var step := minf(delay_secs - elapsed, 1.0)
					await get_tree().create_timer(step).timeout
					elapsed += step
				if item.get("status") == "cancelled":
					return

			# Apply the stat changes
			unit.apply_changes(changes)
			stats_changed.emit({"changes": changes, "reason": reason})

			if duration < 0.0:
				# Permanent — mark for retention in queue snapshot
				item["retain"] = true
				return

			if duration > 0.0:
				_start_timed_revert(changes, reason, duration)

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
	var debug_key := "debug_on" if debug_mode else "debug_off"
	var debug_section := "\n\n" + PromptLoader.get_template("unit_agent", debug_key)
	return PromptLoader.get_template("unit_agent", "system") \
		.replace("{unit_name}", unit_name) \
		.replace("{map_str}", map_str) \
		.replace("{rules_section}", rules_section) \
		.replace("{debug_section}", debug_section)


# ── Helpers ───────────────────────────────────────────────────────────────────

func get_api_history() -> Array:
	if _api == null:
		return []
	var h: Array = _api.get_history()
	# Strip any trailing assistant message with unresolved tool_calls — injecting it
	# into a new agent would violate the API rule that tool_calls must be followed
	# immediately by tool result messages.
	if not h.is_empty():
		var last = h[-1]
		if last is Dictionary and last.get("role") == "assistant" and last.has("tool_calls"):
			h = h.slice(0, h.size() - 1)
	return h


func inject_history(history: Array) -> void:
	if _api != null:
		_api.inject_history(history)


func _start_timed_revert(changes: Dictionary, reason: String, duration: float) -> void:
	await get_tree().create_timer(duration).timeout
	_revert_changes(changes, reason)


func _revert_changes(changes: Dictionary, original_reason: String) -> void:
	if unit == null:
		return
	var revert: Dictionary = {}
	for stat in changes.keys():
		revert[stat] = -float(changes[stat])
	unit.apply_changes(revert)
	stats_changed.emit({"changes": revert, "reason": "效果到期/取消：" + original_reason})


func _get_unit_pos() -> Vector2i:
	if _hex_map == null or unit == null:
		return Vector2i.ZERO
	return _hex_map.get_unit_pos(unit.unit_name)
