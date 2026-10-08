extends Node

## 对白表格「已报 bug」的回归验收
##
## 用户报的两条：
##   1. 在对白表格里添加行时，屏幕会把那一行**置顶**（看起来像跳到了别处），
##      而且加出来的文字跟上下文对不上
##   2. 「置旗标」的开关点一下报 `Invalid call. Nonexistent 'String' constructor.`
##
## 两条的根因都不在「按钮连错回调」上，而是**位置 / 值的语义搞错了**，
## 所以断言必须落到「剧本原文变成什么」「视图落在哪一行」「滚动有没有乱动」，
## 光断言「函数被调到了」是抓不到的。
##
## 另外跑完要 grep 一遍控制台有没有 `SCRIPT ERROR` —— 第 2 条的报错来自
## Godot 的构造函数校验，**不会**让断言失败（值没写进去，界面照样重绘），
## 只有把错误日志也纳入判定才守得住。
##
## 跑法（要带窗口）：
##   godot --path . res://tools/editor/tests/table_bugs_test.tscn

const EditorScene = preload("res://tools/editor/editor.tscn")
const GvsParser = preload("res://scripts/core/gvs_parser.gd")
const OpSpec = preload("res://tools/editor/core/op_spec.gd")

var _ed: Control
var _tbl: Control
var _tmp := "user://__table_bugs.gvs"
var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 对白表格 已报 bug 回归 ===")

	_write(_tmp, _make_text())
	_ed = EditorScene.instantiate()
	add_child(_ed)
	_ed.size = get_viewport().get_visible_rect().size
	await _wait(1.0)
	_ed._open(_tmp)
	await _wait(0.4)
	_ed.show_page("table")
	await _wait(0.6)
	_tbl = _ed._pages.get("table")
	_ok(_tbl != null, "对白表格面板已创建")
	if _tbl == null:
		_finish()
		return

	await _test_flag_toggle()
	await _test_insert_position()
	await _test_insert_keeps_view()
	await _test_insert_speaker()
	await _test_insert_directive_defaults()
	await _test_insert_with_hidden_structure()
	await _test_toolbar_insert_anchor()
	await _test_insert_with_filter()
	await _test_state_bar_follows_current()
	await _test_preview_follows_edit()
	await _test_preview_follows_field_edit()
	await _test_asset_dropdown_first_item()

	_ed.queue_free()
	await _wait(0.3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp))
	_finish()


# ---------------------------------------------------------------------------
# bug 2：置旗标的开关
# ---------------------------------------------------------------------------

func _test_flag_toggle() -> void:
	_sec("bug 2 · 置旗标开关")

	var no := _find_line("flag talked_to_alice")
	_ok(no > 0, "找得到 `flag talked_to_alice`（第 %d 行）" % no)
	if no <= 0:
		return

	var chk := _check_of(no)
	_ok(chk != null, "置旗标那一行有开关控件")
	if chk == null:
		return
	_ok(chk.button_pressed, "没写值时开关默认打开（与解析器默认 true 一致）")

	# 关一下 —— 这就是用户报的「点击报错」那一下
	_click_check(chk, false)
	await _wait(0.35)
	_ok(_ed.doc.text_at(no) == "flag talked_to_alice false",
		"关掉后写回 `false`（实得 %s）" % _ed.doc.text_at(no))
	_ok(not _flag_value("talked_to_alice"), "解析器读到的值也是 false")

	# 再打开
	var chk2 := _check_of(no)
	if chk2 != null:
		_click_check(chk2, true)
		await _wait(0.35)
	_ok(_ed.doc.text_at(no) == "flag talked_to_alice true",
		"打开后写回 `true`（实得 %s）" % _ed.doc.text_at(no))
	_ok(_flag_value("talked_to_alice"), "解析器读到的值也是 true")

	# 旗标名里含有值字面量时，替换必须按「词」定位，不能按子串
	var no2 := _find_line("flag true_flag")
	_ok(no2 > 0, "找得到 `flag true_flag true`（第 %d 行）" % no2)
	if no2 > 0:
		var chk3 := _check_of(no2)
		if chk3 != null:
			_click_check(chk3, false)
			await _wait(0.35)
		_ok(_ed.doc.text_at(no2) == "flag true_flag false",
			"旗标名含 \"true\" 时也改对了（实得 %s）" % _ed.doc.text_at(no2))


