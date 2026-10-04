extends Node

## 外部改动同步 —— 端到端验收
##
## 验证用户最关心的那条链路：**AI（或别的编辑器）直接改了 .gvs，
## 工具界面要自动跟上**。
##
## 跑法（**要带窗口**，因为要实例化完整编辑器）：
##   godot --path . res://tools/editor/tests/sync_test.tscn
##
## 安全：会临时改写入口剧本，所以**原文先备份、结束前无条件还原**，
## 并且最后会断言「文件已还原」，避免测试中途失败把剧本留在改动状态。

const EditorScene = preload("res://tools/editor/editor.tscn")
const ScriptPaths = preload("res://scripts/core/script_paths.gd")

var _pass := 0
var _fail := 0
var _ed: Control
var _backup := ""
var _path := ""


func _ready() -> void:
	_path = ScriptPaths.entry()
	_backup = FileAccess.get_file_as_string(_path)
	if _backup.is_empty():
		print("拿不到 %s，无法测试" % _path)
		get_tree().quit(1)
		return

	print("=== 外部改动同步验收 ===")

	_ed = EditorScene.instantiate()
	add_child(_ed)
	_ed.size = get_viewport().get_visible_rect().size
	await _wait(1.0)

	_ok(_ed.doc != null and _ed.doc.path == _path,
		"编辑器打开了入口剧本（%s）" % _path.get_file())

	var before_lines: int = _ed.doc.line_count()
	var before_rev: int = _ed.doc.revision
	print("  初始 %d 行，revision=%d" % [before_lines, before_rev])

	# --- 模拟外部写入（就像 AI 直接改文件那样）---
	var marker := "# __外部改动同步测试__"
	_write(_path, _backup + "\n" + marker + "\n")
	print("  已写入外部改动，等待轮询…")
	await _wait(1.6)

	_ok(_ed.doc.line_count() == before_lines + 2,
		"外部改动被检测到并整体重载（%d → %d 行）" % [before_lines, _ed.doc.line_count()])
	_ok(_ed.doc.to_text().contains(marker), "新内容进入了文档")
	_ok(not _ed.doc.is_dirty(), "重载后不处于「待写盘」状态（无脏状态设计）")

	# --- 再改一次，确认可以连续同步 ---
	var marker2 := "# __第二次外部改动__"
	_write(_path, _backup + "\n" + marker + "\n" + marker2 + "\n")
	await _wait(1.6)
	_ok(_ed.doc.to_text().contains(marker2), "第二次外部改动同样被同步")

	# --- 还原 ---
	_write(_path, _backup)
	await _wait(1.6)
	_ok(_ed.doc.line_count() == before_lines,
		"还原后行数回到 %d（实得 %d）" % [before_lines, _ed.doc.line_count()])
	_ok(not _ed.doc.to_text().contains(marker), "文档里不再有测试标记")

	# 关键：文件本身必须干净 —— 测试失败也不能把剧本留在改动状态
	var on_disk := FileAccess.get_file_as_string(_path)
	_ok(on_disk == _backup, "磁盘上的剧本已完整还原（逐字节相同）")

	print("")
	if _fail == 0:
		print("=== ALL OK  %d 项 ===" % _pass)
		get_tree().quit(0)
	else:
		print("=== FAILED  %d 通过 / %d 失败 ===" % [_pass, _fail])
		get_tree().quit(1)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  OK    %s" % msg)
	else:
		_fail += 1
		print("  FAIL  %s" % msg)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("  写不进 %s" % path)
		return
	f.store_string(text)
	f.close()
