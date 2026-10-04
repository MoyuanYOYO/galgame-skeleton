extends Node

## 对白表格「新交互」验收
##
## 覆盖用户点名要的那几条：
##   点选中行 · 回车在下方加一行 · 退格删行 · 方向键换行
##   左侧指令列可点击换类型 · 行右不再有 + / x
## 外加一起做的附加项：
##   块层级竖线 + 折叠 · 块间距 · 行内错误标记 · 多行粘贴拆行 · 插入后自动聚焦
##
## 全部走真实路径（控件信号 / 键事件），不直接改文档。
##
## 跑法（要带窗口）：
##   godot --path . res://tools/editor/tests/table_ux_test.tscn

const EditorScene = preload("res://tools/editor/editor.tscn")
const GvsParser = preload("res://scripts/core/gvs_parser.gd")
const EdTheme = preload("res://tools/editor/ed_theme.gd")
const OpSpec = preload("res://tools/editor/core/op_spec.gd")

var _ed: Control
var _tbl: Control
var _tmp := "user://__table_ux.gvs"
var _tmp2 := "user://__table_ux2.gvs"
var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 对白表格 新交互验收 ===")
	_write(_tmp, _make_text())

	_ed = EditorScene.instantiate()
	add_child(_ed)
	_ed.size = get_viewport().get_visible_rect().size
	await _wait(1.0)
	_ed._open(_tmp)
	await _wait(0.4)
	_ed.show_page("table")
	await _wait(0.7)
	_tbl = _ed._pages.get("table")
	_ok(_tbl != null, "对白表格面板已创建")
	if _tbl == null:
		_finish()
		return

	await _test_no_tail_buttons()
	await _test_tag_colors()
	await _test_basic_blocks()
	await _test_select_and_arrows()
	await _test_enter_inserts_below()
	await _test_enter_in_text_field_chains()
	await _test_backspace_deletes()
	await _test_delete_lands_on_previous_row()
	await _test_type_dropdown_convert()
	await _test_type_menu_real_path()
	await _test_fold_and_guides()
	await _test_paste_multiline()
	await _test_issue_marks()
	await _test_second_fixture()

	_ed.queue_free()
	await _wait(0.3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp2))
	_finish()


## 第二组夹具：行号联动 / 新增的指令类型 / ending 与 chapter 的标题 / 跳转链接。
##
## 单开一个文件是因为第一组夹具的**行号**被好几条断言写死了，
## 往里加行会连带改一堆期望值。
func _test_second_fixture() -> void:
	_sec("第二组夹具：行号联动 / 新指令类型 / 标题 / 跳转链接")
	_write(_tmp2, _make_text2())
	_ed._open(_tmp2)
	await _wait(0.6)
	_ed.show_page("table")
	await _wait(0.8)
	_tbl = _ed._pages.get("table")
	_ok(_ed.doc.line_count() >= 12, "第二组夹具已打开（%d 行）" % _ed.doc.line_count())

	await _test_type_menu_has_new_ops()
	await _test_structural_op_inserts()
	await _test_ending_title()
	await _test_chapter_title()
	await _test_set_var_offset()
	await _test_renumber_after_insert()
	await _test_jump_link()
	await _test_choice_arrow()


## 菜单里要能看到新加的那些指令
func _test_type_menu_has_new_ops() -> void:
	_sec("指令类型菜单：新增的选项")
	var no := _find_line("alice: 第一句。")
	_tbl._open_type_menu(no)
	await _wait(0.3)
	var want := ["set", "add", "sub", "chapter", "unlock", "carry", "minigame",
		"label", "jump", "goto", "call", "return", "jump_file"]
	var missing := PackedStringArray()
	for op in want:
		if _menu_index_of(String(op)) < 0:
			missing.append(String(op))
	_ok(missing.is_empty(), "%d 个新选项都在菜单里（缺 %s）" % [want.size(), " ".join(missing)])
	# 结构那一组要能被认出来（界面上会把它当「插入」处理）
	_ok(OpSpec.is_structural("jump") and not OpSpec.is_structural("set"),
		"结构指令的判定没变（jump 是，set 不是）")


## 选结构指令 = **插入一条**，不是把现有行改掉
func _test_structural_op_inserts() -> void:
	_sec("选结构指令是「插入一条」")
	var no := _find_line("alice: 第一句。")
	var n0: int = _ed.doc.line_count()
	_tbl._open_type_menu(no)
	await _wait(0.3)
	var idx := _menu_index_of("jump")
	_ok(idx >= 0, "菜单里找得到「跳转」")
	if idx < 0:
		return
	_tbl._type_menu.index_pressed.emit(idx)
	await _wait(0.6)
	_ok(_ed.doc.line_count() == n0 + 1, "行数 +1（实得 %d，原 %d）" % [_ed.doc.line_count(), n0])
	_ok(_ed.doc.text_at(no).begins_with("alice: "),
		"原来那一行没被改掉（实得 %s）" % _ed.doc.text_at(no))
	_ok(_ed.doc.text_at(no + 1).begins_with("jump "),
		"新插的那行是 jump（实得 %s）" % _ed.doc.text_at(no + 1))
	_ok(not _ed.doc.text_at(no + 1).strip_edges() == "jump",
		"带上了骨架（不是光秃秃的 jump）")