# ---------------------------------------------------------------------------
# bug 1：添加行
# ---------------------------------------------------------------------------

func _test_insert_position() -> void:
	_sec("bug 1 · 点行内 [+] 插入的位置")

	var no := _find_line("alice: 第 40 句。")
	_ok(no > 0, "找得到第 40 句（第 %d 行）" % no)
	if no <= 0:
		return
	_scroll_top(no)
	await _wait(0.3)

	var n0: int = _ed.doc.line_count()
	await _row_insert(no)
	_ok(_ed.doc.line_count() == n0 + 1, "行数 +1（实得 %d）" % _ed.doc.line_count())
	_ok(_ed.doc.text_at(no + 1).contains(": 新台词"),
		"新行紧跟在被点的那一行之后（实得 %s）" % _ed.doc.text_at(no + 1))
	_ok(_ed.caret_line == no + 1,
		"主控的当前行跟到新行（实得 %d，期望 %d）" % [_ed.caret_line, no + 1])
	_ok(_tbl._current_no == no + 1, "表格自己的当前行也是新行")
	_ok(_row_visible(no + 1), "新行在视口里（scroll=%d，新行 y=%d）" % [
		_tbl._scroll.scroll_vertical, _row_y(no + 1)])


## 用户报的正是这一条：「屏幕会把那行置顶」
func _test_insert_keeps_view() -> void:
	_sec("bug 1 · 插入不应该把画面顶走")

	var no := _find_line("alice: 第 70 句。")
	_scroll_top(no)                        # 让被点的那一行在视口顶端，新行必然可见
	await _wait(0.3)
	var before: int = _tbl._scroll.scroll_vertical
	await _row_insert(no)
	_ok(_ed.doc.text_at(no + 1).contains(": 新台词"),
		"新行插在正确位置（实得 %s）" % _ed.doc.text_at(no + 1))
	_ok(_row_visible(no + 1), "新行可见")
	_ok(_tbl._scroll.scroll_vertical == before,
		"视口没动（前 %d / 后 %d）—— 新行本来就在眼前，不该整屏上移一格" % [
			before, _tbl._scroll.scroll_vertical])
	_ok(_tbl._scroll.scroll_vertical != _row_y(no + 1),
		"没有把新行强行置顶（scroll=%d，新行 y=%d）" % [
			_tbl._scroll.scroll_vertical, _row_y(no + 1)])


## 「加出来的文字跟上下文对不上」：在谁的对话里插，就还是谁在说话
func _test_insert_speaker() -> void:
	_sec("bug 1 · 新对白沿用上一行的说话人")

	var no := _find_line("bob: 第 45 句。")
	_ok(no > 0, "找得到 bob 的台词（第 %d 行）" % no)
	if no <= 0:
		return
	_touch_row(no)
	await _wait(0.25)
	await _row_insert(no)
	var new_text: String = _ed.doc.text_at(no + 1)
	_ok(new_text.begins_with("bob: "),
		"在 bob 的对话里插入的新行仍是 bob（实得 %s）" % new_text)


## 插入菜单里的指令模板不能带 `<角色>` / `<语音>` 这类占位符 ——
## 那不是合法内容：`hide <角色>` 插进剧本后静默什么都不做，
## 静态审计也只算「缺素材」（0 错 0 提醒），用户看到的就是
## 「加了东西，但结果对不上」。
func _test_insert_directive_defaults() -> void:
	_sec("bug 1 · 插入指令的默认文本必须是合法内容")

	var anchor := _find_line("alice: 第 30 句。")
	_ok(anchor > 0, "找得到锚点行（第 %d 行）" % anchor)
	if anchor <= 0:
		return

	for op in ["hide", "voice", "bg", "cg", "bgm"]:
		var no := _find_line("alice: 第 30 句。")
		var n0: int = _ed.doc.line_count()
		await _row_insert(no, op)
		if _ed.doc.line_count() != n0 + 1:
			_ok(false, "插入 %s 后行数没 +1" % op)
			continue
		var text: String = _ed.doc.text_at(no + 1)
		_ok(_parse_has(op), "解析器认得出插入的 %s 指令" % op)
		if _index_has_asset(op):
			_ok(not text.contains("<"),
				"插入的 %s 用真实素材 id 填好了（实得 %s）" % [op, text])
		else:
			# 索引里根本没有这类素材（本项目没有 assets/voice/）→ 占位符填不上，
			# 但**必须显式提醒**，不能静默留下一行什么都不做的指令
			_ok(text.contains("<"), "索引无此类素材时保留占位符（实得 %s）" % text)
			_ok(_ed._notice.text.contains("要自己填"),
				"并且弹了「要自己填」的提醒（实得 %s）" % _ed._notice.text)


