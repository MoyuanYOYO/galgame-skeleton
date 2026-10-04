extends Node

## 编辑器纯净性验收 —— 跑完整流程后，剧本必须**一字未动**
##
## 这条守着一个真实踩过的坑：编辑器在「切换页面 / 定位光标 / 跑预览」的
## 过程中，曾经把两行模板文本插进了剧本开头，把原有注释挤掉了。
## 那类损坏不报错、不影响解析、界面也看不出来 —— **只有比对文件才发现得了**。
## 所以这里就比对文件：跑一遍全流程，然后逐文件比 SHA256。
##
## 跑法（要带窗口，因为要实例化完整编辑器）：
##   godot --path . res://tools/editor/tests/purity_test.tscn

const EditorScene = preload("res://tools/editor/editor.tscn")
const ScriptPaths = preload("res://scripts/core/script_paths.gd")

var _before: Dictionary = {}
var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 编辑器纯净性验收 ===")

	var files := _collect()
	_ok(files.size() >= 3, "采集到 %d 个受保护文件" % files.size())
	for f in files:
		_before[f] = FileAccess.get_sha256(f)

	var ed: Control = EditorScene.instantiate()
	add_child(ed)
	ed.size = get_viewport().get_visible_rect().size
	await _wait(1.0)

	# 1. 走一遍所有页面（页面是懒加载的，这样能把每个面板都构建一遍）
	for page in ["script", "table", "graph", "asset", "i18n"]:
		ed.show_page(page)
		await _wait(0.35)

	# 2. 定位光标（表格与演出面板会据此建控件）
	ed.goto_source(47)
	await _wait(0.35)
	ed.show_page("table")
	await _wait(0.35)
	ed.show_page("stage")
	await _wait(0.35)

	# 3. 跑一段预览（驱动 Stage / ScriptRunner，会读素材、跑指令）
	ed._preview_panel.run_from(15)
	await _wait(1.5)

	# 4. 给自动保存留出触发窗口（如果意外产生了脏状态，这里会写盘）
	await _wait(1.5)

	ed.queue_free()
	await _wait(0.6)

	# 5. 逐文件比对
	var changed: Array = []
	for f in _before.keys():
		var now := FileAccess.get_sha256(String(f))
		if now != String(_before[f]):
			changed.append(String(f))
	_ok(changed.is_empty(),
		"全流程后没有文件被改动%s" % ("" if changed.is_empty() else "（变了：%s）" % ", ".join(changed)))

	# 单独再确认一次入口剧本的行数（多一层可读的断言）
	var entry := ScriptPaths.entry()
	var text := FileAccess.get_file_as_string(entry)
	_ok(not text.contains("anim alice speed=0.5\nshow alice"),
		"剧本开头没有被插入模板文本")
	_ok(text.begins_with("# ==="), "剧本第一行仍是原本的注释")

	print("")
	if _fail == 0:
		print("=== ALL OK  %d 项 ===" % _pass)
		get_tree().quit(0)
	else:
		print("=== FAILED  %d 通过 / %d 失败 ===" % _pass)
		get_tree().quit(1)


## 受保护的文件：全部剧本 + data/ 下的配置
func _collect() -> PackedStringArray:
	var out := PackedStringArray()
	for p in _walk("res://data"):
		var s := String(p)
		if s.ends_with(".gvs") or s.ends_with(".json"):
			out.append(s)
	return out


func _walk(dir_path: String, out: Array = []) -> Array:
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	for f in d.get_files():
		out.append(dir_path + "/" + String(f))
	for sub in d.get_directories():
		_walk(dir_path + "/" + String(sub), out)
	return out


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  OK    %s" % msg)
	else:
		_fail += 1
		print("  FAIL  %s" % msg)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