## `ending <id> "标题"` 的标题要读得出来、也写得回去
func _test_ending_title() -> void:
	_sec("结局标题（双引号整段）")
	var no := _find_line("ending normal")
	_ok(no > 0, "找得到结局行（第 %d 行）" % no)
	var row := _tbl._row_by_no.get(no, null) as Control
	var title := _text_field_of(row, "留到下个春天")
	_ok(title != null, "标题框里读出了「留到下个春天」（整段双引号解析对了）")
	if title == null:
		return
	# 改标题：必须写成 `"…"`，而且读回来还是新的
	(title as LineEdit).text_submitted.emit("春日的答案")
	await _wait(0.5)
	var raw: String = _ed.doc.text_at(no)
	_ok(raw.contains("\"春日的答案\""),
		"写回时带上了双引号（实得 %s）" % raw)
	var title2 := _text_field_of(_tbl._row_by_no.get(no, null) as Control, "春日的答案")
	_ok(title2 != null, "改完之后标题框里还是新值（不会「按回车就消失」）")
	# 带空格的标题也要能整段存下来
	(title2 as LineEdit).text_submitted.emit("春日的 答案 · 上")
	await _wait(0.5)
	_ok(String(_ed.doc.text_at(no)).contains("\"春日的 答案 · 上\""),
		"含空格的标题整段写回（实得 %s）" % _ed.doc.text_at(no))
	var title3 := _text_field_of(_tbl._row_by_no.get(no, null) as Control, "春日的 答案 · 上")
	_ok(title3 != null, "含空格的标题也读得回来")


## `chapter 第一章 · 春日的答案` —— 同样的「整段双引号」形态
func _test_chapter_title() -> void:
	_sec("章节名（整段，且含空格与 ·）")
	var no := _find_line("chapter 第一章")
	_ok(no > 0, "找得到 chapter 行（第 %d 行）" % no)
	var row := _tbl._row_by_no.get(no, null) as Control
	var f := _text_field_of(row, "第一章 · 春日的答案")
	_ok(f != null, "章节名读出来了（含空格与 ·）")
	if f == null:
		return
	(f as LineEdit).text_submitted.emit("第二章 · 夏")
	await _wait(0.5)
	_ok(String(_ed.doc.text_at(no)).contains("\"第二章 · 夏\""),
		"写回带引号（实得 %s）" % _ed.doc.text_at(no))


## `set var stance "defend"` 里的可选 `var` 会占掉位置参数的第 0 位
func _test_set_var_offset() -> void:
	_sec("变量指令的可选 var")
	var no := _find_line("set var stance")
	_ok(no > 0, "找得到 `set var stance`（第 %d 行）" % no)
	var row := _tbl._row_by_no.get(no, null) as Control
	_ok(_text_field_of(row, "stance") != null,
		"变量名读的是 stance 而不是 var（pos 偏移对了）")
	_ok(_text_field_of(row, "defend") != null, "值读出来了")

	var no2 := _find_line("set chapter 1")
	_ok(no2 > 0, "找得到不带 var 的 `set chapter 1`（第 %d 行）" % no2)
	var row2 := _tbl._row_by_no.get(no2, null) as Control
	_ok(_text_field_of(row2, "chapter") != null, "不带 var 时变量名是 chapter")
	_ok(_text_field_of(row2, "1") != null, "值是 1")


## 插入之后，**下面那些行显示的数字**也要跟着变
func _test_renumber_after_insert() -> void:
	_sec("插入后下方行号要更新")
	var last: int = _ed.doc.line_count()
	var row := _tbl._row_by_no.get(last, null) as Control
	_ok(row != null, "拿得到最后一行的行控件（第 %d 行）" % last)
	if row == null:
		return
	_ok(_no_btn_text(row) == str(last), "插入前显示 %s" % _no_btn_text(row))

	var at := _find_line("label start")
	_tbl._set_current(at)
	await _wait(0.2)
	_click_row(at)
	_press(KEY_ENTER)
	await _wait(0.6)

	_ok(_ed.doc.line_count() == last + 1, "文档行数 +1")
	_ok(_tbl._row_by_no.get(last + 1, null) == row,
		"还是同一个行控件（没有整表重建）")
	_ok(_no_btn_text(row) == str(last + 1),
		"它的行号从 %d 更新成了 %s" % [last, _no_btn_text(row)])
	_ok(_no_of_row(row) == last + 1, "meta 里的行号也跟着变了")


