extends Node

const API_URL := "https://api.deepseek.com/chat/completions"
const API_KEY := "sk-05394ae536894062a6bb05b9862a4ef7"

var _http: HTTPRequest
var _history: Array[Dictionary] = []
var _system_prompt: String = ""

signal response_received(content: String)
signal request_failed(error: String)


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_completed)


func set_system_prompt(prompt: String) -> void:
	_system_prompt = prompt
	_history.clear()


func send_message(user_content: String) -> void:
	if API_KEY.is_empty():
		request_failed.emit("API Key 未填写，请编辑 scripts/deepseek_api.gd 中的 API_KEY 常量。")
		return

	_history.append({"role": "user", "content": user_content})

	var messages: Array = []
	if not _system_prompt.is_empty():
		messages.append({"role": "system", "content": _system_prompt})
	messages.append_array(_history)

	var payload := JSON.stringify({
		"model": "deepseek-chat",
		"messages": messages,
		"stream": false
	})

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + API_KEY
	])

	var err := _http.request(API_URL, headers, HTTPClient.METHOD_POST, payload)
	if err != OK:
		_history.pop_back()
		request_failed.emit("HTTP 请求发送失败，错误码: %d" % err)


func clear_history() -> void:
	_history.clear()


func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
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
	if not (data is Dictionary) or not data.has("choices") or (data["choices"] as Array).is_empty():
		request_failed.emit("API 响应格式异常: %s" % JSON.stringify(data))
		return

	var content: String = data["choices"][0]["message"]["content"]
	_history.append({"role": "assistant", "content": content})
	response_received.emit(content)
