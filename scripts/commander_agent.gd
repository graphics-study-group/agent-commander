class_name CommanderAgent
extends Node

signal response_ready(narrative: String)
signal routing_complete(dispatched_count: int)

const DeepSeekAPI = preload("res://scripts/deepseek_api.gd")

var _api: Node
var _hex_map: Node
var _units_list: Array  # live reference to commander_ui._units_list
var _extra_rules: String
var debug_mode: bool = false: set = _set_debug_mode

const TOOLS: Array = [
	{
		"type": "function",
		"function": {
			"name": "dispatch_to_unit",
			"description": "向指定部队的AI指挥官下达命令，该部队将自行决策如何执行。可多次调用以并行指挥多支部队。若指令仅与特定区域或条件相关，只调动符合条件的部队；若指令无需调动任何部队则不调用。",
			"parameters": {
				"type": "object",
				"properties": {
					"unit_name": {
						"type": "string",
						"description": "目标部队番号，需与部队状态列表中的名称完全一致"
					},
					"command": {
						"type": "string",
						"description": "传达给该部队AI的具体命令内容，语言清晰、可直接执行"
					},
					"reason": {
						"type": "string",
						"description": "选择该部队的理由，如：距目标最近、处于进攻路线上、供给充足等"
					}
				},
				"required": ["unit_name", "command", "reason"]
			}
		}
	}
]


func _set_debug_mode(value: bool) -> void:
	debug_mode = value
	if _api != null:
		_api.set_system_prompt(_build_system_prompt())


func setup(units_list: Array, hex_map: Node, extra_rules: String = "") -> void:
	_units_list = units_list
	_hex_map = hex_map
	_extra_rules = extra_rules

	_api = DeepSeekAPI.new()
	add_child(_api)
	_api.agent_type = "main_agent"
	_api.tools = TOOLS
	_api.response_received.connect(_on_final_response)
	_api.tool_calls_received.connect(_on_tool_calls)
	_api.request_failed.connect(_on_error)
	_api.set_system_prompt(_build_system_prompt())


func reload_rules(rules: String) -> void:
	_extra_rules = rules
	_api.set_system_prompt(_build_system_prompt())


func send_command(message: String) -> void:
	var ctx := _build_all_units_context()
	ctx += "\n\n【统帅指令】" + message
	_api.send_message(ctx)


# ── Tool call handling ────────────────────────────────────────────────────────

func _on_tool_calls(calls: Array) -> void:
	var results: Array = []
	var batch_dispatched := 0

	for call: Dictionary in calls:
		var fn: Dictionary   = call.get("function", {})
		var fn_name: String  = fn.get("name", "")
		var args_str: String = fn.get("arguments", "{}")
		var j := JSON.new()
		var args: Dictionary = {}
		if j.parse(args_str) == OK and j.get_data() is Dictionary:
			args = j.get_data()

		var result: Dictionary = {}
		if fn_name == "dispatch_to_unit":
			var unit_name: String = args.get("unit_name", "")
			var command: String   = args.get("command", "")
			var found := false
			for entry: Dictionary in _units_list:
				var u: Unit = entry["unit"]
				if u.unit_name == unit_name:
					var agent: Node = entry["agent"]
					if agent != null:
						agent.receive_event("player_command", {"message": command})
						batch_dispatched += 1
						found = true
					break
			result = {"dispatched": found, "unit": unit_name}
		else:
			result = {"error": "unknown tool: " + fn_name}

		results.append({
			"role":         "tool",
			"tool_call_id": call.get("id", ""),
			"name":         fn_name,
			"content":      JSON.stringify(result)
		})

	# Emit before sending tool results so UI can start tracking unit responses
	routing_complete.emit(batch_dispatched)
	_api.send_tool_results(results)


func _on_final_response(content: String) -> void:
	response_ready.emit(content)


func _on_error(error: String) -> void:
	routing_complete.emit(0)
	response_ready.emit("[指挥部通讯故障] " + error)


# ── Context builders ──────────────────────────────────────────────────────────

func _build_all_units_context() -> String:
	var lines: Array[String] = ["【各部队当前状态】"]
	for entry: Dictionary in _units_list:
		var u: Unit = entry["unit"]
		lines.append("▪ " + u.unit_name)
		lines.append("  " + u.get_state_summary())
		if _hex_map != null and _hex_map.has_method("get_position_info"):
			var pos_info: String = _hex_map.get_position_info(u.unit_name)
			if not pos_info.is_empty():
				lines.append("  " + pos_info)
	return "\n".join(lines)


func _build_system_prompt() -> String:
	var unit_names: PackedStringArray = []
	for entry: Dictionary in _units_list:
		unit_names.append((entry["unit"] as Unit).unit_name)

	var map_str := ""
	if _hex_map != null and _hex_map.has_method("get_map_string"):
		map_str = _hex_map.get_map_string() + "\n\n"

	var rules_section := ""
	if not _extra_rules.is_empty():
		rules_section = "\n\n【裁判额外设定（最高优先级）】\n" + _extra_rules

	var debug_key := "debug_on" if debug_mode else "debug_off"
	var debug_section := "\n\n" + PromptLoader.get_template("commander_agent", debug_key)

	return PromptLoader.get_template("commander_agent", "system") \
		.replace("{unit_names}", ", ".join(unit_names)) \
		.replace("{map_str}", map_str) \
		.replace("{rules_section}", rules_section) \
		.replace("{debug_section}", debug_section)