## 跳转目标做成可点击的链接
func _test_jump_link() -> void:
	_sec("跳转目标可点击")
	var no := _find_line("jump target_a")
	_ok(no > 0, "找得到 `jump target_a`（第 %d 行）" % no)
	var row := _tbl._row_by_no.get(no, null) as Control
	var link := _link_of(row, "target_a")
	_ok(link != null, "目标渲染成了可点击的链接")
	if link == null:
		return
	_ok(link.get_theme_color("font_color") == EdTheme.ACCENT,
		"目标存在时是链接色")
	link.pressed.emit()
	await _wait(0.5)
	# **留在剧本块页**（用户要求：定位不要去源码页）
	_ok(_ed._current_page == "table", "点了之后留在剧本块页（实得 %s）" % _ed._current_page)
	_ok(_tbl._current_no == _label_line("target_a"),
		"剧本块的当前行落到 label target_a（实得 %d，期望 %d；doc.label_line=%d 行数=%d lines=%d）"
		% [_tbl._current_no, _label_line("target_a"), _ed.doc.label_line("target_a"),
			_ed.doc.line_count(), _ed.doc.lines.size()])
	_ok(_ed.caret_line == _tbl._current_no,
		"主控的光标行也跟上了（实得 %d）" % _ed.caret_line)
	_ok(_row_selected(_tbl._current_no), "并且那一行被高亮")

	# 跳到一个不存在的标签：标红 + 点了给提示
	_ed.show_page("table")
	await _wait(0.5)
	var bad_no := _find_line("jump no_such_label")
	_ok(bad_no > 0, "找得到指向不存在标签的那一行（第 %d 行）" % bad_no)
	var bad_row := _tbl._row_by_no.get(bad_no, null) as Control
	var bad_link := _link_of(bad_row, "no_such_label")
	_ok(bad_link != null, "那一行也有链接")
	if bad_link != null:
		_ok(bad_link.get_theme_color("font_color") == EdTheme.ERR,
			"找不到目标时标红（这样「死跳转」在表格里一眼看得见）")
		bad_link.pressed.emit()
		await _wait(0.3)
		_ok(_ed._notice.text.contains("找不到标签"),
			"点了会明确提示（实得 %s）" % _ed._notice.text)

	# 跨文件跳转：点了要打开另一个剧本
	var jf := _find_line("jump_file")
	_ok(jf > 0, "找得到 jump_file（第 %d 行）" % jf)
	var jf_row := _tbl._row_by_no.get(jf, null) as Control
	var jf_link := _link_of(jf_row, "chapter1_start")
	_ok(jf_link != null, "跨文件目标也是可点击的")
	if jf_link != null:
		jf_link.pressed.emit()
		await _wait(0.7)
		_ok(_ed.doc.path.contains("chapter1.gvs"),
			"点了打开了另一个剧本（实得 %s）" % _ed.doc.path)
		_ok(_ed._current_page == "table",
			"而且**留在剧本块页**（实得 %s）" % _ed._current_page)


## choice 选项的箭头也要能点击定位（用户明确要求）
func _test_choice_arrow() -> void:
	_sec("choice 选项的箭头可点击")

	# 上一节点了 jump_file，文档已经切到 chapter1.gvs —— 先切回夹具
	_ed._open(_tmp2, false, true)
	await _wait(0.7)

	var no := _find_line("\"选项一\"")
	_ok(no > 0, "找得到选项行（第 %d 行）" % no)
	var row := _tbl._row_by_no.get(no, null) as Control
	var arrow := _link_of(row, "→")
	_ok(arrow != null, "选项行有一个可点击的箭头")
	if arrow == null:
		return
	_ok(arrow.get_theme_color("font_color") == EdTheme.ACCENT, "目标存在时是链接色")

	arrow.pressed.emit()
	await _wait(0.5)
	_ok(_ed._current_page == "table", "点了留在剧本块页（实得 %s）" % _ed._current_page)
	_ok(_tbl._current_no == _label_line("target_a"),
		"跳到了目标标签（实得 %d，期望 %d）" % [_tbl._current_no, _label_line("target_a")])

	# 指向不存在的标签 → 标红 + 明确提示
	var no2 := _find_line("\"选项二\"")
	var row2 := _tbl._row_by_no.get(no2, null) as Control
	var arrow2 := _link_of(row2, "→")
	_ok(arrow2 != null and arrow2.get_theme_color("font_color") == EdTheme.ERR,
		"指向不存在的标签时箭头标红")
	if arrow2 != null:
		arrow2.pressed.emit()
		await _wait(0.3)
		_ok(_ed._notice.text.contains("找不到标签"),
			"点了会明确提示（实得 %s）" % _ed._notice.text)


func _no_btn_text(row: Control) -> String:
	var b := row.get_meta("no_btn", null) as Button
	return "" if b == null else b.text


func _no_of_row(row: Control) -> int:
	return int(row.get_meta("line_no", 0))


## 行里那个「文本等于 want」的输入框
func _text_field_of(row: Control, want: String) -> LineEdit:
	for e in _all_line_edits(row):
		if (e as LineEdit).text == want:
			return e
	return null


func _all_line_edits(node: Node) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is LineEdit:
			out.append(c)
		out.append_array(_all_line_edits(c))
	return out


## 行里那个「文字等于 want」的链接按钮
func _link_of(row: Control, want: String) -> Button:
	for b in _all_buttons(row):
		if (b as Button).text == want and (b as Button).flat:
			return b
	return null


func _label_line(label: String) -> int:
	for i in range(1, _ed.doc.line_count() + 1):
		if _ed.doc.text_at(i).strip_edges() == "label %s" % label:
			return i
	return -1


func _make_text2() -> String:
	return "\n".join(PackedStringArray([
		"# 第二组夹具",
		"label start",
		"alice: 第一句。",
		"jump target_a",
		"alice: 这段是死代码。",
		"label target_a",
		"alice: 到了 A。",
		"ending normal \"留到下个春天\"",
		"chapter 第一章 · 春日的答案",
		"set var stance \"defend\"",
		"set chapter 1",
		"jump no_such_label",
		"jump_file res://data/scripts/chapter1.gvs chapter1_start",
		"label choice_demo",
		"choice",
		"    \"选项一\" -> target_a",
		"    \"选项二\" -> nowhere",
		"end",
	])) + "\n"


# ---------------------------------------------------------------------------
# 行右不再有 + / x
# ---------------------------------------------------------------------------

