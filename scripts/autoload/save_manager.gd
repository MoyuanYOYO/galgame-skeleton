extends Node

## 存档管理器（Autoload）
##
## 纯存储层：只负责把 main.gd 组装好的 payload 写进 user://saves/*.json，
## 以及读回来。它不认识 ScriptRunner / Stage / GameManager，
## 因此换任何数据结构都不用改这里。
##
## 槽位约定：0 = 自动存档，1..SLOT_COUNT = 手动存档槽。

signal slot_written(slot: int)
signal slot_read(slot: int)
signal slot_deleted(slot: int)

const SAVE_DIR := "user://saves"
const SLOT_COUNT := 6
const AUTO_SLOT := 0
const SAVE_VERSION := 1


func _ready() -> void:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)


func slot_path(slot: int) -> String:
	if slot == AUTO_SLOT:
		return "%s/auto.json" % SAVE_DIR
	return "%s/slot_%02d.json" % [SAVE_DIR, slot]


func write_slot(slot: int, payload: Dictionary) -> bool:
	var data := payload.duplicate(true)
	data["version"] = SAVE_VERSION
	data["slot"] = slot
	data["saved_at"] = Time.get_datetime_string_from_system(false, true)

	var file := FileAccess.open(slot_path(slot), FileAccess.WRITE)
	if file == null:
		push_warning("[Save] 无法写入存档槽 %d" % slot)
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	slot_written.emit(slot)
	return true


func read_slot(slot: int) -> Dictionary:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("[Save] 无法读取存档槽 %d" % slot)
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[Save] 存档槽 %d 数据损坏" % slot)
		return {}
	slot_read.emit(slot)
	return parsed


func slot_exists(slot: int) -> bool:
	return FileAccess.file_exists(slot_path(slot))


func delete_slot(slot: int) -> bool:
	if not slot_exists(slot):
		return false
	var err := DirAccess.remove_absolute(slot_path(slot))
	if err != OK:
		push_warning("[Save] 删除存档槽 %d 失败 (err=%d)" % [slot, err])
		return false
	# 缩略图跟着一起删，否则删掉存档后还留着一张孤儿图
	var thumb := thumb_path(slot)
	if FileAccess.file_exists(thumb):
		DirAccess.remove_absolute(thumb)
	slot_deleted.emit(slot)
	return true


# ---------------------------------------------------------------------------
# 缩略图
# ---------------------------------------------------------------------------

## 缩略图存成独立 PNG，不塞进存档 JSON ——
## 这样存档 JSON 保持可读、可手改，也不会因为图片膨胀到几百 KB。
func thumb_path(slot: int) -> String:
	if slot == AUTO_SLOT:
		return "%s/auto.png" % SAVE_DIR
	return "%s/slot_%02d.png" % [SAVE_DIR, slot]


func write_thumbnail(slot: int, image: Image) -> bool:
	if image == null:
		return false
	var err := image.save_png(thumb_path(slot))
	if err != OK:
		push_warning("[Save] 缩略图写入失败 slot=%d (err=%d)" % [slot, err])
		return false
	return true


func has_thumbnail(slot: int) -> bool:
	return FileAccess.file_exists(thumb_path(slot))


func get_thumbnail(slot: int) -> Texture2D:
	var path := thumb_path(slot)
	if not FileAccess.file_exists(path):
		return null
	var image := Image.load_from_file(path)
	if image == null:
		return null
	return ImageTexture.create_from_image(image)


## 轻量摘要，供存档界面列表使用（不解析整个存档）
func get_slot_info(slot: int) -> Dictionary:
	var data := read_slot(slot)
	if data.is_empty():
		return {
			"slot": slot,
			"empty": true,
			"saved_at": "",
			"chapter_title": "",
			"preview": "",
			"speaker": "",
			"play_time": 0.0,
			"has_thumb": false,
		}
	return {
		"slot": slot,
		"empty": false,
		"saved_at": String(data.get("saved_at", "")),
		"chapter_title": String(data.get("chapter_title", "")),
		"preview": String(data.get("preview", "")),
		"speaker": String(data.get("speaker", "")),
		"play_time": float(data.get("play_time", 0.0)),
		"has_thumb": has_thumbnail(slot),
	}


## 返回 [自动存档, 槽1, 槽2, ...] 的摘要列表
func list_slots() -> Array:
	var out: Array = [get_slot_info(AUTO_SLOT)]
	for i in range(1, SLOT_COUNT + 1):
		out.append(get_slot_info(i))
	return out


## 找出最近一次写入的槽位，没有则返回 -1
func newest_slot() -> int:
	var best_slot := -1
	var best_time := ""
	for info in list_slots():
		if bool(info["empty"]):
			continue
		var stamp := String(info["saved_at"])
		if stamp > best_time:
			best_time = stamp
			best_slot = int(info["slot"])
	return best_slot


static func format_play_time(seconds: float) -> String:
	var total := int(maxf(0.0, seconds))
	var hours := floori(float(total) / 3600.0)
	var minutes := floori(float(total % 3600) / 60.0)
	var secs := total % 60
	if hours > 0:
		return "%d:%02d:%02d" % [hours, minutes, secs]
	return "%02d:%02d" % [minutes, secs]