## 素材索引里有没有该类素材
func _index_has_asset(op: String) -> bool:
	for f in (OpSpec.get_spec(op).get("fields", []) as Array):
		var fd: Dictionary = f
		if String(fd.get("type", "")) != OpSpec.F_ASSET:
			continue
		if _ed.index.ids(String(fd.get("kind", ""))).size() > 0:
			return true
	return false


## 解析全文，看有没有某条指令
func _parse_has(op: String) -> bool:
	var r := GvsParser.parse(_ed.doc.to_text(), "t.gvs")
	for c in (r["commands"] as Array):
		if String((c as Dictionary).get("op", "")) == op:
			return true
	return false


func _test_insert_with_hidden_structure() -> void:
	_sec("bug 1 · 关掉「显示注释与空行」后插入")

	_tbl._show_structure = false
	_tbl._apply_visibility()
	await _wait(0.4)
	_ok(_visible_row_count() < _ed.doc.line_count(),
		"可见行数少于文档行数（差 %d 行）" % [
			_ed.doc.line_count() - _visible_row_count()])

	var no := _find_line("alice: 第 60 句。")
	_scroll_top(no)
	await _wait(0.3)
	await _row_insert(no)
	_ok(_ed.doc.text_at(no + 1).contains(": 新台词"),
		"新行插在正确的位置（实得 %s）" % _ed.doc.text_at(no + 1))
	# 关键：定位必须按行号查行控件，不能拿「行号 - 1」当子节点下标
	_ok(_row_visible(no + 1),
		"新行仍在视口里，没有跳到别的行（scroll=%d，新行 y=%d）" % [
			_tbl._scroll.scroll_vertical, _row_y(no + 1)])

	_tbl._show_structure = true
	_tbl._apply_visibility()
	await _wait(0.3)


func _test_toolbar_insert_anchor() -> void:
	_sec("bug 1 · 顶栏 [+ 添加对白] 的落点")

	# 用户滚到文件末尾附近、并且刚刚点过第 100 行
	var no := _find_line("alice: 第 100 句。")
	_touch_row(no)
	await _wait(0.25)
	_ok(_tbl._current_no == no, "点过第 %d 行后它成为当前行" % no)

	var n0: int = _ed.doc.line_count()
	# 顶栏按钮的 lambda 就是这一句
	_click_row(no)
	_tbl._insert_after_current("__say")
	await _wait(0.5)
	_ok(_ed.doc.line_count() == n0 + 1, "行数 +1")
	_ok(_ed.doc.text_at(no + 1).contains(": 新台词"),
		"新对白插在**当前行之后**，不是插到文件开头（实得第 %d 行 = %s）" % [
			no + 1, _ed.doc.text_at(no + 1)])
	_ok(not _ed.doc.text_at(1).contains("新台词"), "文件开头没有被插进东西")
	_ok(_ed.caret_line == no + 1, "主控的当前行跟到新行（实得 %d）" % _ed.caret_line)
	_ok(_row_visible(no + 1), "新行可见")


func _test_insert_with_filter() -> void:
	_sec("bug 1 · 过滤状态下插入")

	_tbl._search.text = "第 80 句"
	_tbl._apply_visibility()
	await _wait(0.4)
	var no := _find_line("alice: 第 80 句。")
	var row := _tbl._row_by_no.get(no, null) as Control
	_ok(row != null and row.visible, "过滤后目标行仍在表体里且可见")
	if row == null:
		return

	var n0: int = _ed.doc.line_count()
	await _row_insert(no)
	_ok(_ed.doc.line_count() == n0 + 1, "过滤状态下也能插入（行数 +1）")
	_ok(_ed.doc.text_at(no + 1).contains(": 新台词"),
		"插到了正确的行之后（实得 %s）" % _ed.doc.text_at(no + 1))

	_tbl._search.text = ""
	_tbl._apply_visibility()
	await _wait(0.3)


