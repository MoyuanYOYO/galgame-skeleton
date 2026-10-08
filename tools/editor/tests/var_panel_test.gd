extends Node

## 变量页「单击选中 + 右侧引用侧边栏」验收
##
## 用户的要求：
##   · 点变量 = **选中**（不再直接跳转）
##   · 右侧侧边栏列出这个变量的读写位置，**每条可点着跳过去**
##   · 双击跳转不再需要（跳转由侧边栏承担）
##
## 要窗口：
##   godot --path . res://tools/editor/tests/var_panel_test.tscn

const EditorScene = preload("res://tools/editor/editor.tscn")
const VarIndex = preload("res://tools/editor/core/var_index.gd")

var _ed: Control
var _panel: Control
var _tmp := "user://__var_panel_test.gvs"
var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 变量页：单击选中 + 引用侧边栏 验收 ===")

	# 一个变量，1 处写、2 处读 —— 侧边栏要能把三处都列出来
	_write(_tmp, "\n".join([
		"label start",
		"flag met_alice",
		"if flag met_alice",
		"    narr 第一次。",
		"end",
		"if flag met_alice",
		"    narr 第二次。",
		"end",
		"flag lonely_flag",
		"ending e \"结局\"",
		"",
	]))

	_ed = EditorScene.instantiate()
	add_child(_ed)
	_ed.size = get_viewport().get_visible_rect().size
	await _wait(1.0)
	_ed._open(_tmp)
	await _wait(0.4)
	_ed.show_page("var")
	await _wait(0.6)

	_panel = _ed._pages.get("var")
	_ok(_panel != null, "变量页已创建")
	if _panel == null:
		_finish()
		return

	# 只扫临时文件 —— 不然断言就得依赖项目里真实剧本的内容，改一句台词就红
	_panel.rescan(PackedStringArray([_tmp]))
	await _wait(0.4)
	_ok(not _panel._data.is_empty(), "扫到了变量（%d 个名字）" % VarIndex.total(_panel._data))

	await _check_initial()
	await _check_select()
	await _check_switch()
	await _check_jump()

	# 截图要拍「变量页」—— 上面最后一步是跳转，画面还停在源码页
	_ed.show_page("var")
	await _wait(0.4)
	_panel.rescan(PackedStringArray([_tmp]))
	await _wait(0.3)
	var shot_row := _row_of("met_alice")
	shot_row.button_pressed = true
	shot_row.toggled.emit(true)
	await _wait(0.4)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://captures/editor_var_panel.png")
	print("  （截图已存 user://captures/editor_var_panel.png）")

	_ed.queue_free()
	await _wait(0.3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp))
	_finish()


## 一进来右侧不该是空的 —— 自动选中第一条，否则像是坏了
func _check_initial() -> void:
	print("-- 初始状态 --")
	_ok(not _panel._sel_name.is_empty(), "自动选中了第一条（%s）" % _panel._sel_name)
	_ok(_refs_count() > 0, "右侧已经列出引用（%d 条）" % _refs_count())
	_ok(_panel._refs_meta.text.contains("写") and _panel._refs_meta.text.contains("读"),
		"摘要里写了读写条数（%s）" % _panel._refs_meta.text)


## 点一行 = 选中，且**不跳页**
func _check_select() -> void:
	print("-- 单击选中 --")
	var row := _row_of("met_alice")
	_ok(row != null, "找得到 met_alice 那一行")
	if row == null:
		return
	var page_before: String = _ed._current_page
	_ok(row.toggle_mode, "变量行是「可选中」的（toggle）")
	row.button_pressed = true
	row.toggled.emit(true)
	await _wait(0.4)

	_ok(_panel._sel_name == "met_alice", "选中了 met_alice（实得「%s」）" % _panel._sel_name)
	_ok(_ed._current_page == page_before,
		"单击**不跳页**，还留在变量页（实得 %s）" % _ed._current_page)
	# 1 写 2 读 → 侧边栏该有 3 条
	var entry: Dictionary = (_panel._data["flag"] as Dictionary)["met_alice"]
	var want := (entry["writes"] as Array).size() + (entry["reads"] as Array).size()
	_ok(_refs_count() == want,
		"侧边栏列出全部 %d 处引用（实得 %d）" % [want, _refs_count()])
	_ok(_panel._refs_title.text.contains("met_alice"),
		"侧边栏标题带变量名（%s）" % _panel._refs_title.text)


