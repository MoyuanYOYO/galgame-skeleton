class_name CollectionRegistry
extends RefCounted

## 收藏品注册表
##
## 从 data/collection/*.json 读取「可收集项」的定义（CG、音乐……）。
## 只负责「有哪些东西」，不关心「解锁了没有」——后者归 CollectionManager。
##
## 新增一类收藏品：加一个 json 文件 + 在 SOURCES 里加一行。

const SOURCES := {
	"cg": "res://data/collection/cg.json",
	"music": "res://data/collection/music.json",
	"video": "res://data/collection/video.json",
	"endings": "res://data/collection/endings.json",
}

static var _cache: Dictionary = {}


static func get_items(type: String) -> Array:
	_ensure(type)
	var items: Array = _cache.get(type, [])
	return items


static func get_item(type: String, id: String) -> Dictionary:
	for item in get_items(type):
		if String((item as Dictionary).get("id", "")) == id:
			return item
	return {}


static func has_item(type: String, id: String) -> bool:
	return not get_item(type, id).is_empty()


static func get_ids(type: String) -> PackedStringArray:
	var out := PackedStringArray()
	for item in get_items(type):
		out.append(String((item as Dictionary).get("id", "")))
	return out


static func total_count(type: String) -> int:
	return get_items(type).size()


## 取条目的显示贴图：优先用注册表里声明的 image 路径，
## 找不到就退回按 id 生成的占位图（骨架阶段没有美术素材时全靠它）
static func resolve_texture(item: Dictionary) -> Texture2D:
	var path := String(item.get("image", ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		var texture := load(path) as Texture2D
		if texture != null:
			return texture
	return PlaceholderAssets.get_cg(String(item.get("id", "")))


static func types() -> Array:
	return SOURCES.keys()


static func clear_cache() -> void:
	_cache.clear()


static func _ensure(type: String) -> void:
	if _cache.has(type):
		return
	var items: Array = []
	var path := String(SOURCES.get(type, ""))
	if path.is_empty():
		push_warning("[CollectionRegistry] 未知收藏品类型: %s" % type)
		_cache[type] = items
		return

	var raw: Variant = JsonUtil.load_json(path)
	if typeof(raw) == TYPE_DICTIONARY:
		var list: Variant = (raw as Dictionary).get("items", [])
		if typeof(list) == TYPE_ARRAY:
			for entry in (list as Array):
				if typeof(entry) != TYPE_DICTIONARY:
					continue
				var item: Dictionary = entry
				if String(item.get("id", "")).is_empty():
					push_warning("[CollectionRegistry] %s 里有条目缺少 id" % path)
					continue
				items.append(item)
	else:
		push_warning("[CollectionRegistry] %s 格式错误，应为含 items 数组的对象" % path)

	_cache[type] = items
