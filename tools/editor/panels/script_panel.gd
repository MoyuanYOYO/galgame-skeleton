extends Control

## 源码视图
##
## 用 Godot 内建的 `CodeEdit` 承担编辑（行号、当前行高亮、缩进、选择、
## 内建撤销栈全部现成），只补两件它不管的事：
##
##   1. **语法高亮** —— 通过 `CodeHighlighter` 资源配置，不需要自绘。
##   2. **与文档层同步** —— 击键后**防抖** 300ms 才把全文推回 `ScriptDoc`，
##      期间界面保持流畅。推回后由主控触发重新校验与预览刷新。
##
## 为什么整篇推回而不是逐行 diff：`CodeEdit` 里的文本就是用户看到的文本，
## 整篇推回不会引入任何偏差；而「行分类」对几百行的剧本是微秒级的。
## 真正需要守住的是**不要在这里做格式化** —— 一旦自动整理缩进，
## 作者手写的排版就被改了。

const EdTheme = preload("res://tools/editor/ed_theme.gd")
const LineIndex = preload("res://tools/editor/core/line_index.gd")
const GvsParser = preload("res://scripts/core/gvs_parser.gd")

const SYNC_DELAY := 0.30

signal caret_moved(line_no: int)
signal committed()

var _ed: Control
var _edit: CodeEdit
var _hl: CodeHighlighter
var _timer: Timer
var _syncing := false
var _dirty := false
## 文档被别处（剧本块等）改过，源码视图的内容已经过期
var _stale_from_panel := false


func setup(ed: Control) -> void:
	_ed = ed
	_build()


func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	_hl = CodeHighlighter.new()
	_configure_highlighter()

	_edit = CodeEdit.new()
	_edit.syntax_highlighter = _hl
	# 行号槽。正确属性名是 gutters_zero_pad_line_numbers（不是 gutters_zero_pad），
	# 补零 + 最少 3 位能让行号右对齐，翻页时不会左右跳
	_edit.gutters_draw_line_numbers = true
	_edit.gutters_zero_pad_line_numbers = true
	_edit.gutters_line_numbers_min_digits = 3
	# 块折叠是 CodeEdit 内建的（按缩进折叠）—— 剧本里 if/choice 块本来就缩进，
	# 所以开箱即用，不需要自己实现折叠逻辑
	_edit.line_folding = true
	_edit.gutters_draw_fold_gutter = true
	# GVS 没有成员补全，开着只会弹无用的空框
	_edit.code_completion_enabled = false
	_edit.highlight_current_line = true
	_edit.indent_size = 4
	_edit.indent_use_spaces = true
	_edit.draw_tabs = false
	_edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	_edit.scroll_past_end_of_file = true
	_edit.caret_blink = true
	_edit.minimap_draw = false
	_edit.set_anchors_preset(Control.PRESET_FULL_RECT)

	# 主题
	_edit.add_theme_font_override("font", EdTheme.mono())
	_edit.add_theme_font_size_override("font_size", EdTheme.FS_CODE)
	_edit.add_theme_color_override("font_color", EdTheme.TEXT)
	_edit.add_theme_color_override("font_readonly_color", EdTheme.TEXT_DIM)
	_edit.add_theme_color_override("caret_color", EdTheme.ACCENT)
	_edit.add_theme_color_override("current_line_color", EdTheme.CURLINE_BG)
	_edit.add_theme_color_override("selection_color", EdTheme.SEL_BG)
	_edit.add_theme_color_override("line_number_color", EdTheme.TEXT_FAINT)
	_edit.add_theme_color_override("caret_background_color", Color(0, 0, 0, 0))
	_edit.add_theme_color_override("brace_mismatch_color", EdTheme.ERR)
	_edit.add_theme_stylebox_override("normal", EdTheme.sb(EdTheme.BG, 0, 8, 6))
	_edit.add_theme_stylebox_override("focus", EdTheme.sb(EdTheme.BG, 0, 8, 6))
	_edit.add_theme_constant_override("line_spacing", 3)

	add_child(_edit)

	_edit.text_changed.connect(_on_text_changed)
	_edit.caret_changed.connect(_on_caret_changed)

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = SYNC_DELAY
	_timer.timeout.connect(_flush)
	add_child(_timer)


func _configure_highlighter() -> void:
	_hl.number_color = EdTheme.SYN_NUMBER
	_hl.symbol_color = EdTheme.TEXT_DIM
	_hl.function_color = EdTheme.SYN_KEYWORD
	_hl.member_variable_color = EdTheme.SYN_PARAM

	for kw in GvsParser.KEYWORDS:
		_hl.add_keyword_color(String(kw), EdTheme.SYN_KEYWORD)

	# 字符串：引号区域
	_hl.add_color_region("\"", "\"", EdTheme.SYN_STRING, false)
	_hl.add_color_region("'", "'", EdTheme.SYN_STRING, false)
	# 注释：`#` 到行尾。line_only = true 是关键 ——
	# 否则 `screen_flash color=#ff0000` 的 # 会把后面全吃掉
	_hl.add_color_region("#", "", EdTheme.SYN_COMMENT, true)