func _test_no_tail_buttons() -> void:
	_sec("行右不再有增删按钮")
	var bad := PackedStringArray()
	for no in _tbl._row_by_no.keys():
		var row := _tbl._row_by_no[no] as Control
		for b in _all_buttons(row):
			var t := (b as Button).text
			if t == "+" or t == "x" or t == "✕":
				bad.append("%d:%s" % [no, t])
	_ok(bad.is_empty(), "没有任何行还挂着 + / x（实得 %s）" % " ".join(bad))
	_ok(_find_button(_tbl, "+ 添加对白") != null, "工具栏的「+ 添加对白」还在")

	# 空行 / 注释行的类型格也要有名字 —— 否则就是一个孤零零的「▾」
	var blank_no := -1
	var comment_no := -1
	for i in range(1, _ed.doc.line_count() + 1):
		var t: String = _ed.doc.text_at(i).strip_edges()
		if blank_no < 0 and t.is_empty():
			blank_no = i
		if comment_no < 0 and t.begins_with("#"):
			comment_no = i
	_ok(blank_no > 0 and _type_text(blank_no) == "空行",
		"空行的类型格显示「空行」（实得 %s）" % _type_text(blank_no))
	_ok(comment_no > 0 and _type_text(comment_no) == "注释",
		"注释行的类型格显示「注释」（实得 %s）" % _type_text(comment_no))

	# 默认不显示空行与注释（剧本里空行很多，一上来铺满会稀释有内容的行）
	_ok(not _tbl._show_structure, "默认关闭「显示注释与空行」")
	_ok(blank_no > 0 and not _row_visible(blank_no), "空行默认不显示")
	_ok(comment_no > 0 and not _row_visible(comment_no), "注释行默认不显示")
	_tbl._show_structure = true
	_tbl._apply_visibility()
	await _wait(0.25)
	_ok(_row_visible(blank_no) and _row_visible(comment_no), "打开开关后两者都显示")
	_tbl._show_structure = false
	_tbl._apply_visibility()
	await _wait(0.25)


## 指令类型配色：各类要两两分得开。
##
## 用户报的原始问题：**对白与立绘同色**（都用了 SYN_SPEAKER），
## 而这两类恰恰最需要区分（一个改台词、一个改画面）。
## 所以这里断言的不只是「这两个不同」，而是「各类在色相环上都拉开了」。
##
## ⚠️ 新增一类配色时**必须把它加进下面的 groups** —— 否则新色可以跟任何一色
## 撞在一起而断言照样全绿，这张表就成了摆设。
func _test_tag_colors() -> void:
	_sec("指令类型配色")
	var groups := {
		"SAY": ["SAY"], "CHAR": ["CHAR"], "BG": ["BG", "CG"],
		"BGM": ["BGM", "SE", "VO"], "FX": ["FX"], "AFX": ["AFX"],
		"STATE": ["STATE"], "VIDEO": ["VIDEO"], "FLOW": ["FLOW"],
	}
	var bad := PackedStringArray()
	for g in groups.keys():
		var ref := EdTheme.tag_color(String((groups[g] as Array)[0]))
		for t in (groups[g] as Array):
			if EdTheme.tag_color(String(t)) != ref:
				bad.append("%s 组内不一致" % g)
	_ok(bad.is_empty(), "同用途的指令同色（%s）" % " ".join(bad))

	var names: Array = groups.keys()
	var close := PackedStringArray()
	for i in names.size():
		for j in range(i + 1, names.size()):
			var a := EdTheme.tag_color(String(names[i]))
			var b := EdTheme.tag_color(String(names[j]))
			if a == b:
				close.append("%s 与 %s 完全同色" % [names[i], names[j]])
				continue
			var dh := absf(a.h * 360.0 - b.h * 360.0)
			dh = minf(dh, 360.0 - dh)
			if dh < 20.0:
				close.append("%s 与 %s 只差 %.0f°" % [names[i], names[j], dh])
	_ok(close.is_empty(), "各类两两分得开（%s）" % " ".join(close))

	_ok(EdTheme.tag_color("SAY") != EdTheme.tag_color("CHAR"),
		"对白与立绘不再同色（%s vs %s）" % [
			EdTheme.tag_color("SAY").to_html(false),
			EdTheme.tag_color("CHAR").to_html(false)])
	# 类型格实际用上了这张表（不是各写一份）
	var no := _find_line("bob@smile: 第二句。")
	var cell := _type_button(no)
	_ok(cell != null and cell.get_theme_color("font_color") == EdTheme.tag_color("SAY"),
		"对白那一格用的是 SAY 色（实得 %s）" % (
			cell.get_theme_color("font_color").to_html(false) if cell != null else "无"))


# ---------------------------------------------------------------------------
# 基本块分隔（领导点划分）
# ---------------------------------------------------------------------------