## 点另一行 → 侧边栏整个换掉
func _check_switch() -> void:
	print("-- 换一个变量 --")
	var row := _row_of("lonely_flag")
	if row == null:
		_ok(false, "找得到 lonely_flag 那一行")
		return
	row.button_pressed = true
	row.toggled.emit(true)
	await _wait(0.4)
	_ok(_panel._sel_name == "lonely_flag", "选中换成 lonely_flag（实得「%s」）" % _panel._sel_name)
	# 只写不读 → 只有 1 条写
	_ok(_refs_count() == 1, "只写不读的变量只列 1 条（实得 %d）" % _refs_count())
	_ok(_panel._refs_meta.text.contains("只写不读"), "摘要点出了「只写不读」（%s）" % _panel._refs_meta.text)


## 点侧边栏里的一条 → 跳到那一行
func _check_jump() -> void:
	print("-- 点引用跳转 --")
	var row := _row_of("met_alice")
	row.button_pressed = true
	row.toggled.emit(true)
	await _wait(0.4)

	var btns := _ref_buttons()
	_ok(btns.size() >= 2, "侧边栏里有多条可点的引用（%d）" % btns.size())
	if btns.is_empty():
		return
	# 第二条（读）—— 它指向第 6 行
	var target: Button = btns[btns.size() - 1]
	var tip: String = target.tooltip_text
	# 期望的行号**从数据里取**，不写死 —— `if flag X` 记的是 if 那一行，
	# 不是块内正文那一行，写死了第一次就数错。
	var entry: Dictionary = (_panel._data["flag"] as Dictionary)["met_alice"]
	var write_line := int(((entry["writes"] as Array)[0] as Dictionary)["line"])
	var reads: Array = entry["reads"]
	var last_read := int((reads[reads.size() - 1] as Dictionary)["line"])

	btns[0].pressed.emit()
	await _wait(0.5)
	_ok(_ed._current_page == "script", "跳转会切到源码页（实得 %s）" % _ed._current_page)
	_ok(_ed.caret_line == write_line,
		"点第一条落在**写**它的那一行（第 %d 行，期望 %d）" % [_ed.caret_line, write_line])

	# 回到变量页，点最后一条（第二处读 → 第 7 行）。
	# ⚠️ 切回页面会触发 on_shown → rescan()（扫**全部**剧本），
	# 临时文件不在那个清单里，所以要再按测试文件扫一遍。
	_ed.show_page("var")
	await _wait(0.4)
	_panel.rescan(PackedStringArray([_tmp]))
	await _wait(0.3)
	_row_of("met_alice").button_pressed = true
	_row_of("met_alice").toggled.emit(true)
	await _wait(0.4)
	var btns2 := _ref_buttons()
	if btns2.size() >= 3:
		btns2[btns2.size() - 1].pressed.emit()
		await _wait(0.5)
		_ok(_ed.caret_line == last_read,
			"点最后一条落在最后那处**读**（第 %d 行，期望 %d）" % [_ed.caret_line, last_read])
	else:
		_ok(false, "侧边栏该有 3 条引用（实得 %d）" % btns2.size())
	_ok(not tip.is_empty(), "引用行的 tooltip 带完整信息")


# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------

## 左侧清单里名字对应的那一行按钮
func _row_of(name: String) -> Button:
	return _find_row(_panel._list, name)


func _find_row(node: Node, name: String) -> Button:
	for c in node.get_children():
		if c is Button and (c as Button).toggle_mode \
				and (c as Button).text.contains(name):
			return c as Button
		var r := _find_row(c, name)
		if r != null:
			return r
	return null


## 右侧侧边栏里可点的引用条数（跳过标题那种普通 Label）
func _refs_count() -> int:
	return _ref_buttons().size()


func _ref_buttons() -> Array:
	var out: Array = []
	for c in _panel._refs_list.get_children():
		if c is Button:
			out.append(c)
	return out


# ---------------------------------------------------------------------------

func _finish() -> void:
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
		return
	f.store_string(text)
	f.close()
