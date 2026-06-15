extends Node

const API_URL := "https://api.deepseek.com/chat/completions"
const TOKEN_LOG_PATH := "token_usage.log"

var _api_key: String = ""
var agent_type: String = "unknown"
var model: String = "deepseek-chat"
var max_tool_rounds: int = 25
var history_window: int = 0  # 0 = unlimited; >0 = keep last N messages before dispatch

var _http: HTTPRequest
var _history: Array[Dictionary] = []
var _system_prompt: String = ""
var _tool_round: int = 0
var tools: Array = []   # set before send_message to enable function-calling

signal response_received(content: String)
signal tool_calls_received(calls: Array)
signal request_failed(error: String)


func _ready() -> void:
	var app_state := get_node_or_null("/root/AppState")
	if app_state != null:
		_api_key = app_state.get("deepseek_api_key")
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_completed)


func set_system_prompt(prompt: String) -> void:
	_system_prompt = prompt


func send_message(user_content: String) -> void:
	if _api_key.is_empty():
		request_failed.emit("API Key 未填写，请在主菜单输入 DeepSeek API Key")
		return
	_tool_round = 0
	_history.append({"role": "user", "content": user_content})
	_dispatch()


func send_tool_results(results: Array) -> void:
	_tool_round += 1
	if _tool_round >= max_tool_rounds:
		request_failed.emit("工具调用轮次超限（%d轮），终止对话" % max_tool_rounds)
		return
	for r in results:
		_history.append(r)
	_dispatch()


func clear_history() -> void:
	_history.clear()
	_tool_round = 0


func get_history() -> Array:
	return _history.duplicate(true)


func inject_history(history: Array) -> void:
	for msg in history:
		if msg is Dictionary:
			_history.append((msg as Dictionary).duplicate(true))


func get_approx_chars() -> int:
	var total := _system_prompt.length()
	for msg: Dictionary in _history:
		var c = msg.get("content", "")
		if c is String:
			total += (c as String).length()
	return total


func _dispatch() -> void:
	var messages: Array = []
	if not _system_prompt.is_empty():
		messages.append({"role": "system", "content": _system_prompt})
	if history_window > 0 and _history.size() > history_window:
		messages.append_array(_history.slice(_history.size() - history_window))
	else:
		messages.append_array(_history)

	var payload_dict: Dictionary = {
		"model": model,
		"messages": messages,
		"stream": false
	}
	if not tools.is_empty():
		payload_dict["tools"] = tools

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + _api_key
	])
	var err := _http.request(API_URL, headers, HTTPClient.METHOD_POST,
		JSON.stringify(payload_dict))
	if err != OK:
		_history.pop_back()
		request_failed.emit("HTTP 请求失败，错误码: %d" % err)


func _on_completed(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		request_failed.emit("网络请求失败，结果码: %d" % result)
		return
	if code != 200:
		request_failed.emit("API 返回错误 HTTP %d:\n%s" % [code, body.get_string_from_utf8()])
		return

	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		request_failed.emit("无法解析 API 响应 JSON")
		return

	var data: Variant = json.get_data()
	if not (data is Dictionary) or not data.has("choices") \
			or (data["choices"] as Array).is_empty():
		request_failed.emit("API 响应格式异常")
		return

	var choice: Dictionary  = data["choices"][0]
	var message: Dictionary = choice["message"]
	var finish_reason: String = choice.get("finish_reason", "stop")

	# Token usage logging
	var usage: Dictionary = (data as Dictionary).get("usage", {})
	var in_chars: int = int(usage.get("prompt_tokens", 0)) * 3
	var out_chars: int = int(usage.get("completion_tokens", 0)) * 3
	if in_chars == 0:
		in_chars = get_approx_chars()
	_append_token_log(in_chars, out_chars)

	if finish_reason == "tool_calls":
		# Store the full assistant message (includes tool_calls array)
		_history.append(message)
		tool_calls_received.emit(message.get("tool_calls", []))
	else:
		var content: String = message.get("content", "")
		_history.append({"role": "assistant", "content": content})
		response_received.emit(content)


func _append_token_log(in_chars: int, out_chars: int) -> void:
	var log_path := ProjectSettings.globalize_path("res://") + TOKEN_LOG_PATH
	var fa := FileAccess.open(log_path, FileAccess.READ_WRITE)
	if fa == null:
		fa = FileAccess.open(log_path, FileAccess.WRITE)
	if fa == null:
		return
	fa.seek_end()
	var ts := Time.get_datetime_string_from_system(false, true)
	fa.store_line("%s [%s] in:%d out:%d" % [ts, agent_type, in_chars, out_chars])
	fa.close()