## 领导点规则（编译原理意义上的 basic block leader）：
##   文件首行 · 所有 label（跳转到达行）· 跳转/结束指令的下一行 ·
##   if / elif / else / choice / end 的下一行
##
## 这一节必须在**动过文档之前**跑：断言的是具体行号。
func _test_basic_blocks() -> void:
	_sec("基本块分隔（领导点划分）")

	# 夹具（18 行）按规则算出的领导点 → 块序号
	var expect := {1: 1, 2: 2, 11: 3, 14: 4, 15: 5, 17: 6}
	var bad := PackedStringArray()
	for no in expect.keys():
		if int(_tbl._block_of.get(no, -1)) != int(expect[no]):
			bad.append("第 %d 行应是块 %d（实得 %s）" % [
				no, expect[no], str(_tbl._block_of.get(no, "无"))])
	for no in _tbl._block_of.keys():
		if not expect.has(int(no)):
			bad.append("第 %d 行不该是领导点" % no)
	_ok(bad.is_empty(), "领导点集合与规则一致：%d 个（%s）" % [_block_of_size(), " ".join(bad)])

	# 样式：块首上方有分隔线 + 额外间距
	var st := _row_stylebox(11)          # 第 11 行 = choice 的下一行
	_ok(st != null and st.border_width_top == 1, "块首行画了上分隔线")
	_ok(st != null and st.content_margin_top >= 16,
		"块首上方留了间距（实得 %d）" % (st.content_margin_top if st else -1))
	var st2 := _row_stylebox(3)          # 第 3 行不是领导点
	_ok(st2 != null and st2.border_width_top == 0, "非块首行没有分隔线")

	# 第一块（第 1 行）不该在自己上面画线
	var st1 := _row_stylebox(1)
	_ok(st1 != null and st1.border_width_top == 0, "第一块上方不画线")

	# 关掉开关 → 分隔线消失
	_tbl._show_blocks = false
	_tbl._restyle_all()
	await _wait(0.2)
	var st3 := _row_stylebox(11)
	_ok(st3 != null and st3.border_width_top == 0, "关掉「基本块分隔」后不再画线")
	_tbl._show_blocks = true
	_tbl._restyle_all()
	await _wait(0.2)


func _block_of_size() -> int:
	return _tbl._block_of.size()


# ---------------------------------------------------------------------------
# 选中 + 方向键
# ---------------------------------------------------------------------------

func _test_select_and_arrows() -> void:
	_sec("点选中行 + 方向键")

	var no := _find_line("alice: 第三句。")
	_ok(no > 0, "找得到锚点行（第 %d 行）" % no)
	_click_row(no)
	await _wait(0.2)
	_ok(_tbl._current_no == no, "点一下就选中了（实得 %d）" % _tbl._current_no)
	_ok(_row_selected(no), "那一行有选中底色")
	_ok(not _row_selected(no + 1), "相邻行没有一起被选中")

	_press(KEY_DOWN)
	await _wait(0.2)
	_ok(_tbl._current_no == no + 1, "↓ 移到下一行（实得 %d）" % _tbl._current_no)
	_press(KEY_UP)
	await _wait(0.2)
	_ok(_tbl._current_no == no, "↑ 移回来（实得 %d）" % _tbl._current_no)


# ---------------------------------------------------------------------------
# 回车加一行
# ---------------------------------------------------------------------------

func _test_enter_inserts_below() -> void:
	_sec("回车在选中行下方加一行对白")

	var no := _find_line("alice: 第三句。")
	_click_row(no)
	await _wait(0.2)
	var n0: int = _ed.doc.line_count()
	_press(KEY_ENTER)
	await _wait(0.5)
	_ok(_ed.doc.line_count() == n0 + 1, "行数 +1")
	_ok(_ed.doc.text_at(no + 1).contains(": 新台词"),
		"新行紧跟选中行（实得 %s）" % _ed.doc.text_at(no + 1))
	_ok(_tbl._current_no == no + 1, "选中跟到新行")
	# 自动聚焦：新行的台词输入框应该拿到焦点
	var focus := get_viewport().gui_get_focus_owner()
	_ok(focus is LineEdit, "新行的台词输入框自动获得焦点（实得 %s）" % str(focus))


## 在台词框里直接回车 → 提交并接下一行（连续写剧本的主路径）
func _test_enter_in_text_field_chains() -> void:
	_sec("台词框里回车 → 提交并接下一行")

	var focus := get_viewport().gui_get_focus_owner()
	_ok(focus is LineEdit, "焦点还在台词框里")
	if not (focus is LineEdit):
		return
	(focus as LineEdit).text = "连着写的一句。"
	var n0: int = _ed.doc.line_count()
	(focus as LineEdit).text_submitted.emit("连着写的一句。")
	await _wait(0.5)
	_ok(_ed.doc.line_count() == n0 + 1, "又接了一行（行数 +1）")
	var txt: String = _ed.doc.to_text()
	_ok(txt.contains("连着写的一句。"), "刚敲的那句已经写进剧本")


# ---------------------------------------------------------------------------
# 退格删行
# ---------------------------------------------------------------------------

func _test_backspace_deletes() -> void:
	_sec("退格删除选中行")

	var no := _find_line("alice: 连着写的一句。")
	_ok(no > 0, "找得到刚加的那一行（第 %d 行）" % no)
	_click_row(no)
	await _wait(0.2)
	var n0: int = _ed.doc.line_count()
	_press(KEY_BACKSPACE)
	await _wait(0.4)
	_ok(_ed.doc.line_count() == n0 - 1, "行数 -1（实得 %d）" % _ed.doc.line_count())
	_ok(not _ed.doc.to_text().contains("连着写的一句。"), "那一行没了")

	# 焦点在输入框里时，退格**只能删字符**，不能删行
	var no2 := _find_line("alice: 第三句。")
	var row := _tbl._row_by_no.get(no2, null) as Control
	var e := _find_line_edit(row)
	_ok(e != null, "拿得到台词输入框")
	if e != null:
		e.grab_focus()
		await _wait(0.2)
		var n1: int = _ed.doc.line_count()
		_press(KEY_BACKSPACE)
		await _wait(0.3)
		_ok(_ed.doc.line_count() == n1, "焦点在输入框时退格不会删掉整行")
		get_viewport().gui_release_focus()


