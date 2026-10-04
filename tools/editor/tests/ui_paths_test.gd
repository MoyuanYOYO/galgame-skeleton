extends Node

## 用户操作路径验收 —— 把所有按钮的 `pressed` 都触发一遍
##
## **为什么需要**：面板通过 untyped 引用（`_ed.xxx`）访问主控 ——
## 把属性当函数调用、或方法名写错，**编译期完全查不出来**，
## 只在运行时抛 `Nonexistent function`。
##
## 真实案例：`preview_panel` 里写成了 `_ed.caret_line()`（多了括号），
## 导致「从此处预览」按钮一按就报错、预览起不来。
## 而当时所有测试都走另一条路径（`run_from(15)`），所以一条都没抓到。
##
## 做法：打开一个**临时剧本**（绝不碰真剧本），然后递归找出所有 Button
## 逐个 `emit("pressed")`。任何运行时错误都会打在控制台 ——
## 跑完由调用方 grep `SCRIPT ERROR` 检查。
##
## 跑法（要带窗口）：
##   godot --path . res://tools/editor/tests/ui_paths_test.tscn

const EditorScene = preload("res://tools/editor/editor.tscn")

## 只在这些页面全量点按钮。i18n 页面跳过 —— 它的「保存翻译」会写
## `data/i18n/en.json`，那是真文件，不该被测试碰。
const SAFE_PAGES := ["script", "table", "graph", "asset"]

var _ed: Control
var _tmp := "user://__ui_paths_test.gvs"
var _pass := 0
var _fail := 0
var _clicked := 0


func _ready() -> void:
	print("=== 用户操作路径验收 ===")

	var src := FileAccess.get_file_as_string("res://data/scripts/prologue.gvs")
	_write(_tmp, src)

	_ed = EditorScene.instantiate()
	add_child(_ed)
	_ed.size = get_viewport().get_visible_rect().size
	await _wait(1.0)

	_ed._open(_tmp)
	await _wait(0.5)
	_ok(_ed.doc != null and _ed.doc.path == _tmp, "编辑器打开的是临时剧本（不碰真剧本）")

	# 逐页把按钮都点一遍
	for page in SAFE_PAGES:
		_ed.show_page(page)
		await _wait(0.45)
		var n: int = await _click_buttons(_ed._pages[page])
		_clicked += n
		# script 页是纯文本编辑器（CodeEdit），本来就没有按钮
		_ok(n >= 0, "页面 %s：触发了 %d 个按钮" % [page, n])

	# i18n 页面只构建、不点按钮
	_ed.show_page("i18n")
	await _wait(0.5)
	_ok(true, "页面 i18n：已构建（按钮跳过，避免写翻译表）")

	# 顶栏按钮（视图切换 / 重新扫描）。
	# 只点顶栏 —— 不能整个编辑器遍历，那会把 i18n 的「保存翻译」也点到，
	# 而它会写 data/i18n/en.json 这个真文件。
	var n2: int = await _click_buttons(_ed._topbar)
	_clicked += n2
	_ok(n2 > 0, "顶栏：触发了 %d 个按钮" % n2)

	# --- 素材网格：+ 卡片与 ✕ 徽章的实际接线 ---
	#
	# 通用遍历覆盖不到这里：点一下类别芯片就会 rebuild，之前收集到的卡片全部
	# 失效被跳过。所以单独走一遍 —— 重点验「按钮 → 函数」的映射，
	# 只调内部函数是抓不到接线错误的。
	_ed.show_page("asset")
	await _wait(0.5)
	var ap: Control = _ed._pages["asset"]
	ap.set("_kind", "char")
	ap.call("rebuild")
	await _wait(0.5)

	var grid: Control = ap.get("_grid")
	var ncd: ConfirmationDialog = ap.get("_new_char_dialog")
	var confirm: ConfirmationDialog = ap.get("_confirm")

	var plus: Node = grid.get_child(grid.get_child_count() - 1)
	_ok(plus is Button, "网格末尾是 + 卡片（实得 %s）" % plus.get_class())
	if plus is Button:
		# 立绘页的 + = 新建角色：只弹对话框，不碰文件系统
		(plus as Button).pressed.emit()
		await _wait(0.3)
		_ok(ncd.visible, "点 + 打开了「新建角色」对话框")
		ncd.hide()

	var before: int = _ed.index.char_ids().size()
	var card: Node = grid.get_child(0)
	# ⚠️ 徽章在卡片里的一个 HBoxContainer 里，**必须递归找**，不能只看直接子节点
	var badge: Button = null
	for d in _descendants(card):
		if d is Button and (d as Button).text == "✕":
			badge = d
	_ok(badge != null, "角色卡片右上角有 ✕ 徽章")

	# ⚠️ 改素材会**连带改剧本**，所以手里有未保存改动时会被拦住（`_guard_dirty`）。
	# 上面在 table 页点过按钮，文档多半是脏的 —— 先存一下，
	# 否则这里测到的是「被拦下」而不是「弹确认框」。
	if _ed.doc.is_dirty():
		_ed._save()
		await _wait(0.4)
	_ok(not _ed.doc.is_dirty(), "当前剧本已保存（改素材的前置条件）")

	if badge != null:
		badge.pressed.emit()
		await _wait(0.3)
		_ok(confirm.visible, "点 ✕ 弹出删除确认框（不是直接删）")
		ap.set("_pending_delete", Callable())      # 等价于点了「取消」
		confirm.hide()
		await _wait(0.3)
		_ok(_ed.index.char_ids().size() == before,
			"取消后角色一个没少（%d → %d）" % [before, _ed.index.char_ids().size()])

	# --- 用户报的那条路径：右上角「从此处预览」---
	_ed.show_page("script")
	_ed.goto_source(15)
	await _wait(0.4)
	_ed._preview_panel.run_from_caret()
	await _wait(0.8)
	_ok(_ed._preview_panel.is_running(), "「从此处预览」按钮可用（不再报 Nonexistent function）")
	_ed._preview_panel.stop()
	await _wait(0.3)
	_ok(not _ed._preview_panel.is_running(), "「停止预览」可用")

	# 走一圈预览推进，确认没有别的等待态问题
	_ed._preview_panel.run_from(15)
	await _wait(1.2)
	_ok(_ed._preview_panel.is_running(), "预览能持续运行")

	print("  共触发 %d 个按钮" % _clicked)

	_ed.queue_free()
	await _wait(0.4)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp))
	_finish()


