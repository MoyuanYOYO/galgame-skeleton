extends Node

## 已读文本追踪（Autoload）
##
## 记录玩家看过的每一句台词，供「跳过已读」使用 —— 这是 galgame 的标配行为：
## 跳过键只快进看过的内容，遇到新剧情就停下来。
##
## 键用**文本内容的 hash**，不用「文件 + 行号」：
##   · 好处：改剧本、插删行都不会让已读记录错位
##   · 代价：两处一模一样的台词会被当成同一处（可接受）
##
## 数据存在 user:// 下，和存档分离 —— 已读是「玩家在这台机器上的记忆」，
## 不该跟着某个存档槽走。

const DATA_PATH := "user://read_text.json"
const DATA_VERSION := 1

var _seen: Dictionary = {}
var _dirty := false


func _ready() -> void:
	_load()


func _notification(what: int) -> void:
	# 关窗时兜底落盘，避免最后几句已读丢失
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		save_now()


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

func is_read(text: String) -> bool:
	if text.is_empty():
		return false
	return _seen.has(_key(text))


func read_count() -> int:
	return _seen.size()


# ---------------------------------------------------------------------------
# 写入
# ---------------------------------------------------------------------------

func mark_read(text: String) -> void:
	if text.is_empty():
		return
	var key := _key(text)
	if _seen.has(key):
		return
	_seen[key] = true
	_dirty = true


## 落盘。正常流程里由自动存档顺带调用，不必每句话都写文件。
func save_now() -> void:
	if not _dirty:
		return
	_dirty = false
	var hashes: Array = _seen.keys()
	var file := FileAccess.open(DATA_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[ReadTracker] 无法写入 %s" % DATA_PATH)
		return
	file.store_string(JSON.stringify({"version": DATA_VERSION, "hashes": hashes}))
	file.close()


func clear() -> void:
	_seen.clear()
	_dirty = true
	save_now()


func to_dict() -> Dictionary:
	return {"hashes": _seen.keys()}


func from_dict(data: Dictionary) -> void:
	_seen.clear()
	for item in data.get("hashes", []):
		_seen[str(item)] = true
	_dirty = true


# ---------------------------------------------------------------------------
# 内部
# ---------------------------------------------------------------------------

func _load() -> void:
	_seen.clear()
	if not FileAccess.file_exists(DATA_PATH):
		return
	var file := FileAccess.open(DATA_PATH, FileAccess.READ)
	if file == null:
		return
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[ReadTracker] 已读数据损坏，忽略")
		return
	for item in (parsed as Dictionary).get("hashes", []):
		_seen[str(item)] = true


static func _key(text: String) -> String:
	return str(text.hash())
