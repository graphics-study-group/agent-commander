class_name PromptLoader

# Loads prompts.json from the exe directory first, then falls back to res://.
# Use String.replace() (not String.format()) to substitute {placeholders}.

static var _cache: Dictionary = {}
static var _loaded: bool = false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true

	# Try exe dir first (user-editable when packaged)
	var exe_dir := OS.get_executable_path().get_base_dir()
	var ext_path := exe_dir.path_join("prompts.json")
	var text := ""

	var fa := FileAccess.open(ext_path, FileAccess.READ)
	if fa != null:
		text = fa.get_as_text()
		fa.close()
	else:
		var fa2 := FileAccess.open("res://prompts.json", FileAccess.READ)
		if fa2 != null:
			text = fa2.get_as_text()
			fa2.close()

	if text.is_empty():
		push_error("PromptLoader: prompts.json not found")
		return

	var j := JSON.new()
	if j.parse(text) != OK or not j.get_data() is Dictionary:
		push_error("PromptLoader: failed to parse prompts.json")
		return

	_cache = j.get_data()


static func get_section(agent: String) -> Dictionary:
	_ensure_loaded()
	var sec = _cache.get(agent)
	return sec if sec is Dictionary else {}


static func get_template(agent: String, key: String, fallback: String = "") -> String:
	var sec := get_section(agent)
	var val = sec.get(key, fallback)
	return val if val is String else fallback