## 当前真正显示出来的行数
func _visible_row_count() -> int:
	var n := 0
	for c in _tbl._body.get_children():
		if (c as Control).visible:
			n += 1
	return n


## 用户报的第三条：**在剧本块里改完一行，右侧预览不更新** ——
## 要点别的行、再点回来才刷新。
##
## 根因：剧本块的改动只 `mark_dirty_from_panel()`（仅置一个「源码视图过期」标记），
## 而源码视图那条路会 `emit committed` → `Editor._on_doc_committed` → 刷预览。
## 剧本块少了后半截。
##
## ⚠️ 断言必须落在**预览上真的显示出了新台词**，不能只断言「函数被调到了」——
## 这个 bug 的特征恰恰是「什么都没发生」。
func _test_preview_follows_edit() -> void:
	print("-- 改完剧本块，右侧预览要立刻跟上 --")
	var no := _find_line("alice: 第 3 句。")
	_ok(no > 0, "找得到要改的那一行")
	# 点这一行 —— 走真实的「选中行」路径，预览会跟着摆到这一行
	_tbl._set_current(no)
	await _wait(0.5)
	var pv = _ed._preview_panel
	_ok(pv._dlg_text.text == "第 3 句。", "预览先显示原台词（实得「%s」）" % pv._dlg_text.text)

	# 改台词 —— 走真实的提交路径
	var row: Control = _tbl._row_by_no.get(no, null)
	var edit := _find_line_edit(row)
	_ok(edit != null, "找得到台词输入框")
	if edit == null:
		return
	edit.text = "改过的第三句。"
	_tbl._commit_text(row, edit.text)
	await _wait(0.5)

	_ok(_ed.doc.text_at(no) == "alice: 改过的第三句。",
		"剧本原文改了（实得「%s」）" % _ed.doc.text_at(no))
	_ok(pv._dlg_text.text == "改过的第三句。",
		"**预览立刻更新**，不用点别的行再点回来（实得「%s」）" % pv._dlg_text.text)
	# 说话人也得跟着走（预览里那一行整体是新的）
	_ok(pv._dlg_name.text == "alice", "预览的说话人没错（实得「%s」）" % pv._dlg_name.text)


## 用户报的第四条：**改指令行的下拉（立绘 / CG / 背景）预览不更新**。
##
## 根因和第三条同源，但漏的是**另一处**：指令行的所有下拉都走 `_field_write`，
## 而它只 `_refresh_row`（重建这一行的控件），**没有 `_after_edit`** ——
## 源码视图不知道文档变了，预览自然也不重画。
##
## 教训：改文档的地方有十几处，**收尾必须收敛到一个函数**，
## 靠「记得加」是守不住的（第三条修完就漏了这一条）。
func _test_preview_follows_field_edit() -> void:
	print("-- 改指令行的下拉，预览也要跟上 --")
	var no := _find_line("bg rooftop")
	_ok(no > 0, "找得到 bg rooftop 那一行")
	_tbl._set_current(no)
	await _wait(0.5)
	var pv = _ed._preview_panel
	_ok(pv._stage.get_bg_id() == "rooftop",
		"预览先显示 rooftop（实得「%s」）" % pv._stage.get_bg_id())

	# 换背景 —— 走真实的下拉信号（按 `field_key` meta 找控件，不按位置）
	var opt := _field_option(no, "id")
	_ok(opt != null, "找得到背景下拉")
	if opt == null:
		return
	var idx := _index_of_text(opt, "classroom")
	_ok(idx >= 0, "下拉里有 classroom（%s）" % str(_opt_texts(opt)))
	if idx < 0:
		return
	opt.item_selected.emit(idx)
	await _wait(0.6)

	_ok(_ed.doc.text_at(no) == "bg classroom fade=0.6",
		"剧本原文改了（实得「%s」）" % _ed.doc.text_at(no))
	_ok(pv._stage.get_bg_id() == "classroom",
		"**预览立刻换成新背景**（实得「%s」）" % pv._stage.get_bg_id())