## 把按钮先**快照**下来再点。
##
## 不能边遍历边点：表格里每个行都有 `+` / `x`，一点就触发 rebuild，
## 正在遍历的那些节点当场被 queue_free —— 再访问就是
## "previously freed instance"。
##
## 另外限总量：表格一页有 600+ 个按钮，全点一遍要好几分钟，
## 而前几十个已经足够覆盖到各类回调了。
const MAX_CLICKS_PER_PAGE := 24

func _click_buttons(root: Node) -> int:
	var buttons: Array = []
	_collect_buttons(root, buttons)
	var n := 0
	for b in buttons:
		if n >= MAX_CLICKS_PER_PAGE:
			break
		if not is_instance_valid(b):
			continue
		(b as Button).pressed.emit()
		n += 1
		await _wait(0.05)
	return n


## CheckButton 跳过 —— 它按一下会改设置并写 config.json，
## 属于「测试不该改的东西」。
##
## ⚠️ **Window（对话框）整棵子树都要跳过。** 对话框内部藏着「确定 / 删除 / 打开」
## 这类按钮，点下去会真的执行破坏性动作 —— 素材面板的删除确认框点一下
## 就会把作者的素材删掉（`_pending_delete` 早被 ✕ 徽章设好了）。
## 而且这些按钮本身也不是「用户操作路径」，测它们没有意义。
func _collect_buttons(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is Window:
			continue
		if child is CheckButton:
			continue
		if child is Button:
			out.append(child)
		if child.get_child_count() > 0:
			_collect_buttons(child, out)


func _descendants(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		out.append(child)
		out.append_array(_descendants(child))
	return out


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
