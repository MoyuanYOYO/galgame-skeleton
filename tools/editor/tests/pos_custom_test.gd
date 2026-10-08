extends Node

## 立绘位置「自定义」下拉的端到端验收
##
## 用户的需求原话：「既然角色入场支持自定义坐标，那更改一下编辑工具的交互逻辑，
## 位置多一个自定义选项，在选中自定义之后才显示 xy 的参数」。
##
## 这个测试走**真实控件**（点下拉项 → 写回剧本 → 行重建 → 再看控件），
## 而不是直接调内部函数 —— 「内部函数对、映射错」那一类只有真点才抓得到
## （`table_ux_test` 在菜单映射上漏过一次）。
##
## 要窗口：
##   godot --path . res://tools/editor/tests/pos_custom_test.tscn

const EditorScene = preload("res://tools/editor/editor.tscn")
const GvsParser = preload("res://scripts/core/gvs_parser.gd")
const OpSpec = preload("res://tools/editor/core/op_spec.gd")

var _ed: Control
var _tbl: Control
var _tmp := "user://__pos_custom_test.gvs"
var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 立绘位置「自定义」下拉 验收 ===")

	_write(_tmp, "\n".join([
		"label start",
		"show alice at=left fade=0.5",
		"show bob x=680 y=1130 fade=0.5",
		"move bob at=right fade=0.6",
		"",
	]))

	_ed = EditorScene.instantiate()
	add_child(_ed)
	_ed.size = get_viewport().get_visible_rect().size
	await _wait(1.0)
	_ed._open(_tmp)
	await _wait(0.5)
	_ed.show_page("table")
	await _wait(0.6)

	_tbl = _ed._pages.get("table")
	_ok(_tbl != null, "剧本块面板已创建")
	if _tbl == null:
		_finish()
		return

	await _check_slot_mode()
	await _check_switch_to_custom()
	await _check_switch_back()

	# 顺手出一张图给用户看
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://captures/editor_pos_custom.png")
	print("  （截图已存 user://captures/editor_pos_custom.png）")

	_ed.queue_free()
	await _wait(0.3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp))
	_finish()


## 槽位模式下：位置下拉有「自定义」项，但**没有** x / y 控件
func _check_slot_mode() -> void:
	print("-- 槽位模式 --")
	var no := _find_line("show alice")
	_ok(no > 0, "找得到 show 那一行")
	var at := _option_of(no, "at")
	_ok(at != null, "行里有「位置」下拉")
	if at == null:
		return
	_ok(_option_texts(at).has(OpSpec.CUSTOM_POS),
		"下拉里有「%s」项（实得 %s）" % [OpSpec.CUSTOM_POS, str(_option_texts(at))])
	_ok(_option_texts(at).has("left"), "原本的槽位项还在")
	_ok(_num_of(no, "x") == null and _num_of(no, "y") == null,
		"选槽位时不显示 x / y 输入框")
	_ok(_num_of(no, "scale") != null, "缩放与位置无关，一直显示")


## 点「自定义」→ 写坐标、删掉 at=、行重建后出现 x / y
func _check_switch_to_custom() -> void:
	print("-- 切到自定义 --")
	var no := _find_line("show alice")
	var at := _option_of(no, "at")
	var idx := _index_of_option(at, OpSpec.CUSTOM_POS)
	_ok(idx >= 0, "找得到「自定义」那一项的下标")
	# 走真实信号：`item_selected` 就是用户点下拉时发的
	at.item_selected.emit(idx)
	await _wait(0.4)

	var raw: String = _ed.doc.text_at(no)
	_ok(not raw.contains("at="), "「自定义」不写进剧本（槽位已清掉）：%s" % raw)
	_ok(raw.contains("x=") and raw.contains("y="), "写入了坐标：%s" % raw)
	# 语义校验：解析器真的按坐标摆位
	var cmd := _parse_op("show")
	_ok(cmd.has("x") and cmd.has("y") and String(cmd.get("at", "")) != "left",
		"解析器读到坐标、槽位不再是 left（at=「%s」）" % cmd.get("at", ""))

	_ok(_num_of(no, "x") != null and _num_of(no, "y") != null,
		"行重建后出现了 x / y 输入框")
	var at2 := _option_of(no, "at")
	_ok(at2 != null and _option_texts(at2)[at2.selected] == OpSpec.CUSTOM_POS,
		"下拉停在「自定义」（实得 %s）" % (_option_texts(at2)[at2.selected] if at2 != null else "无"))