func _test_state_bar_follows_current() -> void:
	_sec("bug 1 · 状态条跟着当前行（不再跳回第 1 行）")

	# 文件开头放一个背景，中间再放一个 —— 状态条显示哪个就知道它认的是哪一行
	var bg_no := _find_line("bg classroom")
	_ok(bg_no > 0, "文件开头有 `bg classroom`（第 %d 行）" % bg_no)
	var mid_no := _find_line("bg rooftop")
	_ok(mid_no > 0, "中段有 `bg rooftop`（第 %d 行）" % mid_no)
	if mid_no <= 0:
		return

	_touch_row(mid_no)
	await _wait(0.4)
	var bar := _state_bar_text()
	_ok(bar.contains("rooftop"), "状态条显示的是当前行的画面（%s）" % bar)
	# 注意不能断言 `not bar.contains("classroom")` —— CG id 叫 `cg_classroom`，
	# 子串会误命中。要盯的是「背景」这一项。
	_ok(not bar.contains("背景 classroom"), "状态条没有被拽回文件开头的画面")
	_ok(bar.contains("第 %d 行" % mid_no), "状态条标题也是当前行（%s）" % bar)


# ---------------------------------------------------------------------------
# 数据
# ---------------------------------------------------------------------------

func _make_text() -> String:
	var lines := PackedStringArray()
	lines.append("# 头部注释")
	lines.append("")
	lines.append("label start")
	lines.append("bg classroom fade=0.8")
	for i in range(1, 121):
		lines.append("bob: 第 45 句。" if i == 45 else "alice: 第 %d 句。" % i)
		if i == 60:
			lines.append("bg rooftop fade=0.6")
		if i % 20 == 0:
			lines.append("")
			lines.append("# 分隔 %d" % i)
	lines.append("flag talked_to_alice")
	lines.append("flag true_flag true")
	lines.append("")
	lines.append("label end")
	return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# 操作（都走真实路径：控件信号，不直接调内部函数）
# ---------------------------------------------------------------------------

func _click_check(chk: CheckButton, on: bool) -> void:
	chk.button_pressed = on
	chk.toggled.emit(on)


## 走真实路径插入一行：
##   对白 → 先「点一下这一行」（把焦点从输入框上拿开），再按回车
##   其他指令 → 走插入模板
func _row_insert(no: int, op: String = "__say") -> void:
	_click_row(no)
	await _wait(0.1)
	if op == "__say":
		_press(KEY_ENTER)
	else:
		_tbl._insert_block(no, op)
	await _wait(0.4)


## 模拟鼠标点在行上（真实点击会顺带把焦点从输入框挪走）。
##
## **先把它滚进视口** —— 真实的鼠标点不到看不见的行。测试里「点」一个屏幕外的行
## 是现实中不存在的操作，测出来的结论也不可信。
func _click_row(no: int) -> void:
	var row := _tbl._row_by_no.get(no, null) as Control
	if row == null:
		_ok(false, "找不到第 %d 行的行控件" % no)
		return
	if not _tbl._row_in_view(no):
		_scroll_top(no)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	row.gui_input.emit(ev)
	get_viewport().gui_release_focus()


