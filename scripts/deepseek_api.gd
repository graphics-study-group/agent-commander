extends Node

const API_URL := "https://api.deepseek.com/chat/completions"

static func _load_api_key() -> String:
	var fa := FileAccess.open("res://api_key.txt", FileAccess.READ)
	if fa == null:
		push_error("DeepSeekAPI: api_key.txt not found. Place your API key there.")
		return ""
	var key := fa.get_as_text().strip_edges()
	fa.close()
	return key

var _api_key: String = ""

var _http: HTTPRequest
var _history: Array[Dictionary] = []
var _system_prompt: String = ""
var tools: Array = []   # set before send_message to enable function-calling

signal response_received(content: String)
signal tool_calls_received(calls: Array)
signal request_failed(error: String)


func _ready() -> void:
	_api_key = _load_api_key()
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_completed)


func set_system_prompt(prompt: String) -> void:
	_system_prompt = prompt
	_history.clear()


func send_message(user_content: String) -> void:
	if _api_key.is_empty():
		request_failed.emit("API Key 未填写，请在项目根目录放置 api_key.txt")
		return
	_history.append({"role": "user", "content": user_content})
	_dispatch()


func send_tool_results(results: Array) -> void:
	# Each result: {role:"tool", tool_call_id:..., name:..., content:...}
	for r in results:
		_history.append(r)
	_dispatch()


func clear_history() -> void:
	_history.clear()


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
	messages.append_array(_history)

	var payload_dict: Dictionary = {
		"model": "deepseek-chat",
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

	if finish_reason == "tool_calls":
		# Store the full assistant message (includes tool_calls array)
		_history.append(message)
		tool_calls_received.emit(message.get("tool_calls", []))
	else:
		var content: String = message.get("content", "")
		_history.append({"role": "assistant", "content": content})
		response_received.emit(content)