# ---------------------------------------------------------------------------
# 删除后的落点 + 「看不见的行不作为落点」
# ---------------------------------------------------------------------------

## 退格删完要吸附到**上一行**（与文本编辑器里退格合并行的直觉一致）。
##
## 自己插一行再删掉，**净改动为零** —— 免得弄坏后面那些依赖夹具内容的断言。
func _test_delete_lands_on_previous_row() -> void:
	_sec("退格删除后吸附到上一行")

	var anchor := _find_line("alice: 第三句。")
	_ok(anchor > 0, "找得到锚点行（第 %d 行）" % anchor)
	_click_row(anchor)
	await _wait(0.2)
	_press(KEY_ENTER)
	await _wait(0.5)
	var new_no: int = _tbl._current_no
	_ok(_ed.doc.text_at(new_no).contains(": 新台词"),
		"先插了一行（第 %d 行：%s）" % [new_no, _ed.doc.text_at(new_no)])

	var next_text: String = _ed.doc.text_at(new_no + 1)
	# 插入之后焦点自动落在新行的台词框里 —— 那时按退格只删字符、不删行（这是对的）。
	# 要删整行得先把焦点从输入框挪开，真实用户也是「点一下那一行」再按退格。
	_click_row(new_no)
	await _wait(0.2)
	_press(KEY_BACKSPACE)
	await _wait(0.5)
	_ok(_ed.doc.text_at(new_no) == next_text,
		"下一行顶上来了（实得 %s）" % _ed.doc.text_at(new_no))
	_ok(_tbl._current_no == new_no - 1,
		"选中吸附到**上一行**而不是下一行（实得第 %d 行，被删的是第 %d 行）"
		% [_tbl._current_no, new_no])
	var st := _row_stylebox(_tbl._current_no)
	_ok(st != null and st.bg_color == EdTheme.SEL_BG, "那一行确实被高亮了")


# ---------------------------------------------------------------------------
# 指令列下拉 / 类型转换
# ---------------------------------------------------------------------------

func _test_type_dropdown_convert() -> void:
	_sec("左侧指令列可点击换类型")

	# 对白 → 指令：说话人要跟着搬过去
	var no := _find_line("bob@smile: 第二句。")
	_ok(no > 0, "找得到 bob 的对白（第 %d 行）" % no)
	_ok(_type_text(no).begins_with("对白"), "类型列显示「对白」（实得 %s）" % _type_text(no))

	_tbl._convert_line(no, "show")
	await _wait(0.4)
	var raw: String = _ed.doc.text_at(no)
	_ok(raw.begins_with("show bob"), "转成立绘入场并沿用说话人（实得 %s）" % raw)
	_ok(_type_text(no).begins_with("立绘入场"), "类型列跟着变了（实得 %s）" % _type_text(no))
	_ok(_parsed_has("show"), "解析器认得出转换后的指令")

	# 指令 → 对白：角色要变成说话人
	_tbl._convert_line(no, "__say")
	await _wait(0.4)
	_ok(_ed.doc.text_at(no).begins_with("bob: "),
		"转回对白并沿用角色（实得 %s）" % _ed.doc.text_at(no))

	# 指令 → 指令：能沿用的 kv 参数要带过去
	var no2 := _find_line("show alice expr=normal")
	_ok(no2 > 0, "找得到 `show alice ... at=left fade=0.5`（第 %d 行）" % no2)
	_tbl._convert_line(no2, "move")
	await _wait(0.4)
	var raw2: String = _ed.doc.text_at(no2)
	_ok(raw2.begins_with("move alice"), "角色沿用（实得 %s）" % raw2)
	_ok(raw2.contains("fade=0.5"), "同类型的 kv 参数沿用（实得 %s）" % raw2)
	_ok(not raw2.contains("expr="), "新指令没有的参数不带过去（实得 %s）" % raw2)

	# 结构行不给换类型
	var label_no := _find_line("label label_a")
	_tbl._convert_line(label_no, "bg")
	await _wait(0.2)
	_ok(_ed.doc.text_at(label_no).begins_with("label"),
		"结构行改类型被拒绝（实得 %s）" % _ed.doc.text_at(label_no))


# ---------------------------------------------------------------------------
# 类型下拉：走真实路径（点格子 → 菜单弹出 → 点菜单项）
# ---------------------------------------------------------------------------