## 模拟在表格上按一个键（焦点不在输入框时的真实路径）
func _press(key: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = key
	ev.pressed = true
	_tbl._unhandled_key_input(ev)


## 模拟「用户点了这一行的任意地方」：行内的输入框拿到焦点正是 _hook_row 挂的钩子
func _touch_row(no: int) -> void:
	var row := _tbl._row_by_no.get(no, null) as Control
	if row == null:
		_ok(false, "找不到第 %d 行的行控件" % no)
		return
	var e := _find_line_edit(row)
	if e != null:
		e.focus_entered.emit()
		return
	var opt := _find_option(row)
	if opt != null:
		opt.pressed.emit()
		return
	_ok(false, "第 %d 行没有任何可交互控件" % no)


# ---------------------------------------------------------------------------
# 查找 / 判定
# ---------------------------------------------------------------------------

func _find_line(prefix: String) -> int:
	for i in range(1, _ed.doc.line_count() + 1):
		if _ed.doc.text_at(i).begins_with(prefix):
			return i
	return -1


func _check_of(no: int) -> CheckButton:
	return _find_check(_tbl._row_by_no.get(no, null) as Control)


func _row_y(no: int) -> int:
	var row := _tbl._row_by_no.get(no, null) as Control
	return int(row.position.y) if row != null else -1


func _row_visible(no: int) -> bool:
	var row := _tbl._row_by_no.get(no, null) as Control
	if row == null or not is_instance_valid(row) or not row.visible:
		return false
	var top := float(row.position.y)
	var vt := float(_tbl._scroll.scroll_vertical)
	return top >= vt - 1.0 and top + row.size.y <= vt + float(_tbl._scroll.size.y) + 1.0


## 把某一行放到视口顶端（测试里用来构造「新行一定可见」的前置条件）
func _scroll_top(no: int) -> void:
	var row := _tbl._row_by_no.get(no, null) as Control
	if row != null and is_instance_valid(row) and row.visible:
		_tbl._scroll.scroll_vertical = int(row.position.y)


func _flag_value(name: String) -> bool:
	var r := GvsParser.parse(_ed.doc.to_text(), "t.gvs")
	for c in (r["commands"] as Array):
		var cmd: Dictionary = c
		if String(cmd.get("op", "")) == "flag" and String(cmd.get("name", "")) == name:
			return bool(cmd.get("value", false))
	return false


func _state_bar_text() -> String:
	var out := PackedStringArray()
	for c in _tbl._state_bar.get_children():
		if c is Label:
			out.append((c as Label).text)
		else:
			for g in c.get_children():
				if g is Label:
					out.append((g as Label).text)
	return " | ".join(out)


## 用户报的第五条：alice 的立绘显示「缺文件」，明明有这个角色。
##
## 根因：`_asset_field` 拿 `sel == 0` 当「没找到」的哨兵，而下标 0 是**合法值** ——
## 列表里**第一个**素材永远被判成「缺文件」。`alice` 正好是排序后的第一个，
## 所以只有她中招（bg 列表里第一个是 classroom，同理）。
func _test_asset_dropdown_first_item() -> void:
	print("-- 素材下拉：第一个不该被判成「缺文件」--")
	var no := _find_line("bg classroom")
	_ok(no > 0, "找得到 bg classroom 那一行")
	var opt := _field_option(no, "id")
	_ok(opt != null, "找得到背景素材下拉")
	if opt == null:
		return
	var texts := _opt_texts(opt)
	var bad := ""
	for t in texts:
		if String(t).ends_with("（缺文件）"):
			bad = String(t)
	_ok(bad.is_empty(), "下拉里没有「（缺文件）」项（实得 %s，列表 %s）" % [bad, str(texts)])
	_ok(texts[opt.selected] == "classroom",
		"选中的就是 classroom（实得 %s）" % texts[opt.selected])
	_ok(texts.size() == 3, "选项数 = 素材数 3（实得 %d）" % texts.size())


## 按 `field_key` meta 找指令行的字段控件（`TablePanel._directive_row` 盖的）
func _field_option(no: int, key: String) -> OptionButton:
	var row: Control = _tbl._row_by_no.get(no, null)
	if row == null:
		return null
	var c := _find_by_meta(row, "field_key", key)
	if c is OptionButton:
		return c as OptionButton
	return _find_option(c) if c != null else null


func _find_by_meta(node: Node, meta: String, value: String) -> Control:
	if node.has_meta(meta) and String(node.get_meta(meta)) == value:
		return node as Control
	for c in node.get_children():
		var r := _find_by_meta(c, meta, value)
		if r != null:
			return r
	return null


static func _opt_texts(opt: OptionButton) -> Array:
	var out: Array = []
	if opt == null:
		return out
	for i in opt.item_count:
		out.append(opt.get_item_text(i))
	return out


static func _index_of_text(opt: OptionButton, text: String) -> int:
	if opt == null:
		return -1
	for i in opt.item_count:
		if opt.get_item_text(i) == text:
			return i
	return -1


func _find_button(node: Control, text: String) -> Button:
	if node == null:
		return null
	for c in node.get_children():
		if c is Button and not (c is OptionButton) and (c as Button).text == text:
			return c
	return null


func _find_check(node: Control) -> CheckButton:
	if node == null:
		return null
	for c in node.get_children():
		if c is CheckButton:
			return c
		if c.get_child_count() > 0:
			var r := _find_check(c as Control)
			if r != null:
				return r
	return null


func _find_line_edit(node: Control) -> LineEdit:
	if node == null:
		return null
	for c in node.get_children():
		if c is LineEdit:
			return c
		if c.get_child_count() > 0:
			var r := _find_line_edit(c as Control)
			if r != null:
				return r
	return null


func _find_option(node: Control) -> OptionButton:
	if node == null:
		return null
	for c in node.get_children():
		if c is OptionButton:
			return c
	return null


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


func _sec(t: String) -> void:
	print("\n-- %s --" % t)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
