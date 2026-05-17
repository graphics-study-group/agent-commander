extends Node3D

# 移动速度、缩放速度
@export var move_speed: float = 8.0
@export var zoom_speed: float = 0.8
# 相机远近限制
@export var min_zoom: float = 6.0
@export var max_zoom: float = 25.0

@onready var cam: Camera3D = $Camera3D

var _zoom := 6.0

func _ready() -> void:
	_zoom = clampf(cam.position.y, min_zoom, max_zoom)
	_apply_zoom()

func _process(delta: float) -> void:
	# WASD 平移
	var input_dir := Vector3.ZERO
	if Input.is_action_pressed("ui_left"):  input_dir.x -= 1
	if Input.is_action_pressed("ui_right"): input_dir.x += 1
	if Input.is_action_pressed("ui_up"):input_dir.z -= 1
	if Input.is_action_pressed("ui_down"):input_dir.z += 1

	if Input.is_action_just_pressed("zoom_in"):
		_zoom = clampf(_zoom - zoom_speed, min_zoom, max_zoom)
		_apply_zoom()
	elif Input.is_action_just_pressed("zoom_out"):
		_zoom = clampf(_zoom + zoom_speed, min_zoom, max_zoom)
		_apply_zoom()

	# 保持俯视平面移动，不歪
	input_dir = input_dir.normalized()
	position += input_dir * move_speed * delta


func _apply_zoom() -> void:
	cam.position = Vector3(0.0, _zoom, _zoom)
