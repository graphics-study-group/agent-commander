class_name UnitMarker
extends Node3D

const BAR_WIDTH := 0.9
const BAR_HEIGHT := 0.10

const MODEL_SCENES := {
	"knight":   "res://scenes/units/UnitVisualKnight.tscn",
	"spearman": "res://scenes/units/UnitVisualSpearman.tscn",
	"swordsman":"res://scenes/units/UnitVisualSwordsman.tscn",
	"archer":   "res://scenes/units/UnitVisualArcher.tscn",
}
const DEBUG_ROUTE_TILES := [[1, 1], [2, 3], [4, 5]]
const DEBUG_ROUTE_GRID_COLS := 16
const DEBUG_ROUTE_GRID_ROWS := 16
const CJK_FONT_3D := preload("res://assets/fonts/NotoSansSC-Regular.ttf")
const DEBUG_ROUTE_COLOR := Color(1.0, 0.9, 0.2, 1.0)

@export var debug_show_sample_route: bool = true

@onready var _visual: UnitVisualBase = $Visual
@onready var _route_renderer: RouteArrowRenderer = $RouteArrowRenderer
@onready var _route_renderer_debug: RouteArrowRenderer = $RouteArrowRendererDebug
@onready var _hp_fg: MeshInstance3D = $HPForeground
@onready var _hp_bg: MeshInstance3D = $HPBackground
@onready var _name_label: Label3D = $NameLabel

var _hp_fg_mat: StandardMaterial3D
var _hp_bg_mat: StandardMaterial3D
var _route_color: Color = Color(0.25, 0.55, 1.0, 1.0)
var _current_faction_color: Color = Color.WHITE


func _ready() -> void:
	_apply_debug_route()

func configure(unit_name: String, color: Color, is_enemy: bool = false) -> void:
	_current_faction_color = color
	name = "Marker_%s" % unit_name
	set_route_color(color)
	_apply_debug_route()
	if is_instance_valid(_visual):
		_visual.faction_color = color
		_visual.refresh_faction_color()
	_setup_health_bar_materials()
	if is_instance_valid(_name_label):
		_name_label.font = CJK_FONT_3D
		_name_label.text = unit_name
		if is_enemy:
			_name_label.modulate = Color(1.0, 0.35, 0.35)
			_name_label.outline_modulate = Color(0.3, 0.0, 0.0)
			_name_label.outline_size = 6
		else:
			_name_label.modulate = Color.WHITE


func set_route_color(color: Color) -> void:
	_route_color = color
	if is_instance_valid(_route_renderer):
		_route_renderer.set_faction_color(color)


func set_route_tiles(path_tiles: Array, grid_cols: int, grid_rows: int) -> void:
	if not is_instance_valid(_route_renderer):
		return
	_route_renderer.set_route_from_tiles(path_tiles, grid_cols, grid_rows, _route_color)


func clear_route() -> void:
	if not is_instance_valid(_route_renderer):
		return
	_route_renderer.clear_route()


func _apply_debug_route() -> void:
	if not is_instance_valid(_route_renderer_debug):
		return
	if not debug_show_sample_route:
		_route_renderer_debug.clear_route()
		return
	_route_renderer_debug.set_route_from_tiles(
		DEBUG_ROUTE_TILES,
		DEBUG_ROUTE_GRID_COLS,
		DEBUG_ROUTE_GRID_ROWS,
		DEBUG_ROUTE_COLOR
	)

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


func set_unit_name(new_name: String) -> void:
	if is_instance_valid(_name_label):
		_name_label.text = new_name


func face_towards(target_pos: Vector3) -> void:
	if not is_instance_valid(_visual):
		return
	var from := _visual.global_position
	var flat_target := Vector3(target_pos.x, from.y, target_pos.z)
	if from.distance_squared_to(flat_target) < 0.000001:
		return
	# Rotate only the visual mesh, keep HP/name anchors unrotated.
	_visual.look_at(flat_target, Vector3.UP)


func set_visual_model(model_type: String) -> void:
	if not MODEL_SCENES.has(model_type):
		return
	var packed := load(MODEL_SCENES[model_type]) as PackedScene
	if packed == null:
		return
	var new_visual := packed.instantiate() as UnitVisualBase
	if new_visual == null:
		return
	if is_instance_valid(_visual):
		_visual.queue_free()
	new_visual.name = "Visual"
	add_child(new_visual)
	_visual = new_visual
	_visual.faction_color = _current_faction_color
	_visual.refresh_faction_color()
