# Agent Commander

一个基于 Godot 4 的 3D 战略游戏原型，以 AI Agent 体系（DeepSeek API function calling）为核心驱动双方部队的自主决策。

## 项目现状

- 引擎：Godot 4.6（`project.godot` 中配置）
- 默认主菜单：`res://scenes/main_menu.tscn`
- 地图编辑器场景：`res://scenes/map_editor.tscn`
- 游戏主场景（读取固定地图）：`res://scenes/game_main.tscn`
- 渲染方式：Mobile Renderer


## 目录结构

```text
.
├─ project.godot                 # Godot 项目配置
├─ icon.svg                      # 项目图标
├─ api_key.txt                   # DeepSeek API 密钥（不提交版本库）
├─ prompts.json                  # Agent 系统 prompt 模板（可热更新）
├─ token_usage.log               # API token 消耗日志（运行时生成）
├─ addons/
│  └─ godot-git-plugin/          # Godot Git 插件（版本控制集成）
├─ assets/                       # 资产内容，包括 3D 模型、材质、纹理、音频等
├─ scenes/                       # 场景，预制件等
└─ scripts/                      # 脚本
```

## 地图编辑与加载

- 地图数据类型：`MapData`（`res://scripts/map_data.gd`）
- 默认地图文件：`res://maps/default_map.tres`
- 编辑器另存一份到：`user://maps/default_map.tres`
- 地块架构：`TileBase` 基类场景 + 派生地块场景（Plain / Forest / Mountain / Water / City）

### 地块系统

- 基类地块：`res://scenes/tiles/TileBase.tscn` + `res://scripts/tiles/tile_base.gd`
- 预留地块类型：
   - 平原：`res://scenes/tiles/PlainTile.tscn`
   - 树林：`res://scenes/tiles/ForestTile.tscn`
   - 山地：`res://scenes/tiles/MountainTile.tscn`
   - 水域：`res://scenes/tiles/WaterTile.tscn`
   - 城市：`res://scenes/tiles/CityTile.tscn`
- 道路数据与地块类型分离保存，单个地块可携带道路 bitmask，并在地块节点上绘制道路覆盖层。

### 编辑器功能

1. 打开并运行 `res://scenes/map_editor.tscn`。
2. 点击 **Generate Random** 随机生成地图。
3. 点击 **Save Map** 保存到 `res://maps/default_map.tres`，并尝试导出到 `user://maps/default_map.tres`。
4. **地形绘制**：左侧面板选择地块类型后，左键点击/拖拽绘制。
5. **道路绘制**：选择道路方向，在相邻地块之间绘制或清除道路连接。
6. **地点命名**：为地图格设置地名，支持 AI 自动批量命名（调用 DeepSeek API）；地名以 3D 标签显示在地图上。
7. **胜利城市**：右键点击城市格可将其设为胜利目标，地图上显示金色六边形标记与「★胜利目标」文字。
8. **玩家 / 敌方部队数量**：在编辑器中设置双方各 1–5 支部队。
9. **部队属性编辑**：点击「编辑部队属性」打开右侧面板，可修改每支部队的初始名称、出生位置（Col / Row）及全部 10 项数值属性；修改在保存地图时随 `.tres` 文件持久化，游戏开局时直接读取。

### 游戏流程

1. 打开并运行 `res://scenes/game_main.tscn`。
2. 场景启动时固定读取 `res://maps/default_map.tres`。
3. 若读取失败，会回退为随机地图并打印 warning。

## AI Agent 系统

### Agent 类型

| Agent | 脚本 | 生命周期 | 职责 |
|---|---|---|---|
| CommanderAgent | `commander_agent.gd` | 全局常驻 | 将「全军」指令智能路由到各 UnitAgent |
| UnitAgent | `unit_agent.gd` | 每支蓝方部队 | 接收事件、维护执行队列、控制单位行动 |
| EnemyAgent | `enemy_agent.gd` | 全局常驻 | 统一指挥所有红方部队，30 秒自动重新评估战场 |
| BattleAgent | `battle_agent.gd` | 每场战斗独立实例 | 逐轮裁定双方伤亡，战斗结束后销毁 |

### 工具调用（Function Calling）

- **UnitAgent / EnemyAgent**：`calculate_path`、`enqueue_action`（move / wait / modify_stats / emit_event）、`delete_queue_item`、`clear_exec_queue`、`name_point`、`rename_unit`、`split_unit`、`send_combat_order`
- **BattleAgent**：`modify_unit_stats`、`end_battle`
- **CommanderAgent**：`dispatch_to_unit`

### Prompt 模板

Prompt 存放在 `prompts.json`（运行时优先加载 exe 同目录的同名文件，不存在时读取 `res://prompts.json`，支持打包后热更新）。每个 agent 的 prompt 结构：

- `system`：系统提示词
- `debug_on` / `debug_off`：调试模式附加段落

### Token 与上下文管理

- API 调用记录追加写入 `token_usage.log`（时间戳 + agent 类型 + 输入/输出字符估算）。
- 输入上下文超过约 300 万字符时触发 warning。
- EnemyAgent 不清空历史，以最大化 DeepSeek 前缀缓存命中率，降低 token 成本。
- BattleAgent 每场战斗独立实例，使用 `deepseek-v4-pro` 模型。

