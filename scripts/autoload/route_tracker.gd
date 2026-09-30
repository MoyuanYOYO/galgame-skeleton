extends Node

## 路线记录（Autoload）
##
## 记两件事：
##   · 玩家在每个选项点选了什么 —— 路线图用
##   · 走过哪些章节 —— 章节选择用
##
## 存 user://route.json，**和存档分离**：路线是「这台机器上的通关记录」，
## 读旧档不该把它抹掉（和已读记录同一个理由）。

const DATA_PATH := "user://route.json"
const DATA_VERSION := 1

## "文件:标签" -> 选项下标
var _picks: Dictionary = {}
## 章节 id -> true
var _visited: Dictionary = {}
var _dirty := false


func _ready() -> void:
	_load()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		save_now()


# ---------------------------------------------------------------------------
# 记录
# ---------------------------------------------------------------------------

func record_pick(file: String, label: String, option_index: int) -> void:
	if label.is_empty():
		return
	var key := pick_key(file, label)
	if int(_picks.get(key, -1)) == option_index:
		return
	_picks[key] = option_index
	_dirty = true


func record_chapter(chapter_id: String) -> void:
	if chapter_id.is_empty() or _visited.has(chapter_id):
		return
	_visited[chapter_id] = true
	_dirty = true


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

## 选项点的唯一键。用「文件 + 标签」而不是指令下标 ——
## 下标会随剧本改动漂移，标签是作者显式写的锚点。
static func pick_key(file: String, label: String) -> String:
	return "%s:%s" % [file.get_file(), label]


func get_pick(file: String, label: String) -> int:
	return int(_picks.get(pick_key(file, label), -1))


func has_visited(chapter_id: String) -> bool:
	return _visited.has(chapter_id)


## 某章是否可选：没声明 unlock_flag 的（通常是第一章）永远可选，
## 声明了的要等那个 flag 被置位。
func is_chapter_available(chapter: Dictionary) -> bool:
	var flag := String(chapter.get("unlock_flag", ""))
	if flag.is_empty():
		return true
	return GameManager.get_flag(flag)


func pick_count() -> int:
	return _picks.size()


func visited_count() -> int:
	return _visited.size()


func to_dict() -> Dictionary:
	return {"picks": _picks.duplicate(true), "visited": _visited.keys()}


func from_dict(data: Dictionary) -> void:
	_picks.clear()
	_visited.clear()
	var picks: Variant = data.get("picks", {})
	if typeof(picks) == TYPE_DICTIONARY:
		for key in (picks as Dictionary).keys():
			_picks[String(key)] = int((picks as Dictionary)[key])
	for item in data.get("visited", []):
		_visited[String(item)] = true


func save_now() -> void:
	if not _dirty:
		return
	_dirty = false
	JsonUtil.save_json(DATA_PATH, {
		"version": DATA_VERSION,
		"picks": _picks,
		"visited": _visited.keys(),
	})


func clear() -> void:
	_picks.clear()
	_visited.clear()
	_dirty = true
	save_now()


func _load() -> void:
	# 先判存在 —— JsonUtil 读不到文件会打警告，首次运行时不该有噪音
	if not FileAccess.file_exists(DATA_PATH):
		return
	var raw: Variant = JsonUtil.load_json(DATA_PATH)
	if typeof(raw) != TYPE_DICTIONARY:
		return
	from_dict(raw as Dictionary)