## 这一段是**必须走菜单**的：`_convert_line` 直接调能过，
## 但菜单的下标一旦算错（`add_separator()` 也占下标），
## 每个菜单项挂的就是**前一项**的 metadata —— 点「背景」没反应、
## 点「立绘入场」插出「立绘退场」。用户报的「点击没有反应」就是这个。
func _test_type_menu_real_path() -> void:
	_sec("类型下拉走真实路径（点格子 → 选菜单项）")

	var no := _find_line("alice: 第三句。")
	var btn := _type_button(no)
	_ok(btn != null, "类型格是个按钮")
	if btn == null:
		return
	btn.pressed.emit()
	# 轮询等它真的可见 —— 菜单有 44 项，`popup()` 到 `visible` 之间偶尔要一两帧，
	# 固定等 0.3s 会偶发失败
	for _i in 20:
		if _tbl._type_menu.visible:
			break
		await _wait(0.1)
	_ok(_tbl._type_menu.visible, "点一下菜单弹出来了")

	# 每一项的 metadata 必须等于标签里括号中的那个 op —— 一条抓全表 off-by-one
	var bad := PackedStringArray()
	var total := 0
	for i in _tbl._type_menu.item_count:
		# 分组标题（disabled）与分隔线都不该有 metadata
		if _tbl._type_menu.is_item_disabled(i) or _tbl._type_menu.is_item_separator(i):
			continue
		var text: String = _tbl._type_menu.get_item_text(i)
		var md: Variant = _tbl._type_menu.get_item_metadata(i)
		if md == null:
			bad.append("「%s」没有 metadata" % text)
			continue
		var lp: int = text.rfind("(")
		var rp: int = text.rfind(")")
		if lp < 0 or rp <= lp:
			bad.append("「%s」标签里没有 op" % text)
			continue
		var label_op: String = text.substr(lp + 1, rp - lp - 1)
		total += 1
		if String(md) != label_op:
			bad.append("「%s」挂的是 %s" % [label_op, str(md)])
	_ok(bad.is_empty(), "%d 个菜单项标签与 metadata 一一对应（%s）" % [total, " ".join(bad)])

	# 点「立绘退场」（在第二组之后，正是 off-by-one 最容易错的地方）
	var want := _menu_index_of("hide")
	_ok(want >= 0, "菜单里找得到 hide 项")
	if want >= 0:
		_tbl._type_menu.index_pressed.emit(want)
		await _wait(0.4)
		var raw: String = _ed.doc.text_at(no)
		_ok(raw.begins_with("hide "), "点「立绘退场」得到的就是 hide（实得 %s）" % raw)
		_ok(not raw.begins_with("move"), "没有串到隔壁项去")


func _type_button(no: int) -> Button:
	var row := _tbl._row_by_no.get(no, null) as Control
	if row == null:
		return null
	var h := row.get_child(0) as HBoxContainer
	if h == null or h.get_child_count() < 4:
		return null
	return h.get_child(3) as Button


func _menu_index_of(op: String) -> int:
	for i in _tbl._type_menu.item_count:
		var md: Variant = _tbl._type_menu.get_item_metadata(i)
		if md != null and String(md) == op:
			return i
	return -1


# ---------------------------------------------------------------------------
# 折叠 + 块竖线 + 块间距
# ---------------------------------------------------------------------------

func _test_fold_and_guides() -> void:
	_sec("块层级竖线 / 块间距 / 折叠")

	var if_no := _find_line("if flag talked_to_alice")
	_ok(if_no > 0, "找得到 if 块（第 %d 行）" % if_no)
	var inside := _find_line("alice: 分支里的话。")
	_ok(inside == if_no + 1, "块内那一行紧跟在 if 后面（第 %d 行）" % inside)

	# 块内行：有缩进 + 背景微亮（**刻意不画竖线** —— 竖线在块首/块尾会断成折线）
	var st := _row_stylebox(inside)
	_ok(st != null and st.content_margin_left > 4,
		"块内行有缩进（content_margin_left=%d）" % (st.content_margin_left if st else -1))
	_ok(st != null and st.border_width_left == 0,
		"块内行**不画**左侧竖线（实得宽度 %d）" % (st.border_width_left if st else -1))
	_ok(st != null and st.bg_color.a > 0.0,
		"块内行用背景微亮表达嵌套（alpha=%.3f）" % (st.bg_color.a if st else -1.0))

	# 块外的行不该有微亮
	var st_out := _row_stylebox(_find_line("label start"))
	_ok(st_out != null and st_out.bg_color.a == 0.0,
		"块外的行背景是透明的（alpha=%.3f）" % (st_out.bg_color.a if st_out else -1.0))

	# 块首上方留了间距
	var st_if := _row_stylebox(if_no)
	_ok(st_if != null and st_if.content_margin_top > 2,
		"块首上方留了间距（content_margin_top=%d）" % (st_if.content_margin_top if st_if else -1))

	# 折叠
	_ok(_row_visible(inside), "折叠前块内行可见")
	_tbl._toggle_fold(if_no)
	await _wait(0.3)
	_ok(not _row_visible(inside), "折叠后块内行不可见")
	_ok(_row_visible(if_no), "块首那一行仍然可见")
	var btn := _tbl._row_by_no[if_no].get_meta("fold_btn", null) as Button
	_ok(btn != null and btn.text == "▸", "折叠钮变成 ▸")

	_tbl._toggle_fold(if_no)
	await _wait(0.3)
	_ok(_row_visible(inside), "展开后块内行又可见了")
	_ok(btn != null and btn.text == "▾", "折叠钮变回 ▾")


# ---------------------------------------------------------------------------
# 多行粘贴
# ---------------------------------------------------------------------------

func _test_paste_multiline() -> void:
	_sec("多行粘贴自动拆行")

	var no := _find_line("alice: 第四句。")
	_ok(no > 0, "找得到锚点行（第 %d 行）" % no)
	_click_row(no)
	await _wait(0.2)
	var n0: int = _ed.doc.line_count()
	_tbl._paste_multiline("第一行台词\n\n第二行台词\nalice: 已经带说话人的一句")
	await _wait(0.5)
	_ok(_ed.doc.line_count() == n0 + 3, "3 行内容拆成 3 行（实得 +%d）"
		% (_ed.doc.line_count() - n0))
	_ok(_ed.doc.text_at(no + 1).contains("第一行台词"), "第 1 行落位正确")
	_ok(_ed.doc.text_at(no + 2).contains("第二行台词"), "空行被跳过，第 2 行落位正确")
	_ok(_ed.doc.text_at(no + 3).begins_with("alice: "),
		"已经带说话人的那行原样保留（实得 %s）" % _ed.doc.text_at(no + 3))


