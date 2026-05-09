extends Node3D

# 移动速度、缩放速度
@export var move_speed: float = 8.0
@export var zoom_speed: float = 0.8
# 相机远近限制
@export var min_zoom: float = 6.0
@export var max_zoom: float = 25.0

var cam: Camera3D

func _ready():
    cam = get_child(0)

func _process(delta):
    # WASD 平移
    var input_dir = Vector3.ZERO
    if Input.is_action_pressed("ui_left"):  input_dir.x -= 1
    if Input.is_action_pressed("ui_right"): input_dir.x += 1
    if Input.is_action_pressed("ui_up"):input_dir.z -= 1
    if Input.is_action_pressed("ui_down"):input_dir.z += 1

    # 保持俯视平面移动，不歪
    input_dir = input_dir.normalized()
    position += input_dir * move_speed * delta