## 再选回一个真实槽位 → 坐标必须被清掉
## （不清的话坐标会盖过槽位，表现是「选了 right 还停在原地」）
func _check_switch_back() -> void:
	print("-- 切回槽位 --")
	var no := _find_line("show alice")
	var at := _option_of(no, "at")
	var idx := _index_of_option(at, "center")
	_ok(idx >= 0, "找得到 center 项")
	at.item_selected.emit(idx)
	await _wait(0.4)

	var raw: String = _ed.doc.text_at(no)
	_ok(raw.contains("at=center"), "写回了槽位：%s" % raw)
	_ok(not raw.contains("x=") and not raw.contains("y="),
		"坐标被清掉了（否则会盖过槽位）：%s" % raw)
	_ok(_num_of(no, "x") == null, "x / y 输入框又收起来了")


# ---------------------------------------------------------------------------
# 辅助：按字段 key 找控件
#
# ⚠️ 行里的控件**不能按位置找** —— 个数会随条件显示变化。
# `TablePanel._directive_row` 给每个控件盖了 `field_key` meta，按它找。
# ---------------------------------------------------------------------------

func _row(no: int) -> Control:
	return _tbl._row_by_no.get(no, null) as Control


func _control_of(no: int, key: String) -> Control:
	var row := _row(no)
	if row == null:
		return null
	return _find_meta(row, key)


func _find_meta(node: Node, key: String) -> Control:
	if node.has_meta("field_key") and String(node.get_meta("field_key")) == key:
		return node as Control
	for c in node.get_children():
		var r := _find_meta(c, key)
		if r != null:
			return r
	return null


func _option_of(no: int, key: String) -> OptionButton:
	var c := _control_of(no, key)
	if c is OptionButton:
		return c as OptionButton
	# 枚举控件外面可能套了一层 box（`_field_control` 的实现细节）
	return _find_option(c) if c != null else null


func _find_option(node: Node) -> OptionButton:
	if node == null:
		return null
	if node is OptionButton:
		return node as OptionButton
	for c in node.get_children():
		var r := _find_option(c)
		if r != null:
			return r
	return null


func _num_of(no: int, key: String) -> Control:
	var c := _control_of(no, key)
	if c == null:
		return null
	if c is LineEdit:
		return c
	return _find_line_edit(c)


func _find_line_edit(node: Node) -> LineEdit:
	if node == null:
		return null
	if node is LineEdit:
		return node as LineEdit
	for c in node.get_children():
		var r := _find_line_edit(c)
		if r != null:
			return r
	return null


static func _option_texts(opt: OptionButton) -> Array:
	var out: Array = []
	if opt == null:
		return out
	for i in opt.item_count:
		out.append(opt.get_item_text(i))
	return out


static func _index_of_option(opt: OptionButton, text: String) -> int:
	if opt == null:
		return -1
	for i in opt.item_count:
		if opt.get_item_text(i) == text:
			return i
	return -1


func _find_line(prefix: String) -> int:
	for i in range(1, _ed.doc.line_count() + 1):
		if _ed.doc.text_at(i).strip_edges().begins_with(prefix):
			return i
	return -1


func _parse_op(op: String) -> Dictionary:
	var r := GvsParser.parse(_ed.doc.to_text(), "t.gvs")
	for c in (r["commands"] as Array):
		var cmd: Dictionary = c
		if String(cmd.get("op", "")) == op:
			return cmd
	return {}


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