## 角色名高亮要在索引扫完之后再挂（角色列表是动态的）
func refresh_speakers(char_ids: PackedStringArray) -> void:
	for cid in char_ids:
		_hl.add_keyword_color(String(cid), EdTheme.SYN_SPEAKER)


## 标签名高亮（每个文件的标签不同，切换文件时重建）
func refresh_labels(labels: PackedStringArray) -> void:
	for name in labels:
		_hl.add_keyword_color(String(name), EdTheme.SYN_LABEL)


# ---------------------------------------------------------------------------
# 装载与同步
# ---------------------------------------------------------------------------

func load_doc() -> void:
	if _ed == null or _ed.doc == null:
		return
	_syncing = true
	_edit.text = _ed.doc.to_text()
	_syncing = false
	_dirty = false
	_stale_from_panel = false
	refresh_labels(_ed.doc.labels())


## 后台同步：全文 + 光标一起对齐，但**不抢焦点、不发 caret_moved**。
##
## 用于「文档被别处（剧本块）改了，源码视图顺手跟上」：
##   - 抢焦点会打断用户正在表格输入框里的键入；
##   - 发 caret_moved 会把主控的 `caret_line` 改写成源码视图的光标行 ——
##     而那个光标刚被 `load_doc()` 重置到第 1 行，于是每在表格里改一次，
##     主控认定的「当前行」就被拽回文件开头（状态条显示第 1 行画面、
##     「+ 添加对白」插到文件开头）。
func sync_from_doc(caret: int) -> void:
	if _ed == null or _ed.doc == null:
		return
	var text: String = _ed.doc.to_text()
	_syncing = true
	# 文本没变就别重设：`CodeEdit.text = ...` 会清空内建撤销栈，
	# 而「源码视图自己敲字 → 防抖提交 → 又同步回来」这条路上文本必然相同。
	if _edit.text != text:
		_edit.text = text
	_edit.set_caret_line(clampi(caret - 1, 0, maxi(0, _edit.get_line_count() - 1)))
	_edit.set_caret_column(0)
	_syncing = false
	_dirty = false
	refresh_labels(_ed.doc.labels())


## 面板改了文档：只打「过期」标记，**先不重设文本**。
##
## 每次改动都整篇重设 CodeEdit 有两个代价：17ms 的全文重解析，
## 以及**清空 CodeEdit 自己的撤销栈**（作者在源码页的 Ctrl+Z 会失效）。
## 所以推迟到切回源码页时再同步 —— 那时用户本来就该看到最新内容。
func mark_dirty_from_panel() -> void:
	_stale_from_panel = true


func is_stale_from_panel() -> bool:
	return _stale_from_panel


## 切回源码页 / 需要时调用：把过期的内容同步过来
func sync_if_stale() -> void:
	if not _stale_from_panel:
		return
	_stale_from_panel = false
	if _ed == null or _ed.doc == null:
		return
	if _edit.text == _ed.doc.to_text():
		# 内容本来就一致（改动其实是源码视图自己产生的）→ 别动光标，
		# 免得把正在输入的插入点拽走
		return
	sync_from_doc(_ed.caret_line)


func _on_text_changed() -> void:
	if _syncing:
		return
	_dirty = true
	_timer.start()


## 把编辑器内容推回文档层
func _flush() -> void:
	if not _dirty or _ed == null or _ed.doc == null:
		return
	_dirty = false
	_ed.doc.set_full_text(_edit.text, false)
	committed.emit()


## 立即提交（切换文件 / 关闭前调用，避免丢掉最后 300ms 的击键）
func flush_now() -> void:
	if _timer != null:
		_timer.stop()
	_flush()


## 程序化改文本 / 改光标期间，光标变化**不是用户操作**，不能当成「用户移动了光标」。
## 否则 `load_doc()` 把光标重置到第 1 行时，会顺手把主控的 caret_line 也改成 1。
func _on_caret_changed() -> void:
	if _syncing:
		return
	caret_moved.emit(current_line())


func current_line() -> int:
	return _edit.get_caret_line() + 1


# ---------------------------------------------------------------------------
# 定位
# ---------------------------------------------------------------------------

## 跳到某一行并高亮，让编辑器滚动到可见
func goto_line(no: int, select_line: bool = true) -> void:
	var idx := clampi(no - 1, 0, maxi(0, _edit.get_line_count() - 1))
	_edit.set_caret_line(idx)
	_edit.set_caret_column(0)
	if select_line:
		_edit.select(idx, 0, idx, _edit.get_line(idx).length())
	_edit.center_viewport_to_caret()
	_edit.grab_focus()
	caret_moved.emit(no)


## 当前选中的行范围（1 基，含两端）
func selection_lines() -> Vector2i:
	if _edit.has_selection():
		var from := _edit.get_selection_from_line() + 1
		var to := _edit.get_selection_to_line() + 1
		return Vector2i(mini(from, to), maxi(from, to))
	var l := current_line()
	return Vector2i(l, l)


func is_dirty() -> bool:
	return _dirty
