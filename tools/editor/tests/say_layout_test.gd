extends Node

## 对白行「版式」下拉的端到端验收
##
## 版式（居中旁白）**不是对白行的参数**，而是文本里的一个 `[center]` 标记 ——
## 所以这个下拉要能从文本里读出它、再写回去。测试走**真实控件**：
## 点下拉项 → 写回剧本 → 行重建 → 再看控件与文本。
##
## 要窗口：
##   godot --path . res://tools/editor/tests/say_layout_test.tscn

const EditorScene = preload("res://tools/editor/editor.tscn")
const TypingTimeline = preload("res://scripts/core/typing_timeline.gd")
const LineIndex = preload("res://tools/editor/core/line_index.gd")

var _ed: Control
var _tbl: Control
var _tmp := "user://__say_layout_test.gvs"
var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 对白行「版式」下拉 验收 ===")

	_write(_tmp, "\n".join([
		"label start",
		"narr 普通旁白。",
		"alice: 角色台词。",
		"narr [mid]别名写法的旁白。",
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

	await _check_items()
	await _check_widths()
	await _check_apply()
	await _check_clear()
	await _check_dialogue_line()
	await _check_alias()
	await _check_speaker_from_narration()

	# 顺手出一张图给用户看
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://captures/editor_say_layout.png")
	print("  （截图已存 user://captures/editor_say_layout.png）")

	_ed.queue_free()
	await _wait(0.3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp))
	_finish()


## 下拉里有「默认」+ 版式清单里的每一项，且默认项被选中
func _check_items() -> void:
	print("-- 下拉项 --")
	var no := _find_line("narr 普通旁白")
	_ok(no > 0, "找得到那一行")
	var opt := _layout_option(no)
	_ok(opt != null, "对白行里有「版式」下拉")
	if opt == null:
		return
	var texts := _option_texts(opt)
	_ok(texts.size() == TypingTimeline.LAYOUT_LABELS.size() + 1,
		"下拉项数 = 1 个「默认」+ %d 个版式（实得 %s）"
		% [TypingTimeline.LAYOUT_LABELS.size(), str(texts)])
	_ok(texts.has("居中"), "有「居中」这一项（实得 %s）" % str(texts))
	_ok(texts[opt.selected] == "默认", "没标记时停在「默认」（实得 %s）" % texts[opt.selected])


## 台词该是这一行最宽的东西 —— 说话人 / 表情 / 版式都收窄了，宽度让给台词。
##
## 断言「比最宽的下拉还宽一倍以上」而不是写死像素：窗口大小、字体、
## 下拉里最长的那个选项都会影响具体数值，写死了迟早变成假失败。
func _check_widths() -> void:
	print("-- 列宽 --")
	var no := _find_line("narr 普通旁白")
	var edit := _text_edit(no)
	_ok(edit != null, "找得到台词输入框")
	if edit == null:
		return
	var sp := _say_control(no, "speaker")
	var ex := _say_control(no, "expr")
	var ly := _say_control(no, "layout")
	_ok(sp != null and ex != null and ly != null, "三个下拉都在")
	if sp == null or ex == null or ly == null:
		return
	var widest := maxf(maxf(sp.size.x, ex.size.x), ly.size.x)
	_ok(edit.size.x > widest * 2.0,
		"台词比最宽的下拉还宽一倍以上（台词 %.0f px vs 最宽下拉 %.0f px）"
		% [edit.size.x, widest])
	_ok(ly.size.x < ex.size.x, "「版式」比「表情」窄（取值更短）：%.0f vs %.0f"
		% [ly.size.x, ex.size.x])


## 选「居中」→ 文本里多出 `[center]`，且运行时的版式判定也跟着变
func _check_apply() -> void:
	print("-- 选「居中」--")
	var no := _find_line("narr 普通旁白")
	var opt := _layout_option(no)
	var idx := _index_of_option(opt, "居中")
	_ok(idx >= 0, "找得到「居中」项")
	opt.item_selected.emit(idx)
	await _wait(0.4)

	var raw: String = _ed.doc.text_at(no)
	_ok(raw == "narr [center]普通旁白。", "标记写进了台词（实得「%s」）" % raw)
	# 语义校验：走的是运行时同一套判定，不是编辑器自己猜的
	# ⚠️ `_ed` 是 untyped 引用，`_ed.doc.line_at()` 推不出类型，必须显式标注
	var line: LineIndex.Line = _ed.doc.line_at(no)
	_ok(TypingTimeline.layout_of(line.text) == TypingTimeline.LAYOUT_CENTER,
		"运行时的版式判定认它（%s）" % TypingTimeline.layout_of(line.text))
	_ok(TypingTimeline.strip(line.text) == "普通旁白。",
		"标记不会漏到画面上（剥完是「%s」）" % TypingTimeline.strip(line.text))
	# 台词输入框里也要看得到标记，否则作者不知道发生了啥
	var edit := _text_edit(no)
	_ok(edit != null and edit.text.contains("[center]"),
		"台词输入框同步显示标记（实得「%s」）" % (edit.text if edit != null else "无"))
	var opt2 := _layout_option(no)
	_ok(_option_texts(opt2)[opt2.selected] == "居中",
		"下拉停在「居中」（实得 %s）" % _option_texts(opt2)[opt2.selected])


## 再选回「默认」→ 标记被去掉
func _check_clear() -> void:
	print("-- 选回「默认」--")
	var no := _find_line("narr")
	var opt := _layout_option(no)
	opt.item_selected.emit(0)
	await _wait(0.4)
	var raw: String = _ed.doc.text_at(no)
	_ok(raw == "narr 普通旁白。", "标记被去掉了（实得「%s」）" % raw)
	_ok(not _text_edit(no).text.contains("["), "台词输入框里也没了标记")


## 角色台词同样能用（`alice: [center]…`）
func _check_dialogue_line() -> void:
	print("-- 角色台词 --")
	var no := _find_line("alice:")
	var opt := _layout_option(no)
	_ok(opt != null, "角色台词行也有「版式」下拉")
	if opt == null:
		return
	opt.item_selected.emit(_index_of_option(opt, "居中"))
	await _wait(0.4)
	var raw: String = _ed.doc.text_at(no)
	_ok(raw == "alice: [center]角色台词。",
		"对白行的前缀（角色名 + 冒号）没被破坏（实得「%s」）" % raw)
	# 说话人没被弄丢
	_ok(_ed.doc.line_at(no).speaker == "alice", "说话人还是 alice")


## 别名写法（`[mid]`）要能识别成同一个版式，并且写回时统一成 `[center]`
func _check_alias() -> void:
	print("-- 别名 --")
	var no := _find_line("narr [mid]")
	_ok(no > 0, "找得到用别名的行")
	var opt := _layout_option(no)
	_ok(_option_texts(opt)[opt.selected] == "居中",
		"别名 [mid] 也认成「居中」（实得 %s）" % _option_texts(opt)[opt.selected])
	# 重新选一次「居中」→ 归一成规范写法
	opt.item_selected.emit(_index_of_option(opt, "居中"))
	await _wait(0.4)
	var raw: String = _ed.doc.text_at(no)
	_ok(raw == "narr [center]别名写法的旁白。",
		"写回时统一成 [center]（实得「%s」）" % raw)


## 旁白行也要能改说话人（用户报的「有些旁白改不了，点了没反应」）。
##
## 根因：`ScriptDoc.set_dialogue_speaker` 以前对**非 DIALOGUE 行**直接 return false，
## 而 `narr 文本` 在 GVS 里是**指令**（DIRECTIVE）—— 于是旁白行点了没反应，
## 新建的行（`角色: 台词`）却好好的，表现就是「有的行行、有的行不行」。
func _check_speaker_from_narration() -> void:
	print("-- 旁白 → 角色 → 旁白 --")
	var no := _find_line("narr 普通旁白")
	_ok(no > 0, "找得到旁白行")
	var opt := _say_control(no, "speaker") as OptionButton
	_ok(opt != null, "旁白行也有说话人下拉")
	if opt == null:
		return
	_ok(_option_texts(opt)[opt.selected] == "（旁白）",
		"旁白行下拉停在「（旁白）」（实得 %s）" % _option_texts(opt)[opt.selected])

	# 改成 alice
	var idx := _index_of_option(opt, "alice")
	_ok(idx >= 0, "下拉里有 alice（%s）" % str(_option_texts(opt)))
	if idx < 0:
		return
	opt.item_selected.emit(idx)
	await _wait(0.4)
	_ok(_ed.doc.text_at(no) == "alice: 普通旁白。",
		"**旁白改成了角色台词**（实得「%s」）" % _ed.doc.text_at(no))

	# 表情下拉这时该解锁（旁白时是禁用的「—」）
	var expr := _say_control(no, "expr") as OptionButton
	_ok(expr != null and not expr.disabled,
		"改成角色之后表情下拉解锁了（disabled=%s）" % (expr.disabled if expr else "无"))

	# 再改回旁白
	var opt2 := _say_control(no, "speaker") as OptionButton
	opt2.item_selected.emit(0)
	await _wait(0.4)
	_ok(_ed.doc.text_at(no) == "narr 普通旁白。",
		"**又改回旁白**（实得「%s」）" % _ed.doc.text_at(no))
	var expr2 := _say_control(no, "expr") as OptionButton
	_ok(expr2 != null and expr2.disabled, "回到旁白后表情下拉又禁用")

	# ⚠️ 反向也要干净：`角色: 台词` → 旁白 → 角色，**不能留下多出来的冒号**。
	# 旧版把说话人清空时写的是 `: 台词`（说话人位空着、冒号还在），
	# 再选回角色就成了 `alice: : 台词` —— 序章里真被写坏过两行。
	# ⚠️ 用 `alice:` 当前缀而不是整句 —— 上面 `_check_dialogue_line` 已经给这一行
	# 加了 `[center]`，整句前缀匹配不上；匹配不到就会拿到 null 控件，
	# 报错还会被吞掉、断言照常往下走（只有日志里有 SCRIPT ERROR）。
	var no2 := _find_line("alice:")
	_ok(no2 > 0, "找得到角色台词那一行（第 %d 行）" % no2)
	var sp2 := _say_control(no2, "speaker") as OptionButton
	_ok(sp2 != null, "拿得到说话人下拉")
	if sp2 == null:
		return
	sp2.item_selected.emit(0)
	await _wait(0.4)
	_ok(_ed.doc.text_at(no2) == "narr [center]角色台词。",
		"角色台词清空说话人 = 变回旁白行（实得「%s」）" % _ed.doc.text_at(no2))
	var sp3 := _say_control(no2, "speaker") as OptionButton
	sp3.item_selected.emit(_index_of_option(sp3, "alice"))
	await _wait(0.4)
	_ok(_ed.doc.text_at(no2) == "alice: [center]角色台词。",
		"再选回角色没有留下多余冒号（实得「%s」）" % _ed.doc.text_at(no2))


# ---------------------------------------------------------------------------
# 辅助：按 `say_field` meta 找控件
# ---------------------------------------------------------------------------

func _row(no: int) -> Control:
	return _tbl._row_by_no.get(no, null) as Control


func _find_meta(node: Node, key: String, value: String) -> Control:
	if node.has_meta(key) and String(node.get_meta(key)) == value:
		return node as Control
	for c in node.get_children():
		var r := _find_meta(c, key, value)
		if r != null:
			return r
	return null


func _say_control(no: int, key: String) -> Control:
	var row := _row(no)
	if row == null:
		return null
	return _find_meta(row, "say_field", key)


func _layout_option(no: int) -> OptionButton:
	var c := _say_control(no, "layout")
	return c as OptionButton if c is OptionButton else null


func _text_edit(no: int) -> LineEdit:
	var row := _row(no)
	if row == null:
		return null
	var c := _find_meta(row, "say_field", "text")
	return c as LineEdit if c is LineEdit else null


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
