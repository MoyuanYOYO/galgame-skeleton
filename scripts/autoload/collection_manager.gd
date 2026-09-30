extends Node

## 收藏品解锁管理器（Autoload）
##
## 管理 CG / 音乐的解锁状态，落盘到 user://collection.json。
## **独立于存档**：收集进度跨周目保留，这是 galgame 的惯例
## （玩家重开新游戏不该丢掉已看过的 CG）。
##
## 解锁来源有三处：
##   1. 剧本 `cg <id>` 指令 —— 展示 CG 并解锁
##   2. 剧本 `bgm <id>` 指令 —— AudioManager 播放时通知解锁
##   3. 剧本 `unlock <type> <id>` 指令 —— 手动解锁隐藏要素

signal unlocked(type: String, id: String, is_new: bool)
signal collection_changed()

const SAVE_PATH := "user://collection.json"
const SAVE_VERSION := 1

var _unlocked: Dictionary = {}


func _ready() -> void:
	load_data()


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

func is_unlocked(type: String, id: String) -> bool:
	if id.is_empty():
		return false
	var bucket: Dictionary = _unlocked.get(type, {})
	return bool(bucket.get(id, false))


func unlocked_count(type: String) -> int:
	var total := 0
	for item in CollectionRegistry.get_items(type):
		if is_unlocked(type, String((item as Dictionary).get("id", ""))):
			total += 1
	return total


func total_count(type: String) -> int:
	return CollectionRegistry.total_count(type)


func get_progress(type: String) -> Vector2i:
	return Vector2i(unlocked_count(type), total_count(type))


func get_unlocked_items(type: String) -> Array:
	var out: Array = []
	for item in CollectionRegistry.get_items(type):
		if is_unlocked(type, String((item as Dictionary).get("id", ""))):
			out.append(item)
	return out


# ---------------------------------------------------------------------------
# 解锁
# ---------------------------------------------------------------------------

## 返回 true 表示这是一次「新解锁」（可用于弹提示 / 播音效）
func unlock(type: String, id: String) -> bool:
	if id.is_empty() or not CollectionRegistry.has_item(type, id):
		return false
	if is_unlocked(type, id):
		return false

	var bucket: Dictionary = _unlocked.get(type, {})
	bucket[id] = true
	_unlocked[type] = bucket

	save_data()
	unlocked.emit(type, id, true)
	collection_changed.emit()
	return true


func unlock_many(type: String, ids: Array) -> int:
	var newly := 0
	var dirty := false
	for raw_id in ids:
		var id := String(raw_id)
		if id.is_empty() or not CollectionRegistry.has_item(type, id):
			continue
		if is_unlocked(type, id):
			continue
		var bucket: Dictionary = _unlocked.get(type, {})
		bucket[id] = true
		_unlocked[type] = bucket
		dirty = true
		newly += 1
		unlocked.emit(type, id, true)
	if dirty:
		save_data()
		collection_changed.emit()
	return newly


func reset_all() -> void:
	_unlocked.clear()
	save_data()
	collection_changed.emit()


# ---------------------------------------------------------------------------
# 持久化
# ---------------------------------------------------------------------------

func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for type in _unlocked.keys():
		out[String(type)] = (_unlocked[type] as Dictionary).duplicate()
	return out


func from_dict(data: Dictionary) -> void:
	_unlocked.clear()
	for type in data.keys():
		var src: Variant = data[type]
		if typeof(src) != TYPE_DICTIONARY:
			continue
		var bucket: Dictionary = {}
		for id in (src as Dictionary).keys():
			if bool((src as Dictionary)[id]):
				bucket[String(id)] = true
		if not bucket.is_empty():
			_unlocked[String(type)] = bucket
	collection_changed.emit()


func save_data() -> void:
	JsonUtil.save_json(SAVE_PATH, {
		"version": SAVE_VERSION,
		"unlocked": to_dict(),
	})


func load_data() -> void:
	_unlocked.clear()
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var raw: Variant = JsonUtil.load_json(SAVE_PATH)
	if typeof(raw) != TYPE_DICTIONARY:
		push_warning("[Collection] 收藏记录损坏，已重置")
		return
	var data: Dictionary = raw
	var src: Variant = data.get("unlocked", {})
	if typeof(src) == TYPE_DICTIONARY:
		from_dict(src)