# ---------------------------------------------------------------------------
# 行内错误标记
# ---------------------------------------------------------------------------

func _test_issue_marks() -> void:
	_sec("行内错误标记")

	var no := _find_line("alice: 第四句。")
	_tbl.set_issues({no: [
		{"level": "error", "text": "prologue.gvs：第 5 行 测试用错误"},
		{"level": "warn", "text": "prologue.gvs：第 5 行 测试用提醒"},
	]})
	await _wait(0.3)
	var dot := _issue_dot_of(no)
	_ok(dot != null and dot.text == "●", "这一行出现了色点")
	_ok(dot != null and dot.tooltip_text.contains("测试用错误"),
		"悬停能看到原因（%s）" % (dot.tooltip_text if dot else ""))
	_ok(dot != null and dot.get_theme_color("font_color") == EdTheme.ERR,
		"有 error 时点用错误色")

	var other := _find_line("alice: 收尾。")
	_ok(other > 0, "找得到另一行用于对照（第 %d 行）" % other)
	var other_dot := _issue_dot_of(other)
	_ok(other_dot != null and other_dot.text == "", "没有问题的行不显示色点")

	# 清掉之后要消失
	_tbl.set_issues({})
	await _wait(0.3)
	var dot2 := _issue_dot_of(no)
	_ok(dot2 != null and dot2.text == "", "问题清掉后色点也消失")


# ---------------------------------------------------------------------------
# 数据与辅助
# ---------------------------------------------------------------------------

func _make_text() -> String:
	return "\n".join(PackedStringArray([
		"# 头部注释",
		"label start",
		"bg classroom fade=0.8",
		"alice: 第一句。",
		"bob@smile: 第二句。",
		"alice: 第三句。",
		"alice: 第四句。",
		"show alice expr=normal at=left fade=0.5",
		"flag talked_to_alice",
		"choice",
		"    \"选项一\" -> label_a",
		"    \"选项二\" -> label_b",
		"end",
		"if flag talked_to_alice",
		"    alice: 分支里的话。",
		"end",
		"label label_a",
		"alice: 收尾。",
	])) + "\n"


func _click_row(no: int) -> void:
	var row := _tbl._row_by_no.get(no, null) as Control
	if row == null:
		_ok(false, "找不到第 %d 行的行控件" % no)
		return
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	row.gui_input.emit(ev)
	get_viewport().gui_release_focus()      # 真实点击会把焦点从输入框挪走


func _press(key: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = key
	ev.pressed = true
	_tbl._unhandled_key_input(ev)


## 按「去掉缩进后的行首」找行 —— 块内的行是带缩进的
func _find_line(prefix: String) -> int:
	for i in range(1, _ed.doc.line_count() + 1):
		if _ed.doc.text_at(i).strip_edges().begins_with(prefix):
			return i
	return -1


func _row_selected(no: int) -> bool:
	var st := _row_stylebox(no)
	return st != null and st.bg_color == EdTheme.SEL_BG


func _row_stylebox(no: int) -> StyleBoxFlat:
	var row := _tbl._row_by_no.get(no, null) as Control
	if row == null or not is_instance_valid(row):
		return null
	return row.get_theme_stylebox("panel") as StyleBoxFlat


func _row_visible(no: int) -> bool:
	var row := _tbl._row_by_no.get(no, null) as Control
	return row != null and is_instance_valid(row) and row.visible


## 指令类型那一格现在显示的文字
func _type_text(no: int) -> String:
	var row := _tbl._row_by_no.get(no, null) as Control
	if row == null:
		return ""
	var h := row.get_child(0) as HBoxContainer
	if h == null or h.get_child_count() < 4:
		return ""
	var c := h.get_child(3)
	if c is Button:
		return (c as Button).text.replace(" ▾", "")
	if c is Label:
		return (c as Label).text
	return ""


func _issue_dot_of(no: int) -> Label:
	var row := _tbl._row_by_no.get(no, null) as Control
	if row == null:
		return null
	var h := row.get_child(0) as HBoxContainer
	return h.get_child(1) as Label


func _all_buttons(node: Node) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is Button and not (c is OptionButton) and not (c is CheckButton):
			out.append(c)
		out.append_array(_all_buttons(c))
	return out


func _find_button(node: Node, text: String) -> Button:
	for c in node.get_children():
		if c is Button and not (c is OptionButton) and (c as Button).text == text:
			return c
		var r := _find_button(c, text)
		if r != null:
			return r
	return null


func _find_line_edit(node: Node) -> LineEdit:
	if node == null:
		return null
	if node is LineEdit:
		return node
	for c in node.get_children():
		var r := _find_line_edit(c)
		if r != null:
			return r
	return null


func _parsed_has(op: String) -> bool:
	var r := GvsParser.parse(_ed.doc.to_text(), "t.gvs")
	for c in (r["commands"] as Array):
		if String((c as Dictionary).get("op", "")) == op:
			return true
	return false


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
