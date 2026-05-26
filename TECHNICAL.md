# Agent Commander — 技术文档

> Godot 4.6 + DeepSeek API 驱动的六角格战棋游戏  
> 引擎：Mobile Renderer / D3D12 / Jolt Physics 3D  
> 视口：1680×1050，主场景：`scenes/main_menu.tscn`

---

## 目录

1. [项目结构](#1-项目结构)
2. [架构概览](#2-架构概览)
3. [AI Agent 系统](#3-ai-agent-系统)
4. [地图与六角格引擎](#4-地图与六角格引擎)
5. [单位系统](#5-单位系统)
6. [战斗系统](#6-战斗系统)
7. [UI 与控制](#7-ui-与控制)
8. [数据资源](#8-数据资源)
9. [Prompt 配置](#9-prompt-配置)
10. [外部依赖与配置文件](#10-外部依赖与配置文件)
11. [信号流图](#11-信号流图)

---

## 1. 项目结构

```
agent-commander/
├── scripts/
│   ├── unit_agent.gd          # 蓝方单位 AI 控制器
│   ├── enemy_agent.gd         # 红方全局 AI 控制器
│   ├── commander_agent.gd     # 蓝方高级指挥路由
│   ├── battle_agent.gd        # 战斗裁判 Agent
│   ├── hex_map.gd             # 六角格地图引擎（~1000 行）
│   ├── unit.gd                # 单位数据资源
│   ├── unit_marker.gd         # 单位 3D 标记节点
│   ├── route_arrow_renderer.gd# 移动路径可视化
│   ├── supply_marker.gd       # 补给车队标记
│   ├── commander_ui.gd        # 聊天 UI 与指令路由（~1350 行）
│   ├── map_data.gd            # 地图序列化资源
│   ├── map_editor.gd          # 地图编辑器逻辑
│   ├── deepseek_api.gd        # DeepSeek HTTP 客户端
│   ├── prompt_loader.gd       # prompts.json 热加载
│   ├── camera_pivot.gd        # 摄像机控制
│   ├── game_main.gd           # 游戏入口
│   ├── app_state.gd           # 跨场景状态单例（Autoload）
│   └── bgm_controller.gd      # 背景音乐管理（Autoload）
├── scenes/
│   ├── main_menu.tscn
│   ├── game_main.tscn
│   ├── commander_ui.tscn
│   ├── map_editor.tscn
│   ├── tiles/                 # TileBase + Plain/Forest/Mountain/Water/City
│   └── units/                 # UnitMarker + RouteArrowRenderer + SupplyMarker
├── maps/
│   ├── default_map.tres       # 默认地图（游戏启动时加载）
│   └── *.tres                 # 其他地图存档
├── prompts.json               # Agent 系统提示词（可热更新）
├── api_key.txt                # DeepSeek API 密钥（不纳入版本控制）
└── token_usage.log            # API 调用 token 统计
```

---

## 2. 架构概览

游戏采用**事件驱动 + LLM 工具调用**架构：玩家的自然语言指令经由多层 Agent 路由到各单位，单位 Agent 将 LLM 响应转化为结构化动作队列，由 GDScript 执行器异步消费。

```
玩家文字指令
      │
      ▼
CommanderAgent (deepseek-v4-pro)
  └─ dispatch_to_unit(unit_name, command, reason)
             │
             ▼
       UnitAgent × N                    EnemyAgent (全局)
  ├─ enqueue_action(move_to / ...)      └─ enqueue_action → 各敌方 UnitAgent
  ├─ delete_queue_item                          │
  └─ emit_event                                 │
             │                                  │
             ▼                                  ▼
       执行队列（GDScript）────────────── HexMap 引擎
  ├─ move_to → hex_map.set_move_path()         │
  ├─ modify_stats → unit.apply_changes()        ▼
  └─ emit_event → 广播给其他 Agent      unit_collision 信号
                                               │
                                               ▼
                                        BattleAgent（per-battle）
                                  ├─ modify_unit_stats（增量）
                                  └─ end_battle(winner, narrative)
```

---

## 3. AI Agent 系统

### 3.1 UnitAgent (`unit_agent.gd`)

单位级别的 AI 控制器，蓝方每个单位一个实例。

**核心机制**
- 维护 **事件收件箱**（inbox）与 **执行队列**（exec_queue）
- 队列项状态：`pending → running → completed / cancelled`
- 调用 DeepSeek API，解析函数调用，将动作写入队列
- 队列执行器：按序异步执行，`move_to` 等待 `movement_finished` 信号后才继续

**可用工具（Tool Calls）**

| 工具 | 说明 |
|------|------|
| `enqueue_action` | 添加 move_to / wait / modify_stats / emit_event |
| `delete_queue_item` | 取消待执行项 |
| `clear_exec_queue` | 清空队列 |
| `dispatch_event` | 向其他 Agent 发送事件 |
| `name_point` | 为地图格命名 |
| `rename_unit` | 单位重命名 |
| `split_unit` | 拆分单位（创建新 UnitAgent） |

**ORG 恢复机制**
- 基础恢复速率：3%/秒
- 城市格加成：×3（9%/秒）
- ORG < 阈值（80%）时恢复暂停
- 崩溃后 60 秒重置

**信号**

| 信号 | 触发时机 |
|------|---------|
| `response_ready(text)` | LLM 返回响应 |
| `stats_changed(unit_name)` | 单位属性变化 |
| `debug_log(unit_name, text)` | 调试文本更新 |

**Token 管理**：输入超 ~3M 字符时发出警告；支持历史注入（用于单位克隆）。

---

### 3.2 EnemyAgent (`enemy_agent.gd`)

红方全局 AI，统一控制所有敌方单位。

- **30 秒**空闲重评估间隔，自动扫描战场态势
- 工具：`enqueue_action`（代理到对应敌方 UnitAgent）、`send_combat_order`
- **不清空历史**（永久保留），最大化 DeepSeek 前缀缓存命中率，降低 token 成本

---

### 3.3 CommanderAgent (`commander_agent.gd`)

蓝方高级指挥，负责将玩家模糊指令路由到具体单位。

- 唯一工具：`dispatch_to_unit(unit_name, command, reason)`
- 单次响应必须批量发出所有 dispatch 调用
- 信号：`routing_complete(dispatched_count)`

---

### 3.4 BattleAgent (`battle_agent.gd`)

战斗发生时动态创建，一场战斗一个实例。

- 模型：deepseek-v4-pro
- **10 秒/回合**分辨窗口
- 工具：`modify_unit_stats`（增量修改）、`end_battle(winner, narrative)`

**战斗公式要点**

| 要素 | 规则 |
|------|------|
| 主动权 | RECON + STAFF + SPEED 决定先手 |
| 地形加成 | 树林/山地 ×2.0，城市 ×2.5（防御方享受） |
| 援军 | 第一防守单位享地形加成，援军不享 |
| 士气崩溃 | MORALE < 阈值时单位溃逃 |
| 每回合伤害 | 基础值 ×10（对应 10 秒时间窗口） |

---

### 3.5 DeepSeek API 客户端 (`deepseek_api.gd`)

- HTTP 流式请求，解析 Server-Sent Events
- 函数调用（Function Calling）完整支持
- Token 统计写入 `token_usage.log`
- 支持历史注入：传入 `extra_messages[]` 合并到请求历史

---

## 4. 地图与六角格引擎

### 4.1 网格规格

```
GRID_COLS = 16,  GRID_ROWS = 16
H_STEP    = 1.732  (列间距，水平)
V_STEP    = 1.5    (行间距，垂直)
ROW_OFFSET = 0.866 (奇数行右偏)
HEX_DIST_KM = 40.0 km/格
```

奇偶行各有不同的邻格偏移表（`OFFSETS_EVEN` / `OFFSETS_ODD`）。

### 4.2 地形类型

| 枚举值 | 名称 | 可通行 |
|--------|------|--------|
| 0 PLAIN | 平原 | ✓ |
| 1 FOREST | 树林 | ✓ |
| 2 MOUNTAIN | 山地 | ✗ |
| 3 WATER | 水域 | ✗ |
| 4 CITY | 城市 | ✓ |

### 4.3 道路系统

每格道路数据为 **6 位掩码**（bit 0–5 对应 6 个方向），写入双向，由 `set_road_at()` 维护一致性。

A* 寻路代价：
- 草地格：`ASTAR_GRASS = 10.0`
- 道路格：`ASTAR_ROAD = 5.0`（速度基准 SPEED=10 时，对应实际移动时间）

### 4.4 主要公开 API

```gdscript
# 路径计算
calc_path(fc, fr, tc, tr) -> Array          # 返回 [[col, row], ...]
set_move_path(unit_name, path)              # 设置并立即执行移动

# 地图查询
get_tile_type_at(col, row) -> int
get_road_mask_at(col, row) -> int
get_position_info(unit_name) -> String      # 供 AI 上下文使用
get_map_string() -> String                  # ASCII 地图全局视图

# 单位管理
register_unit(unit, color, col, row, is_enemy)
unregister_unit(unit_name)
teleport_unit(unit_name, col, row)
freeze_unit / unfreeze_unit                 # 战斗期间锁定单位

# 道路编辑
set_road_at(col, row, direction, enabled) -> bool
set_tile_type_at(col, row, tile_type) -> bool
```

### 4.5 信号

| 信号 | 参数 |
|------|------|
| `movement_finished` | `unit_name: String` |
| `hex_coord_selected` | `col: int, row: int` |
| `unit_collision` | `mover_name: String, resident_name: String` |

### 4.6 地图生成

- **随机生成**：`regenerate_map()` — 随机分布地形 + 城市间自动连路（贪心最小生成树 + 随机碎段）
- **纯平原**：`regenerate_map(cols, rows, all_plain=true)`
- **加载存档**：`load_map_from_path(path)` — 读取 `MapData` 资源

---

## 5. 单位系统

### 5.1 Unit 资源 (`unit.gd`)

10 个属性（均 float，范围 0–100 除非特殊说明）：

| 属性 | 含义 |
|------|------|
| ATK | 攻击力 |
| DEF | 防御力 |
| ORG | 组织度（战斗力核心） |
| MORALE | 士气 |
| PROF | 专业度 |
| RECON | 侦察力（影响视野与主动权） |
| STR | 兵力（0 时单位消亡） |
| SUPPLY | 补给消耗率 |
| SPEED | 移动速度（影响移动时间） |
| STAFF | 参谋能力（影响主动权与侦察） |

关键方法：
- `apply_changes(delta: Dictionary)` — 增量修改并 clamp
- `get_state_summary() -> String` — 供 AI 读取的简短状态
- `get_display_text() -> String` — Tooltip 富文本显示

### 5.2 UnitMarker (`unit_marker.gd`)

3D 场景节点，包含：
- 单位模型（按阵营/类型选择：Archer/Knight/Spearman/Swordsman）
- 血条：颜色随 ORG 渐变（绿 → 橙 → 红）
- 路径箭头渲染器（`RouteArrowRenderer`）
- `set_org(value)` 更新血条
- `face_towards(target_pos)` 朝向控制

### 5.3 战斗轨道动画

单位在战斗时进入 `combat_orbit` 状态，在目标格周围做圆形绕飞：

```gdscript
# orbit 字典结构
{
  "center_col": int, "center_row": int,
  "radius": float, "phase": float,
  "angular_speed": float, "clockwise": bool,
  "battle_id": String
}
```

---

## 6. 战斗系统

**触发**：不同阵营单位移动至同一格 → `unit_collision` 信号 → `commander_ui.gd` 创建 `BattleAgent`

**流程**

1. 双方单位冻结（`freeze_unit`），进入绕飞动画
2. BattleAgent 每 10 秒调用一次 LLM，生成 `modify_unit_stats` 工具调用
3. 属性修改实时同步到 Unit 资源并更新血条
4. BattleAgent 调用 `end_battle(winner, narrative)` 结束战斗
5. 败方单位 STR 归零则注销，胜方解除冻结继续移动

**胜利条件**（全局）
- 蓝方占领胜利城市持续 **1050 秒**，且
- 红方全体 STR ≤ **50%**

**补给系统**
- 补给周期：**150 秒**
- 补给链从出生点延伸，城市可作为中继节点
- `add_convoy_marker / update_convoy_marker / remove_convoy_marker` 管理补给车队动画

---

## 7. UI 与控制

### 7.1 CommanderUI (`commander_ui.gd`)

- 聊天输入框 → CommanderAgent / 直接下发
- 单位选择器（下拉菜单）
- GM 模式：持久化规则（`user://gm_rules.txt`），影响所有 Agent 系统提示
- 时间缩放滑条：1%–300%（`Engine.time_scale`）
- 事件日志与单位队列调试面板
- 字体大小切换：13 / 16 / 22 pt

### 7.2 摄像机控制 (`camera_pivot.gd`)

| 操作 | 功能 |
|------|------|
| WASD / 方向键 | 平移 |
| 鼠标右键拖拽 | 平移 |
| 滚轮 | 缩放（范围 6–25） |

### 7.3 地图编辑器 (`map_editor.gd`)

- 地形笔刷（点击/拖拽绘制）
- 道路连接工具（点两格连路）
- 单位模板放置与属性编辑
- AI 批量命名（`commander_ui.gd` 集成）
- 保存为 `.tres` 资源文件

---

## 8. 数据资源

### MapData (`map_data.gd`)

```gdscript
@export var version: int          # 当前 3
@export var cols: int
@export var rows: int
@export var tile_types: Array     # [row][col] int，地形枚举
@export var roads: Array          # [row][col] int，6 位方向掩码
@export var spawn_col: int
@export var spawn_row: int
@export var player_unit_count: int
@export var enemy_unit_count: int
@export var cell_region: Array    # [row][col] String，区域名
@export var victory_city_col: int
@export var victory_city_row: int
@export var unit_templates: Array # Array[Dictionary]，初始单位配置
```

`unit_templates` 中每项字典包含：
```gdscript
{
  "name": String, "is_enemy": bool,
  "col": int, "row": int,
  "ATK": float, "DEF": float, "ORG": float, "MORALE": float,
  "PROF": float, "RECON": float, "STR": float, "SUPPLY": float,
  "SPEED": float, "STAFF": float
}
```

### Autoloads

| 单例 | 文件 | 用途 |
|------|------|------|
| `AppState` | `app_state.gd` | 跨场景共享状态（如 `selected_map_path`）|
| `BgmController` | `bgm_controller.gd` | 背景音乐播放控制 |

---

## 9. Prompt 配置

`prompts.json` 定义四个 Agent 的系统提示，支持运行时热更新（将文件放在 exe 同目录即可覆盖）。

每个 Agent 条目结构：

```json
{
  "unit_agent":     { "system": "...", "debug_on": "...", "debug_off": "..." },
  "enemy_agent":    { "system": "...", "debug_on": "...", "debug_off": "..." },
  "commander_agent":{ "system": "...", "debug_on": "...", "debug_off": "..." },
  "battle_agent":   { "system": "...", "debug_on": "...", "debug_off": "..." }
}
```

**占位符**

| Agent | 占位符 |
|-------|--------|
| unit_agent | `{unit_name}` `{map_str}` `{rules_section}` `{debug_section}` |
| enemy_agent | `{enemy_names}` `{map_str}` `{rules_section}` |
| commander_agent | `{unit_names}` `{map_str}` `{rules_section}` |
| battle_agent | `{atk_side}` `{def_side}` `{terrain_name}` `{terrain_buff}` `{extra_section}` |

---

## 10. 外部依赖与配置文件

| 文件 | 说明 |
|------|------|
| `api_key.txt` | DeepSeek API 密钥，首行即密钥，**不纳入版本控制** |
| `prompts.json` | Agent 提示词，可在 exe 同目录放置以热更新 |
| `user://gm_rules.txt` | GM 模式自定义规则，跨会话持久化 |
| `token_usage.log` | 每次 API 调用的 token 消耗追加记录 |
| `maps/*.tres` | Godot 二进制资源格式的地图文件 |

---

## 11. 信号流图

```
玩家输入
  │
  ▼
CommanderUI.on_send_pressed()
  │
  ├─[GM/直接模式]──→ UnitAgent.receive_event("player_command")
  │
  └─[Commander模式]─→ CommanderAgent.send_command()
                           │  dispatch_to_unit 工具调用
                           ▼
                     UnitAgent.receive_event("player_command")
                           │  enqueue_action 工具调用
                           ▼
                     UnitAgent._exec_queue_runner()
                           │
                   ┌───────┴────────────┐
                   ▼                    ▼
           move_to 动作           modify_stats 动作
                   │                    │
         HexMap.set_move_path()   Unit.apply_changes()
                   │                    │
         (Tween 动画)           UnitAgent.stats_changed 信号
                   │                    │
         movement_finished 信号   CommanderUI 更新血条
                   │
         ┌─────────┴──────────┐
         ▼                    ▼
   继续队列          unit_collision 信号（碰到敌方）
                              │
                     BattleAgent.new() 创建
                              │
                    freeze_unit(mover + resident)
                              │
                     10s 战斗循环
                              │
                     end_battle(winner)
                              │
                    unfreeze_unit(winner)
                    unregister_unit(loser) [STR=0 时]
```
