# Agent Commander

一个基于 Godot 4 的 3D 战略游戏原型项目，当前已包含基础地图与相机平移控制。

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
├─ addons/
│  └─ godot-git-plugin/          # Godot Git 插件（版本控制集成）
├─ assets/                       # 资产内容，包括3D模型、材质、纹理、音频等
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

### 编辑器流程

1. 打开并运行 `res://scenes/map_editor.tscn`。
2. 点击 **Generate Random** 随机生成地图（沿用当前地图逻辑）。
3. 点击 **Save Map** 保存到 `res://maps/default_map.tres`，并尝试导出到 `user://maps/default_map.tres`。

### 游戏流程

1. 打开并运行 `res://scenes/game_main.tscn`。
2. 场景启动时固定读取 `res://maps/default_map.tres`。
3. 若读取失败，会回退为随机地图并打印 warning。

## 运行方式

1. 使用 Godot 4.6+ 打开项目根目录。
2. 直接运行项目会先进入主菜单。
3. 在主菜单中选择地图后点击 **Start Game** 进入游戏。
4. 点击 **Map Editor** 进入地图编辑器。
5. 如需直接运行固定地图开局，请手动运行 `res://scenes/game_main.tscn`。
6. 默认输入：
   - `W/A/S/D`：相机平移
   - 鼠标滚轮输入动作已预留（`zoom_in` / `zoom_out`）
