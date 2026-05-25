extends Node3D

@export var move_speed: float = 8.0
@export var zoom_speed: float = 0.8
@export var min_zoom: float = 6.0
@export var max_zoom: float = 25.0

@onready var cam: Camera3D = $Camera3D

var _zoom := 6.0
var _is_dragging := false


func _ready() -> void:
	_zoom = clampf(cam.position.y, min_zoom, max_zoom)
	_apply_zoom()


func _process(delta: float) -> void:
	# Use real-world time so movement is unaffected by Engine.time_scale
	var real_delta := delta / maxf(Engine.time_scale, 0.001)

	var input_dir := Vector3.ZERO
	if Input.is_action_pressed("ui_left"):  input_dir.x -= 1
	if Input.is_action_pressed("ui_right"): input_dir.x += 1
	if Input.is_action_pressed("ui_up"):    input_dir.z -= 1
	if Input.is_action_pressed("ui_down"):  input_dir.z += 1

	input_dir = input_dir.normalized()
	position += input_dir * move_speed * real_delta


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_zoom = clampf(_zoom - zoom_speed, min_zoom, max_zoom)
				_apply_zoom()
				get_viewport().set_input_as_handled()
				return
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom = clampf(_zoom + zoom_speed, min_zoom, max_zoom)
				_apply_zoom()
				get_viewport().set_input_as_handled()
				return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_is_dragging = mb.pressed
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _is_dragging:
		var motion := event as InputEventMouseMotion
		var pan_scale := _zoom * 2.0 / get_viewport().get_visible_rect().size.y
		position.x -= motion.relative.x * pan_scale
		position.z -= motion.relative.y * pan_scale
		get_viewport().set_input_as_handled()


func _apply_zoom() -> void:
	cam.position = Vector3(0.0, _zoom, _zoom)
