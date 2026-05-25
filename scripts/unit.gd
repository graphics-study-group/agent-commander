class_name Unit
extends Resource

@export var unit_name: String = "Unknown"
@export var ATK: float = 50.0   # 攻击力
@export var DEF: float = 50.0   # 防御力
@export var ORG: float = 100.0  # 组织度（生命值）
@export var MORALE: float = 80.0 # 士气
@export var PROF: float = 50.0  # 熟练度
@export var RECON: float = 30.0 # 侦察力
@export var STR: float = 100.0  # 兵力 (%)
@export var SUPPLY: float = 7.0 # 补给值 (上限7天)
@export var SPEED: float = 3.0  # 移动速度
@export var STAFF: float = 40.0 # 参谋能力


func get_display_text() -> String:
	return (
		"[b]%s[/b]\n"
		+ "攻击力（ATK）: [color=red]%.0f[/color]    防御力（DEF）: [color=cyan]%.0f[/color]\n"
		+ "组织度（ORG）: [color=lime]%.0f[/color]    士气（MORALE）: [color=yellow]%.0f[/color]\n"
		+ "熟练度（PROF）: %.0f    侦察力（RECON）: %.0f\n"
		+ "兵力（STR）: %.0f%%    补给值（SUPPLY）: %.1f/7\n"
		+ "速度（SPEED）: %.0f    参谋（STAFF）: %.0f"
	) % [unit_name, ATK, DEF, ORG, MORALE, PROF, RECON, STR, SUPPLY, SPEED, STAFF]


func get_state_summary() -> String:
	return "部队[%s] 攻击力（ATK）:%.0f 防御力（DEF）:%.0f 组织度（ORG）:%.0f 士气（MORALE）:%.0f 熟练度（PROF）:%.0f 侦察力（RECON）:%.0f 兵力（STR）:%.0f%% 补给值（SUPPLY）:%.1f/7 速度（SPEED）:%.0f 参谋（STAFF）:%.0f" % [
		unit_name, ATK, DEF, ORG, MORALE, PROF, RECON, STR, SUPPLY, SPEED, STAFF
	]


func apply_changes(changes: Dictionary) -> void:
	if changes.has("ATK"):    ATK    = clamp(ATK    + float(changes["ATK"]),    0.0, 200.0)
	if changes.has("DEF"):    DEF    = clamp(DEF    + float(changes["DEF"]),    0.0, 200.0)
	if changes.has("ORG"):    ORG    = clamp(ORG    + float(changes["ORG"]),    0.0, 100.0)
	if changes.has("MORALE"): MORALE = clamp(MORALE + float(changes["MORALE"]), 0.0, 100.0)
	if changes.has("PROF"):   PROF   = clamp(PROF   + float(changes["PROF"]),   0.0, 100.0)
	if changes.has("RECON"):  RECON  = clamp(RECON  + float(changes["RECON"]),  0.0, 100.0)
	if changes.has("STR"):    STR    = clamp(STR    + float(changes["STR"]),    0.0, 100.0)
	if changes.has("SUPPLY"): SUPPLY = clamp(SUPPLY + float(changes["SUPPLY"]), 0.0, 7.0)
	if changes.has("SPEED"):  SPEED  = clamp(SPEED  + float(changes["SPEED"]),  0.0, 20.0)
	if changes.has("STAFF"):  STAFF  = clamp(STAFF  + float(changes["STAFF"]),  0.0, 100.0)
