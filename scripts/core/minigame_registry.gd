class_name MinigameRegistry
extends RefCounted

## 小游戏注册表
##
## 新增小游戏只需要两步：写好场景，然后在这里加一行映射。
## 剧本 `minigame <id>` 中的 id 就是这里的键。

const REGISTRY := {
	"rhythm_qte": "res://scenes/minigames/rhythm_qte.tscn",
}


static func get_scene(id: String) -> PackedScene:
	if not REGISTRY.has(id):
		push_warning("[Minigame] 未注册的小游戏 id: %s" % id)
		return null
	var path := String(REGISTRY[id])
	if not ResourceLoader.exists(path):
		push_warning("[Minigame] 场景文件不存在: %s" % path)
		return null
	return load(path) as PackedScene


static func has(id: String) -> bool:
	return REGISTRY.has(id)


static func list_ids() -> Array:
	return REGISTRY.keys()
