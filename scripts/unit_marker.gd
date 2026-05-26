class_name UnitMarker
extends Node3D

const BAR_WIDTH := 0.9
const BAR_HEIGHT := 0.10

@onready var _visual: UnitVisualBase = $Visual
@onready var _hp_fg: MeshInstance3D = $HPForeground
@onready var _hp_bg: MeshInstance3D = $HPBackground
@onready var _name_label: Label3D = $NameLabel

var _hp_fg_mat: StandardMaterial3D
var _hp_bg_mat: StandardMaterial3D

func configure(unit_name: String, color: Color, is_enemy: bool = false) -> void:
	name = "Marker_%s" % unit_name
	if is_instance_valid(_visual):
		_visual.faction_color = color
		_visual.refresh_faction_color()
	_setup_health_bar_materials()
	if is_instance_valid(_name_label):
		_name_label.text = unit_name
		if is_enemy:
			_name_label.modulate = Color(1.0, 0.35, 0.35)
			_name_label.outline_modulate = Color(0.3, 0.0, 0.0)
			_name_label.outline_size = 6
		else:
			_name_label.modulate = Color.WHITE

func set_org(org: float) -> void:
	if not is_instance_valid(_hp_fg) or not is_instance_valid(_hp_bg):
		return
	var pct := clampf(org / 100.0, 0.0, 1.0)
	var fg_w := BAR_WIDTH * pct
	var bg_w := BAR_WIDTH * (1.0 - pct)
	var fg_size := Vector2(maxf(fg_w, 0.001), BAR_HEIGHT)
	var bg_size := Vector2(maxf(bg_w, 0.001), BAR_HEIGHT)
	if _hp_fg.mesh is QuadMesh:
		(_hp_fg.mesh as QuadMesh).size = fg_size
	_hp_fg.position = Vector3(-BAR_WIDTH / 2.0 + fg_w / 2.0, 2.1, 0.05)
	if _hp_bg.mesh is QuadMesh:
		(_hp_bg.mesh as QuadMesh).size = bg_size
	_hp_bg.position = Vector3(BAR_WIDTH / 2.0 - bg_w / 2.0, 2.1, 0.05)

func _setup_health_bar_materials() -> void:
	if _hp_fg_mat == null:
		_hp_fg_mat = StandardMaterial3D.new()
		_hp_fg_mat.albedo_color = Color(0.2, 0.85, 0.2)
		_hp_fg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_hp_fg_mat.no_depth_test = true
		_hp_fg_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if _hp_bg_mat == null:
		_hp_bg_mat = StandardMaterial3D.new()
		_hp_bg_mat.albedo_color = Color(0.08, 0.08, 0.08)
		_hp_bg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_hp_bg_mat.no_depth_test = true
		_hp_bg_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if is_instance_valid(_hp_fg):
		_hp_fg.material_override = _hp_fg_mat
	if is_instance_valid(_hp_bg):
		_hp_bg.material_override = _hp_bg_mat


func face_towards(target_pos: Vector3) -> void:
	if not is_instance_valid(_visual):
		return
	var from := _visual.global_position
	var flat_target := Vector3(target_pos.x, from.y, target_pos.z)
	if from.distance_squared_to(flat_target) < 0.000001:
		return
	# Rotate only the visual mesh, keep HP/name anchors unrotated.
	_visual.look_at(flat_target, Vector3.UP)
