# Agent Commander

一个基于 Godot 4 的 3D 战略游戏原型项目，当前已包含基础地图与相机平移控制。

## 项目现状

- 引擎：Godot 4.6（`project.godot` 中配置）
- 主要场景：`res://scenes/example_map.tscn`
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

## 运行方式

1. 使用 Godot 4.6+ 打开项目根目录。
2. 直接运行项目（当前主场景已在 `project.godot` 中指定）。
3. 默认输入：
   - `W/A/S/D`：相机平移
   - 鼠标滚轮输入动作已预留（`zoom_in` / `zoom_out`）