## 部队系统

### 属性（`scripts/unit.gd`）

| 属性 | 范围 | 说明 |
|---|---|---|
| ATK | 0–200 | 攻击 |
| DEF | 0–200 | 防御 |
| ORG | 0–100 | 组织度；降至 80 以下时被动恢复（速率 `(5+PROF)×0.03/s`，城市格 3 倍） |
| MORALE | 0–100 | 士气 |
| PROF | 0–100 | 专业度（影响 ORG 恢复速率） |
| RECON | 0–100 | 侦察 |
| STR | 0–100 | 兵力；低于初始值 50% 可触发胜利条件 |
| SUPPLY | 0–7 | 补给；每补给日消耗 1 点，运输队定期补充 |
| SPEED | 0–20 | 移动速度 |
| STAFF | 0–100 | 参谋（指挥能力） |

- 地图上的单位标记上方显示血条（绿→橙渐变），实时反映 ORG 值。
- `modify_stats` 支持 `delay_seconds`（延迟生效）和 `duration`（持续时长，-1 为永久）。
- 单位可通过 `split_unit` 拆分为多支部队，各继承原属性并按 `str_fraction` 缩放 STR 与 SUPPLY。

## 战斗系统

- **触发**：两支敌对单位移动至同一格时自动触发，双方进入冻结状态。
- **战斗轮次**：每 10 游戏秒一轮；BattleAgent 用 `modify_unit_stats` 裁定伤亡，用 `end_battle` 宣布胜负。
- **地形加成**（仅防守方）：树林 / 山地 ×2.0，城市 ×2.5；攻击方及增援部队无地形加成。
- **增援**：战斗进行中，其他单位进入该格即加入同侧战斗，但不享受地形加成。
- **战后**：胜方冻结 5 秒；败方撤退至相邻可通行格，并获得 +5 SPEED 持续 20 秒。
- **实时命令**：Agent 可通过 `send_combat_order` 在战斗进行中发送战术命令（撤退 / 坚守等）。

## 胜利条件

- 蓝方同时满足以下两个条件即获胜：
  1. 占领胜利城市持续 **1050 游戏秒**
  2. 将红方 STR 压缩至其初始值的 **50% 以下**
- 反之为红方胜利。
- 触发后显示全屏胜利面板，点击「返回主菜单」退出。

## 补给与运输

- 每 **150 游戏秒** 为一个补给日，每支蓝方部队消耗 1 点 SUPPLY。
- 补给不足时，运输队从部队出生地出发，沿最短路径追踪当前部队位置。
- 运输队每 **10 游戏秒** 前进 1 格，到达目标格后补充 +1 SUPPLY（上限 7）。
- 红方单位可拦截运输队（同格接触），补给转交拦截方。
- 地图上运输队以彩色小方块标记显示。

## 指挥官界面

游戏运行时右侧显示指挥官聊天面板（`commander_ui.gd`）。

### 目标选择器

- **全军**：消息发送给 CommanderAgent，由 AI 智能决定路由给哪些 UnitAgent。
- **单独部队**：消息直接发送给对应 UnitAgent。

### 斜杠命令

| 命令 | 功能 |
|---|---|
| `\debug` | 切换调试模式（显示执行队列状态及详细日志） |
| `\clear设定` | 清空全部 GM 规则 |

### GM 模式

- 点击界面右侧 **GM** 开关进入 GM 模式。
- 输入文字后发送，内容追加到 `user://gm_rules.txt`，实时同步到所有 Agent 的系统 prompt，跨局持久保存。

### 时间倍率

- 界面底部滑块控制游戏时间倍率（1%–300%），对应 `Engine.time_scale`。
- 相机输入与地图点击不受时间倍率影响。

## 运行方式

1. 使用 Godot 4.6+ 打开项目根目录。
2. 在项目根目录放置 `api_key.txt`，写入 DeepSeek API Key（无需引号，无需换行）。
3. 直接运行项目会先进入主菜单。
4. 在主菜单中选择地图后点击 **Start Game** 进入游戏。
5. 点击 **Map Editor** 进入地图编辑器。
6. 如需直接运行固定地图开局，请手动运行 `res://scenes/game_main.tscn`。

### 操作说明

| 操作 | 功能 |
|---|---|
| `W / A / S / D` 或方向键 | 相机平移 |
| 鼠标滚轮 | 相机缩放（范围 6–25） |
| 鼠标左键拖拽 | 相机平移 |
| `Enter` | 发送指令 |
| `Shift + Enter` | 指令输入框换行 |

## 外部配置文件

| 文件 | 说明 |
|---|---|
| `api_key.txt` | DeepSeek API Key，放置于项目根目录，不应提交版本库 |
| `prompts.json` | Agent 系统 prompt 模板，可在打包后直接替换 exe 旁的同名文件进行热更新 |
| `user://gm_rules.txt` | GM 模式规则，跨局持久保存 |
| `token_usage.log` | API 调用 token 用量记录，运行时自动追加 |
