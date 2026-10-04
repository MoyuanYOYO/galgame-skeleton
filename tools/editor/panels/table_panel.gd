extends Control

## 剧本块 —— 剧本的结构化编辑器（页面名「剧本块」，旧的「对白表格」）
##
## 每条指令都渲染成对应的编辑控件（背景选背景带缩略图、音乐选曲目、
## 立绘选角色/表情/位置、特效选种类、转场选类型、数字用输入框）。
##
## **保真的做法**：编辑只重写被改动的那一行，其余行原样搬运。
## 参数写回分两种（与 `GvsParser` 的参数模型对应）：
##   位置参数（`show alice`）→ 按「第几个词」替换
##   kv 参数（`fade=0.8`）  → 正则只替换那一个 `key=值`
## 绝不「重新拼整行」—— 那会打乱作者的参数顺序，让 diff 变得难读。
##
## ---------------------------------------------------------------------------
## 四条关键设计（改动前必读）
## ---------------------------------------------------------------------------
##
## 1. **表格有自己的「当前行」**（`_current_no`），不借源码视图的 `caret_line`。
##    后者属于源码视图：在表格页它只是历史残留，而且会被后台同步重置成 1。
##    详见 `Editor._on_caret_moved` / `Editor.set_caret_from_panel`。
##
## 2. **行控件持有「行号 + 建它时的原文」，都放在节点 meta 里**，
##    所有回调通过 `_no_of(row)` / `_stale_row(row)` **现取**，不捕获具体数字。
##    这样插入/删除之后只要改一下 meta（`_rebind_after_insert`），
##    不用重建任何已有行 —— 这是「加一行不再全表重画」的前提。
##
## 3. **重建走「离屏组装 → 一次性换掉 `_body`」**。
##    逐行 `add_child` 进一个挂在 ScrollContainer 里的容器，每次都会触发
##    「最小尺寸 → 滚动条」的整条链重算，实测 247 行要 322ms（O(n²)）；
##    离屏装满再一次性挂上去只要 ~1ms。**不要改回逐个 add_child。**
##
## 4. **滚动分两种意图**：`_scroll_to_line(no, pin)`。插入/删除用最小滚动
##    （只在目标行不在视口里时才滚）；只有「明确导航到某一行」才置顶。
##
## 结构行（label / jump / if / choice / end）刻意不给类型下拉、删除要确认：
## 删掉一个 `end` 会让后面整段落进块里，后果隐蔽。

const EdTheme = preload("res://tools/editor/ed_theme.gd")
const LineIndex = preload("res://tools/editor/core/line_index.gd")
const OpSpec = preload("res://tools/editor/core/op_spec.gd")

const W_NO := 40
const W_DOT := 12
const W_FOLD := 18
const W_TAG := 76
const W_FIELD := 118
const W_NUM := 74
const W_TEXT := 96
const ROW_H := 30
const THUMB := 18
const INDENT_PER_DEPTH := 14
const BLOCK_GAP := 7          ## 块首上方 / 块尾下方额外留的间距

## 块层级的表达：**用背景微亮，不画竖线**。
##
## 竖线的问题：块首（`if` / `choice`）自己不在块里、没有线，块尾 `end` 也不在，
## 所以线天然是「断成几截」的 —— 看着就是一条难看的折线。
## 改成按嵌套深度给背景加一点点白：越深越亮，一眼看出范围，又没有硬边。
const DEPTH_TINTS := [0.035, 0.060, 0.080, 0.095]

## 会改变块结构的关键字：插入/删除它们之后缩进与竖线会整体变化
const BLOCKY := ["if", "elif", "else", "end", "choice", "together"]


var _ed: Control
var _body: VBoxContainer
var _scroll: ScrollContainer
var _stat: Label
var _search: LineEdit
var _state_bar: HBoxContainer
## 默认**不显示**空行与注释 —— 剧本里空行很多（分隔用），
## 一上来就铺满会让「有内容的行」被稀释。要看的时候点工具栏的开关。
var _show_structure := false

var _rebuilding := false
var _thumb_cache: Dictionary = {}
## 原图缓存（path → Image）：同一张图被不同尺寸请求时只解码一次
var _src_cache: Dictionary = {}
var _type_menu: PopupMenu
var _confirm: ConfirmationDialog
var _pending_delete := 0
var _find_bar: PanelContainer
var _find_input: LineEdit
var _find_info: Label
var _find_hits: Array = []

## 上一次画在状态条上的累积状态。
## 状态没变就不重建那条 —— 实测它曾经是「点一下行」里最贵的一步（134ms）。
var _last_state: Dictionary = {}

## 表格自己的「当前行」（1 基；0 = 还没指定）
var _current_no := 0
## 行号 → 行控件（外层 PanelContainer）。重建时填，增量增删时维护。
var _row_by_no: Dictionary = {}
## 折叠起来的块（块起始行号 → true）
var _folded: Dictionary = {}
## 行号 → [{level, text}]（静态审计的结果，由主控推过来）
var _issues: Dictionary = {}
## 行号 → 基本块序号（1 起）。只有「领导点」才在表里，见 `_recompute_blocks`
var _block_of: Dictionary = {}
var _show_blocks := true
## 跨文件跳转的目标存在性缓存（"路径#标签" → bool）
var _label_exists_cache: Dictionary = {}


func setup(ed: Control) -> void:
	_ed = ed
	_build()


func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# --- 工具条 ---
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_PANEL, 0, 10, 6, EdTheme.BORDER, 1))
	root.add_child(bar)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	bar.add_child(h)

	_stat = EdTheme.label("", EdTheme.FS_SMALL, EdTheme.TEXT_DIM)
	h.add_child(_stat)
	h.add_child(EdTheme.hfill())

	_search = LineEdit.new()
	_search.placeholder_text = "过滤台词 / 角色 / 素材 id…"
	_search.custom_minimum_size = Vector2(220, 0)
	EdTheme.style_line_edit(_search)
	_search.text_changed.connect(func(_t: String) -> void: _apply_visibility())
	h.add_child(_search)

	var btn_struct := EdTheme.chip("显示注释与空行")
	btn_struct.toggle_mode = true
	btn_struct.button_pressed = _show_structure
	btn_struct.toggled.connect(func(on: bool) -> void:
		_show_structure = on
		_apply_visibility())
	h.add_child(btn_struct)

	var btn_add := EdTheme.chip("+ 添加对白")
	btn_add.tooltip_text = "在当前行之后插入一条对白（快捷键 Enter）"
	btn_add.pressed.connect(func() -> void: _insert_after_current("__say"))
	h.add_child(btn_add)

	var btn_fold := EdTheme.chip("全部展开")
	btn_fold.tooltip_text = "展开所有被折叠的 if / choice 块"
	btn_fold.pressed.connect(func() -> void:
		if _folded.is_empty():
			return
		_folded.clear()
		_apply_visibility()
		_refresh_fold_buttons())
	h.add_child(btn_fold)

	var btn_blk := EdTheme.chip("基本块分隔")
	btn_blk.tooltip_text = "按「领导点」把剧本切成基本块，块之间画分隔线"
	btn_blk.toggle_mode = true
	btn_blk.button_pressed = _show_blocks
	btn_blk.toggled.connect(func(on: bool) -> void:
		_show_blocks = on
		_restyle_all())
	h.add_child(btn_blk)

	# --- 查找条（Ctrl+F 才出现）---
	#
	# 与上面那个「过滤」输入框是两件事：
	#   过滤 = 只让命中的台词留下（改的是**可见性**）
	#   查找 = 不动可见性，逐条跳过去（改的是**当前行**）
	# 混在一起的话，作者想看上下文就做不到 —— 过滤会把它藏掉。
	_find_bar = PanelContainer.new()
	_find_bar.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_ELEV, 0, 10, 6, EdTheme.BORDER_HI, 1))
	_find_bar.visible = false
	root.add_child(_find_bar)

	var fh := HBoxContainer.new()
	fh.add_theme_constant_override("separation", 8)
	_find_bar.add_child(fh)

	fh.add_child(EdTheme.label("查找", EdTheme.FS_SMALL, EdTheme.ACCENT))

	_find_input = LineEdit.new()
	_find_input.placeholder_text = "在当前剧本里查找（回车下一处）"
	_find_input.custom_minimum_size = Vector2(260, 0)
	_find_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	EdTheme.style_line_edit(_find_input)
	_find_input.text_changed.connect(func(_t: String) -> void: _refresh_find(true))
	_find_input.text_submitted.connect(func(_t: String) -> void: _step_find(1))
	fh.add_child(_find_input)

	_find_info = EdTheme.label("", EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	_find_info.custom_minimum_size = Vector2(96, 0)
	fh.add_child(_find_info)

	var btn_prev := EdTheme.chip("↑ 上一处")
	btn_prev.pressed.connect(func() -> void: _step_find(-1))
	fh.add_child(btn_prev)

	var btn_next := EdTheme.chip("↓ 下一处")
	btn_next.pressed.connect(func() -> void: _step_find(1))
	fh.add_child(btn_next)

	var btn_close := EdTheme.chip("✕")
	btn_close.tooltip_text = "关闭查找条（Esc）"
	btn_close.pressed.connect(close_find)
	fh.add_child(btn_close)

	# --- 场景状态条 ---
	var state_panel := PanelContainer.new()
	state_panel.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_ELEV, 0, 10, 6, EdTheme.BORDER, 1))
	root.add_child(state_panel)

	_state_bar = HBoxContainer.new()
	_state_bar.add_theme_constant_override("separation", 14)
	state_panel.add_child(_state_bar)

	# --- 表头 ---
	var head := PanelContainer.new()
	head.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_PANEL, 0, 0, 0, EdTheme.BORDER, 1))
	root.add_child(head)

	var head_row := HBoxContainer.new()
	head_row.add_theme_constant_override("separation", 4)
	head.add_child(head_row)
	head_row.add_child(_header("行", W_NO))
	head_row.add_child(_header("", W_DOT))
	head_row.add_child(_header("", W_FOLD))
	head_row.add_child(_header("指令", W_TAG))
	head_row.add_child(_header("参数（可直接改）", 0, true))

	# --- 表体 ---
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_scroll)

	_body = _make_body()
	_scroll.add_child(_body)

	# 类型下拉（所有非结构行共用这一个菜单，避免每行建一个 PopupMenu）
	_type_menu = PopupMenu.new()
	_type_menu.add_theme_font_override("font", EdTheme.ui())
	_type_menu.add_theme_font_size_override("font_size", EdTheme.FS_UI)
	_type_menu.add_theme_color_override("font_color", EdTheme.TEXT)
	_type_menu.add_theme_color_override("font_hover_color", Color.WHITE)
	_type_menu.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_ELEV, 6, 4, 4, EdTheme.BORDER_HI, 1))
	_type_menu.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.SEL_BG, 4, 4, 3))
	_type_menu.index_pressed.connect(_on_type_index)
	add_child(_type_menu)

	# 删除确认（结构行用）
	_confirm = ConfirmationDialog.new()
	_confirm.title = "确认删除"
	_confirm.ok_button_text = "删除"
	_confirm.cancel_button_text = "取消"
	_confirm.confirmed.connect(_do_pending_delete)
	add_child(_confirm)


func _make_body() -> VBoxContainer:
	var b := VBoxContainer.new()
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_constant_override("separation", 0)
	return b


func _header(text: String, width: int, expand: bool = false) -> Control:
	var l := EdTheme.label(text, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	if width > 0:
		l.custom_minimum_size = Vector2(width, 0)
	if expand:
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size.y = 24
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func on_shown() -> void:
	# 表格有自己的「当前行」：第一次显示时从主控的光标借一次做初值，
	# 之后就只跟着表格里的操作走。
	if _current_no <= 0:
		_current_no = clampi(_ed.caret_line, 1, maxi(1, _ed.doc.line_count()))
	if _is_built():
		# 文档没变过 → 行控件还是对的。只把可见性 / 高亮 / 状态条对齐，
		# 几毫秒的事；重建整表要 500ms 上下，切页时白等很亏。
		_apply_visibility()
		_restyle_all()
		_refresh_state_bar()
		return
	rebuild()


## 主控切到表格页时会推来「源码视图的行号」—— 滚到那一行，并把它当成当前行
func goto_line(no: int) -> void:
	if _ed == null or _ed.doc == null:
		return
	_current_no = clampi(no, 1, maxi(1, _ed.doc.line_count()))
	_restyle_current()
	_refresh_state_bar()
	_scroll_to_line(_current_no, true)      # 明确「去那一行」→ 置顶最直观


# ---------------------------------------------------------------------------
# 查找（Ctrl+F）
# ---------------------------------------------------------------------------

## 打开查找条并聚焦输入框。由主控的 Ctrl+F 调。
func open_find() -> void:
	if _find_bar == null:
		return
	_find_bar.visible = true
	_find_input.call_deferred("grab_focus")
	_find_input.select_all()
	if not _find_input.text.strip_edges().is_empty():
		_refresh_find(true)
	else:
		_refresh_find(false)


func close_find() -> void:
	if _find_bar == null:
		return
	_find_bar.visible = false
	_find_hits = []


func is_find_open() -> bool:
	return _find_bar != null and _find_bar.visible


## 命中行：**只看当前显示的行**（折叠块里、被隐藏的注释不参与）。
##
## 为什么不做「连隐藏行一起搜」：找到了也跳不过去 —— `goto_line` 落到隐藏行时
## 会退到最近的可见行，于是高亮停在别的行上，比搜不到更让人困惑。
## 要搜注释就打开「显示注释与空行」，要搜折叠块内容就先展开。
func _compute_find_hits() -> Array:
	var out: Array = []
	if _ed == null or _ed.doc == null or _find_input == null:
		return out
	var q := _find_input.text.strip_edges().to_lower()
	if q.is_empty():
		return out
	for no in _row_by_no.keys():
		var n := int(no)
		var line := _ed.doc.line_at(n) as LineIndex.Line
		if line == null or not _should_show(line):
			continue
		if line.raw.to_lower().contains(q):
			out.append(n)
	out.sort()
	return out


func _refresh_find(jump: bool) -> void:
	if _find_bar == null or not _find_bar.visible:
		return
	_find_hits = _compute_find_hits()
	if _find_hits.is_empty():
		_find_info.text = "没有命中" if not _find_input.text.strip_edges().is_empty() else ""
		_find_info.add_theme_color_override("font_color", EdTheme.WARN)
		return
	if jump:
		_step_find(1)
	else:
		_update_find_info()


## 往 dir 方向找下一处，到头环回
func _step_find(dir: int) -> void:
	if _find_bar == null or not _find_bar.visible:
		return
	if _find_hits.is_empty():
		_refresh_find(false)
		if _find_hits.is_empty():
			return
	var target := -1
	if dir > 0:
		for n in _find_hits:
			if int(n) > _current_no:
				target = int(n)
				break
		if target < 0:
			target = int(_find_hits[0])
	else:
		for i in range(_find_hits.size() - 1, -1, -1):
			if int(_find_hits[i]) < _current_no:
				target = int(_find_hits[i])
				break
		if target < 0:
			target = int(_find_hits[_find_hits.size() - 1])
	goto_line(target)
	_update_find_info()


func _update_find_info() -> void:
	if _find_bar == null or not _find_bar.visible:
		return
	if _find_hits.is_empty():
		_find_info.text = ""
		return
	var idx := _find_hits.find(_current_no)
	if idx >= 0:
		_find_info.text = "第 %d / %d 处" % [idx + 1, _find_hits.size()]
		_find_info.add_theme_color_override("font_color", EdTheme.OK)
	else:
		_find_info.text = "%d 处命中" % _find_hits.size()
		_find_info.add_theme_color_override("font_color", EdTheme.TEXT_FAINT)


## 静态审计的结果（主控推过来）。
##
## 只更新**内容真的变了的那几行**的色点 —— 全量刷 247 个 Label
## 每次都要重算最小尺寸，是纯粹的浪费。
func set_issues(issues: Dictionary) -> void:
	var touched := {}
	for no in issues.keys():
		if not _same_issues(_issues.get(no, []), issues[no]):
			touched[int(no)] = true
	for no in _issues.keys():
		if not issues.has(no):
			touched[int(no)] = true
	_issues = issues
	for no in touched.keys():
		var row := _row_by_no.get(no, null) as Control
		if row != null and is_instance_valid(row):
			_apply_issue_mark(row, int(no))


static func _same_issues(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if String((a[i] as Dictionary).get("level", "")) \
				!= String((b[i] as Dictionary).get("level", "")):
			return false
		if String((a[i] as Dictionary).get("text", "")) \
				!= String((b[i] as Dictionary).get("text", "")):
			return false
	return true


# ---------------------------------------------------------------------------
# 重建
# ---------------------------------------------------------------------------

## 表体当前对应的文档版本号。与 `doc.revision` 一致时说明行控件还是对的，
## 切回本页不需要重建（`on_shown` 靠它跳过 500ms 的重建）。
var _built_revision := -1


func rebuild() -> void:
	if _ed == null or _ed.doc == null or _body == null:
		return
	_rebuilding = true

	var keep := _scroll.scroll_vertical
	var lines: Array = _ed.doc.lines
	_recompute_blocks()          # 建行之前先算好，行样式与提示要用

	# **离屏组装**：新的 VBoxContainer 先不挂进树，装满了再一次性换上去。
	# 逐个 add_child 进树里的容器会反复触发「最小尺寸 → 滚动条」重算。
	var fresh := _make_body()
	_row_by_no.clear()

	for i in lines.size():
		var line := lines[i] as LineIndex.Line
		var row := _build_row(line)
		fresh.add_child(row)
		_row_by_no[line.no] = row

	_scroll.remove_child(_body)
	_body.queue_free()
	_body = fresh
	_scroll.add_child(_body)

	_current_no = clampi(_current_no, 1, maxi(1, lines.size()))
	_rebuilding = false
	_scroll.scroll_vertical = keep
	# 新行都是按当时的 `_current_no` 造出来的（`_row_base` 里就带上了选中态），
	# 所以这里**不要再刷一遍** —— 那会白跑 247 次 theme override。
	_mark_styled()
	_apply_visibility()
	_built_revision = _ed.doc.revision
	_refresh_state_bar()


## 按「该不该显示」刷 `visible`。
##
## **行控件常驻**，过滤 / 折叠 / 隐藏注释都只切 `visible` ——
## 这样它们不再需要重建整表（重建 247 行要 500ms 上下）。
## 容器会跳过不可见的子节点，所以不显示的行使布局上就等于不存在。
func _apply_visibility() -> void:
	if _ed == null or _ed.doc == null:
		return
	var shown := 0
	var says := 0
	for no in _row_by_no.keys():
		var row := _row_by_no[no] as Control
		if row == null or not is_instance_valid(row):
			continue
		var line := _ed.doc.line_at(int(no)) as LineIndex.Line
		if line == null:
			continue
		if line.is_say():
			says += 1
		var vis := _should_show(line)
		# **只在真的变了才赋值**：`visible = x` 会让容器重算最小尺寸并排队重排，
		# 247 行每次都赋一遍是纯粹的浪费。
		if row.visible != vis:
			row.visible = vis
		if vis:
			shown += 1
	_stat.text = "%d 句台词 · 显示 %d 行" % [says, shown]
	# 可见性变了 → 查找的命中集合也跟着变（它只认显示中的行）
	_refresh_find(false)


## 重刷所有行的样式（块层级缩进 / 竖线 / 基本块分隔 / 选中态）。
## 单行两次 theme override 约 2µs，247 行也就 0.5ms —— 便宜到可以随便调。
func _restyle_all() -> void:
	if _ed == null or _ed.doc == null:
		return
	_recompute_blocks()
	for no in _row_by_no.keys():
		var n := int(no)
		var row := _row_by_no[no] as Control
		if row == null or not is_instance_valid(row):
			continue
		var line := _ed.doc.line_at(n) as LineIndex.Line
		if line == null:
			continue
		(row as PanelContainer).add_theme_stylebox_override(
			"panel", _row_style(line, n == _current_no))
		var b := row.get_meta("no_btn", null) as Button
		if b != null and is_instance_valid(b):
			b.add_theme_color_override("font_color",
				EdTheme.ACCENT if n == _current_no else EdTheme.TEXT_FAINT)
			b.tooltip_text = _no_btn_tip(n)
	_mark_styled()


## 基本块划分 —— 编译原理意义上的「领导点」（leader）：
##
##   1. 文件首行
##   2. 每个 `label` 行（跳转到达行）
##   3. 跳转 / 结束类指令的**下一行**（`jump` `goto` `jump_file` `return` `ending`）
##   4. 块开闭的**下一行**（`if` `elif` `else` `choice` `end`）
##
## 结果 `_block_of`：行号 → 块序号（1 起）。只有领导点才在里面。
## 界面据此在块首上方画一条分隔线（见 `_row_style`）。
func _recompute_blocks() -> void:
	_block_of.clear()
	if _ed == null or _ed.doc == null:
		return
	var lines: Array = _ed.doc.lines
	var n := lines.size()
	if n == 0:
		return
	var leaders: Dictionary = {1: true}
	for i in n:
		var l := lines[i] as LineIndex.Line
		var nxt := l.no + 1
		if nxt > n:
			continue
		if l.kind == LineIndex.Line.LABEL:
			leaders[l.no] = true
		elif l.kind == LineIndex.Line.DIRECTIVE:
			match l.head:
				"jump", "goto", "jump_file", "return", "ending", \
				"if", "elif", "else", "choice", "end":
					leaders[nxt] = true
	var idx := 0
	for no in range(1, n + 1):
		if leaders.has(no):
			idx += 1
			_block_of[no] = idx


func _no_btn_tip(no: int) -> String:
	var tip := "跳到源码第 %d 行" % no
	if _show_blocks and _block_of.has(no):
		tip += " · 基本块 %d" % int(_block_of[no])
	return tip


## 表格的行控件与文档是否已经对齐
## 素材索引变了（导入 / 改名 / 删除 / 新建角色）→ 让下次显示时**整表重建**。
##
## 为什么必须重建：行控件是**常驻**的，素材下拉的选项在**建行那一刻**就定死了
## （`_asset_field` 读 `index.ids(kind)`、`_expr_field` 读该角色的表情表）。
## 不重建的话，新导入的素材不会出现在旧行的下拉里 —— 只有新插入的行才有
## （用户报的「原来的行没有新素材的选项，只有新添加的行有」）。
##
## 代价是下一次切到剧本块要 500ms 重建，但导入素材本来就是个低频动作。
func invalidate_assets() -> void:
	_built_revision = -1
	_thumb_cache.clear()
	_src_cache.clear()


func _is_built() -> bool:
	return _built_revision == _ed.doc.revision and _body.get_child_count() > 0


func _mark_built() -> void:
	if _ed != null and _ed.doc != null:
		_built_revision = _ed.doc.revision


## 这一行现在该不该出现在表体里（过滤 / 显示注释 / 折叠都在这判定）
func _should_show(line: LineIndex.Line) -> bool:
	if _hidden_by_fold(line):
		return false
	if line.kind == LineIndex.Line.BLANK or line.kind == LineIndex.Line.COMMENT:
		return _show_structure
	if line.is_say():
		return _match(line, _search.text.strip_edges().to_lower())
	return true


## 这一行是否被某个折叠起来的块盖住（块内部，含 `end` 本身）
func _hidden_by_fold(line: LineIndex.Line) -> bool:
	if _folded.is_empty() or line.depth <= 0:
		return false
	for b in _ed.doc.blocks:
		var blk := b as LineIndex.Block
		var end_no: int = blk.end_line if blk.end_line > 0 else _ed.doc.line_count() + 1
		if line.no > blk.start_line and line.no <= end_no and _folded.has(blk.start_line):
			return true
	return false


func _build_row(line: LineIndex.Line) -> Control:
	var row: PanelContainer
	if line.kind == LineIndex.Line.BLANK or line.kind == LineIndex.Line.COMMENT:
		row = _plain_row(line)
	elif line.is_say():
		row = _say_row(line)
	elif line.kind == LineIndex.Line.CHOICE_OPTION:
		row = _option_row(line)
	elif line.kind == LineIndex.Line.LABEL:
		row = _label_row(line)
	elif line.kind == LineIndex.Line.DIRECTIVE:
		# 结构指令：**有规格的**（jump / call / jump_file）渲染成可视行 ——
		# 只读原文的话，跳转目标就没法点。没规格的（label / if / choice / end）
		# 还是只读原文行。
		if OpSpec.is_structural(line.head) and OpSpec.get_spec(line.head).is_empty():
			row = _structural_row(line)
		else:
			row = _directive_row(line)
	else:
		row = _structural_row(line)

	row.set_meta("line_no", line.no)
	row.set_meta("raw", line.raw)
	_hook_row(row)
	return row


func _match(line: LineIndex.Line, filter: String) -> bool:
	if filter.is_empty():
		return true
	if line.text.to_lower().contains(filter):
		return true
	if line.speaker.to_lower().contains(filter):
		return true
	if line.head.to_lower().contains(filter):
		return true
	for a in line.args:
		if String(a).to_lower().contains(filter):
			return true
	return false


# ---------------------------------------------------------------------------
# 增量增删（不重建已有行）
# ---------------------------------------------------------------------------

## 行号存 meta，回调现取 —— 所以插入后只要把插入点之后的编号整体后移。
##
## ⚠️ **meta 改了还不够，行号按钮上显示的数字也要改** ——
## 只改 meta 的话，下面那些行的编号还是旧的（用户看到的就是
## 「插了一行之后，下方的行数不会更新」）。
## 这一步不贵：`Button.text` 只在文本宽度超过 `custom_minimum_size` 时才影响
## 最小尺寸，而 `W_NO` 够宽，所以不会引发容器重排。
func _rebind_after_insert(at: int, count: int) -> void:
	var shifted := {}
	for no in _row_by_no.keys():
		var n := int(no)
		var row := _row_by_no[no] as Control
		if n > at:
			n += count
			row.set_meta("line_no", n)
			_renumber(row, n)
		shifted[n] = row
	_row_by_no = shifted


func _rebind_after_delete(no: int) -> void:
	var shifted := {}
	for k in _row_by_no.keys():
		var n := int(k)
		var row := _row_by_no[k] as Control
		if n > no:
			n -= 1
			row.set_meta("line_no", n)
			_renumber(row, n)
		shifted[n] = row
	_row_by_no = shifted


## 把行号按钮上的数字改成新的（tooltip 由 `_restyle_all` 统一刷）
func _renumber(row: Control, no: int) -> void:
	var b := row.get_meta("no_btn", null) as Button
	if b != null and is_instance_valid(b):
		b.text = str(no)


## 插入 count 行之后把新行加进表体（其余行一律不动）。
##
## 插完统一重刷一遍样式：基本块分隔是按**行号**算的，插入/删除会让
## 后面所有领导点的行号位移，不重算就会画错地方。重刷 247 行约 0.5ms。
func _sync_after_insert(at: int, count: int) -> void:
	_rebind_after_insert(at, count)
	_recompute_blocks()
	var anchor := _row_by_no.get(at, null) as Control
	var pos := _body.get_child_count()
	if anchor != null and is_instance_valid(anchor):
		pos = anchor.get_index() + 1
	for k in count:
		var no := at + 1 + k
		var line := _ed.doc.line_at(no) as LineIndex.Line
		if line == null:
			continue
		var row := _build_row(line)
		_body.add_child(row)
		_body.move_child(row, pos)
		_row_by_no[no] = row
		pos += 1
	_restyle_all()
	_apply_visibility()
	_mark_built()


func _sync_after_delete(no: int) -> void:
	var row := _row_by_no.get(no, null) as Control
	if row != null and is_instance_valid(row):
		_body.remove_child(row)
		row.queue_free()
		_row_by_no.erase(no)
	_rebind_after_delete(no)
	_restyle_all()
	_apply_visibility()
	_mark_built()


## 只重建某一行（行数没变的场景：改说话人 / 表情 / 参数 / 转换类型）。
func _refresh_row(no: int) -> void:
	var old := _row_by_no.get(no, null) as Control
	if old == null or not is_instance_valid(old):
		return
	var line := _ed.doc.line_at(no) as LineIndex.Line
	if line == null:
		return
	var idx := old.get_index()
	var fresh := _build_row(line)
	_body.add_child(fresh)
	_body.move_child(fresh, idx)
	_body.remove_child(old)
	old.queue_free()
	_row_by_no[no] = fresh
	fresh.visible = _should_show(line)
	_apply_issue_mark(fresh, no)
	_restyle_all()
	_mark_built()


## 折叠 / 展开：只切可见性，**不重建任何行控件**
func _toggle_fold(no: int) -> void:
	if _folded.has(no):
		_folded.erase(no)
	else:
		_folded[no] = true
	_apply_visibility()
	_refresh_fold_buttons()


func _refresh_fold_buttons() -> void:
	for no in _row_by_no.keys():
		var row := _row_by_no[no] as Control
		if row == null or not is_instance_valid(row):
			continue
		var b := row.get_meta("fold_btn", null) as Button
		if b == null or not is_instance_valid(b):
			continue
		b.text = "▸" if _folded.has(int(no)) else "▾"


## 这次改动有没有动到块结构（动了就得全量重建：缩进与竖线要整体重算）
func _touches_blocks(heads: PackedStringArray) -> bool:
	for h in heads:
		if BLOCKY.has(h):
			return true
	return false


static func _head_of_raw(raw: String) -> String:
	var code := raw.strip_edges()
	var sp := code.find(" ")
	return code if sp < 0 else code.substr(0, sp)


# ---------------------------------------------------------------------------
# 当前行 / 选中
# ---------------------------------------------------------------------------

func _no_of(row: Control) -> int:
	if row == null or not is_instance_valid(row):
		return 0
	return int(row.get_meta("line_no", 0))


func _row_line(row: Control) -> LineIndex.Line:
	var no := _no_of(row)
	if no <= 0 or _ed == null or _ed.doc == null:
		return null
	return _ed.doc.line_at(no) as LineIndex.Line


## 写入前校验：目标行是否还是控件创建时的那一行。
##
## 控件持有「创建时的行号 + 原文」。若这期间文档被增删过（行号整体位移），
## 拿着旧行号去写就会改到**别的行** —— 而且写进去的是「另一条指令的参数」，
## 既不报错、也不影响解析，剧本却已经悄悄变样。属于最隐蔽的一类损坏，
## 所以每次写之前都拿原文比一次，不一致就放弃并重建界面。
func _stale_row(row: Control) -> bool:
	var line := _row_line(row)
	if line == null:
		return true
	return line.raw != String(row.get_meta("raw", ""))


## 行内任何交互都把它记成当前行
func _touch_row(row: Control) -> void:
	if _rebuilding or _ed == null or _ed.doc == null:
		return
	var no := _no_of(row)
	if no > 0 and no != _current_no:
		_set_current(no)


func _set_current(no: int, notify: bool = true) -> void:
	if _ed == null or _ed.doc == null:
		return
	_current_no = clampi(no, 1, maxi(1, _ed.doc.line_count()))
	_restyle_current()
	_refresh_state_bar()
	if notify:
		_ed.set_caret_from_panel(_current_no)


## 当前行高亮：整行底色 + 行号强调色。
## 没有它，用户看不出 Enter / 退格会作用在哪一行。
##
## **只刷「状态变了的那两行」。**
## 给每一行都 `add_theme_*_override` 会触发该行**整棵子树**的 THEME_CHANGED 传播，
## 247 行就是几百毫秒 —— 实测这一条曾让「加一行」从 5ms 变成 164ms。
## 所以这里记住上一次刷过的行号，只处理差异。
var _styled_no := 0


func _restyle_current() -> void:
	if _ed == null or _ed.doc == null:
		return
	if _styled_no == _current_no:
		return
	_style_row(_styled_no, false)
	_style_row(_current_no, true)
	_styled_no = _current_no


func _style_row(no: int, selected: bool) -> void:
	if no <= 0:
		return
	var row := _row_by_no.get(no, null) as PanelContainer
	if row == null or not is_instance_valid(row):
		return
	var line := _ed.doc.line_at(no) as LineIndex.Line
	if line == null:
		return
	row.add_theme_stylebox_override("panel", _row_style(line, selected))
	var b := row.get_meta("no_btn", null) as Button
	if b != null and is_instance_valid(b):
		b.add_theme_color_override("font_color",
			EdTheme.ACCENT if selected else EdTheme.TEXT_FAINT)


## 重建之后所有行都是按当时的 `_current_no` 造出来的，不用再刷一遍
func _mark_styled() -> void:
	_styled_no = _current_no


## 键盘 / 工具栏操作的落点 —— **永远是「当前行」**。
##
## ⚠️ 这里曾经加过一条「当前行不在视口里时，改落到视口顶端那一行」的规则，
## 那是**错的**：落点是「用户上一次工作的地方」，替他改掉就等于把内容
## 写到别处去 —— 用户看到的是「新行冒到最顶上去了」，而且他完全不知道为什么。
##
## 要解决的是**视图不要被拽走**，那在 `_scroll_to_line` 里治：
## 插入 / 删除只向下滚、不向上滚（见那里的注释）。
func _anchor_no() -> int:
	if _ed == null or _ed.doc == null:
		return 1
	return clampi(_current_no, 1, maxi(1, _ed.doc.line_count()))


## 这一行现在是不是真的在视口里（不可见算不在）
func _row_in_view(no: int) -> bool:
	var row := _row_by_no.get(no, null) as Control
	if row == null or not is_instance_valid(row) or not row.visible:
		return false
	if row.size.y <= 0.0:
		return true          # 还没布局好的行量不出位置，别当成「不在视口里」
	var top := float(row.position.y)
	var vt := float(_scroll.scroll_vertical)
	return top + row.size.y > vt and top < vt + float(_scroll.size.y)


## 视口里最靠上的那一行；一行都量不到时返回 0（调用方要能分辨）
func _top_visible_no() -> int:
	var y := float(_scroll.scroll_vertical)
	var best := 0
	var best_y := INF
	for no in _row_by_no.keys():
		var row := _row_by_no[no] as Control
		if row == null or not is_instance_valid(row) or not row.visible:
			continue
		if row.size.y <= 0.0:
			continue             # 还没布局好，位置是假的
		var top := float(row.position.y)
		if top + row.size.y <= y:
			continue             # 整个在视口上方
		if top < best_y:
			best_y = top
			best = int(no)
	return best


## 从 no 出发朝 dir 方向找第一个可见的行（找不到就原样返回）。
## 用于「删掉一行之后把选中落到上一行」——上一行可能是个默认隐藏的空行。
func _nearest_visible(no: int, dir: int) -> int:
	if _ed == null or _ed.doc == null:
		return no
	var n := clampi(no, 1, maxi(1, _ed.doc.line_count()))
	for _i in _ed.doc.line_count():
		var row := _row_by_no.get(n, null) as Control
		if row != null and is_instance_valid(row) and row.visible:
			return n
		n += dir
		if n < 1 or n > _ed.doc.line_count():
			break
	return no


## 上下移动选中行（跳过当前不显示的行：被过滤或被折叠）
func _move_selection(delta: int) -> void:
	var lines: Array = _ed.doc.lines
	if lines.is_empty():
		return
	var no := _current_no
	for _i in lines.size():
		no += delta
		if no < 1 or no > lines.size():
			return
		var row := _row_by_no.get(no, null) as Control
		if row != null and is_instance_valid(row) and row.visible:
			_set_current(no)
			_scroll_to_line(no)
			return


# ---------------------------------------------------------------------------
# 场景状态条
# ---------------------------------------------------------------------------

## 显示「执行到当前行为止」的累积舞台状态。
##
## GVS 的状态是累积的（`bg classroom` 之后一直有效，直到下一条 bg），
## 所以光看某一行看不出画面长什么样 —— 这条把累积结果摆出来。
func _refresh_state_bar() -> void:
	if _state_bar == null:
		return

	# 用表格自己的当前行，不用主控的 caret_line —— 后者在表格页是残留值
	var no: int = _current_no if _current_no >= 1 else _ed.caret_line
	var st: Dictionary = _ed.doc.line_state(no)

	# **状态没变就只改标题**。
	# 重建这条要造缩略图（`Image.load_from_file` + 缩放），实测一次 134ms ——
	# 而选中行在同一场景内上下移动时状态往往完全一样，白跑。
	if st == _last_state and _state_bar.get_child_count() > 0:
		var t := _state_bar.get_child(0) as Label
		if t != null:
			t.text = "第 %d 行画面" % no
		return
	_last_state = st

	for c in _state_bar.get_children():
		_state_bar.remove_child(c)
		c.queue_free()

	_state_bar.add_child(EdTheme.label("第 %d 行画面" % no, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))

	var bg := String(st.get("bg", ""))
	if not bg.is_empty():
		_state_bar.add_child(_thumb_box(_asset_thumb("bg", bg, 44), Vector2(78, 44)))
		_state_bar.add_child(_kv("背景", bg))

	var cg := String(st.get("cg", ""))
	if not cg.is_empty():
		_state_bar.add_child(_thumb_box(_asset_thumb("cg", cg, 44), Vector2(78, 44)))
		_state_bar.add_child(_kv("CG", cg))

	var bgm := String(st.get("bgm", ""))
	if not bgm.is_empty():
		_state_bar.add_child(_kv("音乐", bgm))

	var weather := String(st.get("weather", ""))
	if not weather.is_empty() and weather != "none":
		_state_bar.add_child(_kv("天气", weather))

	var chars: Array = st.get("chars", [])
	if chars.is_empty():
		_state_bar.add_child(_kv("立绘", "无"))
	else:
		for c in chars:
			var ch: Dictionary = c
			var box := HBoxContainer.new()
			box.add_theme_constant_override("separation", 5)
			box.add_child(_thumb_box(
				_char_thumb(String(ch.get("id", "")), String(ch.get("expr", "normal")), 40),
				Vector2(26, 40)))
			var pos := String(ch.get("at", "center"))
			if ch.has("x") or ch.has("y"):
				pos = "%d,%d" % [int(round(float(ch.get("x", 0)))), int(round(float(ch.get("y", 0))))]
			box.add_child(EdTheme.label("%s · %s · %s" % [
				String(ch.get("id", "")), String(ch.get("expr", "normal")), pos],
				EdTheme.FS_SMALL, EdTheme.SYN_SPEAKER))
			_state_bar.add_child(box)


func _thumb_box(tex: Texture2D, min_size: Vector2) -> Control:
	if tex == null:
		var ph := ColorRect.new()
		ph.color = EdTheme.BG_PANEL
		ph.custom_minimum_size = min_size
		return ph
	var tr := TextureRect.new()
	tr.texture = tex
	tr.custom_minimum_size = min_size
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	return tr


func _kv(k: String, v: String) -> Control:
	return EdTheme.label("%s %s" % [k, v], EdTheme.FS_SMALL, EdTheme.TEXT_DIM)


# ---------------------------------------------------------------------------
# 行的外壳：外层 PanelContainer（负责选中/错误高亮与整行点击）+ 内层 HBox
# ---------------------------------------------------------------------------

## 外层用 PanelContainer 而不是直接 HBoxContainer：HBox 画不了背景，
## 而「选中行」「块层级竖线」「块间距」三件事都要求整行有底色与内边距。
##
## 内层子节点顺序固定（增量更新靠固定下标）：
##   0 行号按钮 · 1 错误色点 · 2 折叠钮 · 3 指令类型 · 4+ 参数 · 末尾 hfill
func _row_base(line: LineIndex.Line) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, ROW_H)
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.focus_mode = Control.FOCUS_CLICK
	panel.add_theme_stylebox_override("panel", _row_style(line, line.no == _current_no))
	panel.gui_input.connect(func(e: InputEvent) -> void:
		if _is_left_press(e):
			_set_current(_no_of(panel)))

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	panel.add_child(h)

	var no_btn := Button.new()
	no_btn.text = str(line.no)
	no_btn.flat = true
	no_btn.custom_minimum_size = Vector2(W_NO, 0)
	no_btn.add_theme_font_override("font", EdTheme.mono())
	no_btn.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	no_btn.add_theme_color_override("font_color",
		EdTheme.ACCENT if line.no == _current_no else EdTheme.TEXT_FAINT)
	no_btn.add_theme_color_override("font_hover_color", EdTheme.ACCENT)
	no_btn.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 0, 6, 0))
	no_btn.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 0, 6, 0))
	no_btn.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 0, 6, 0))
	no_btn.tooltip_text = _no_btn_tip(line.no)
	no_btn.pressed.connect(func() -> void:
		_set_current(_no_of(panel))
		_ed.goto_source(_no_of(panel)))
	h.add_child(no_btn)
	panel.set_meta("no_btn", no_btn)

	h.add_child(_issue_dot(line.no))
	h.add_child(_fold_cell(line, panel))
	h.add_child(_type_cell(line, panel))
	return panel


static func _hbox_of(row: Control) -> HBoxContainer:
	return row.get_child(0) as HBoxContainer


func _row_style(line: LineIndex.Line, selected: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.content_margin_left = 4 + float(line.depth) * float(INDENT_PER_DEPTH)
	s.content_margin_right = 6
	s.content_margin_top = 2
	s.content_margin_bottom = 2
	# 块之间留一段空白，让 if / choice 的边界一眼看得出来
	if line.opens_block():
		s.content_margin_top = BLOCK_GAP
	if line.closes_block():
		s.content_margin_bottom = BLOCK_GAP
	# 基本块分隔：领导点上方画一条横线 + 多留一段空白。
	# 用「样式」而不是「插一个分隔行控件」表达 —— 行控件是常驻的，
	# 往表体里插非行的子节点会让「行号 → 控件」的定位全部要重算。
	if _show_blocks and _block_of.has(line.no) and int(_block_of[line.no]) > 1:
		s.content_margin_top = maxi(s.content_margin_top, 16)
		s.border_width_top = 1
		s.border_color = EdTheme.BORDER_HI
	# 块层级：背景微亮（见 DEPTH_TINTS 的注释，刻意不画竖线）
	if selected:
		s.bg_color = EdTheme.SEL_BG
	elif line.depth > 0:
		var idx := mini(line.depth, DEPTH_TINTS.size()) - 1
		s.bg_color = Color(1, 1, 1, float(DEPTH_TINTS[idx]))
	else:
		s.bg_color = Color(0, 0, 0, 0)
	return s


static func _is_left_press(e: InputEvent) -> bool:
	if not (e is InputEventMouseButton):
		return false
	var mb := e as InputEventMouseButton
	return mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT


## 错误色点（固定占位，永远存在 —— 下标要稳）
func _issue_dot(no: int) -> Control:
	var l := EdTheme.label("", EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	l.custom_minimum_size = Vector2(W_DOT, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_apply_issue_mark_to_dot(l, no)
	return l


func _apply_issue_mark_to_dot(dot: Label, no: int) -> void:
	var items: Array = _issues.get(no, [])
	if items.is_empty():
		dot.text = ""
		dot.tooltip_text = ""
		return
	var has_error := false
	var lines := PackedStringArray()
	for it in items:
		var d: Dictionary = it
		if String(d.get("level", "warn")) == "error":
			has_error = true
		lines.append(String(d.get("text", "")))
	dot.text = "●"
	dot.add_theme_color_override("font_color", EdTheme.ERR if has_error else EdTheme.WARN)
	dot.tooltip_text = "\n".join(lines)


func _apply_issue_mark(row: Control, no: int) -> void:
	var h := _hbox_of(row)
	if h == null or h.get_child_count() < 2:
		return
	_apply_issue_mark_to_dot(h.get_child(1) as Label, no)


func _apply_issue_marks() -> void:
	for no in _row_by_no.keys():
		var row := _row_by_no[no] as Control
		if row != null and is_instance_valid(row):
			_apply_issue_mark(row, int(no))


## 折叠钮（固定占位：非块首行也要占同样宽度，列才对得齐）
func _fold_cell(line: LineIndex.Line, row: PanelContainer) -> Control:
	if not line.opens_block():
		var sp := Control.new()
		sp.custom_minimum_size = Vector2(W_FOLD, 0)
		sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return sp
	var b := Button.new()
	b.text = "▸" if _folded.has(line.no) else "▾"
	b.flat = true
	b.custom_minimum_size = Vector2(W_FOLD, 0)
	b.tooltip_text = "折叠 / 展开这个块"
	b.add_theme_font_override("font", EdTheme.ui())
	b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	b.add_theme_color_override("font_color", EdTheme.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", EdTheme.ACCENT)
	b.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 0, 2, 0))
	b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 0, 2, 0))
	b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 0, 2, 0))
	b.pressed.connect(func() -> void: _toggle_fold(_no_of(row)))
	row.set_meta("fold_btn", b)
	return b


## 指令类型单元：所有非结构行都给下拉（含空行 / 注释行 —— 把一段注释
## 改成对白是很常见的操作），结构行只读。
##
## ⚠️ 回调里必须用 `_no_of(row)` 取行号 —— 行号 meta 挂在**行**上，
## 不是挂在按钮上。写成 `_no_of(b)` 会恒得 0，菜单永远打不开
## （症状就是「点指令类型没有反应」）。
func _type_cell(line: LineIndex.Line, row: PanelContainer) -> Control:
	if OpSpec.is_structural(line.head) or line.kind == LineIndex.Line.LABEL:
		var l := EdTheme.label(line.head if not line.head.is_empty() else "标签",
			EdTheme.FS_SMALL, EdTheme.WARN)
		l.custom_minimum_size = Vector2(W_TAG, 0)
		l.clip_text = true
		l.tooltip_text = "结构行（%s）—— 骨架指令，改类型请到源码" % line.head
		return l

	var cur := _op_label(line)
	var b := Button.new()
	b.text = "%s ▾" % cur
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.custom_minimum_size = Vector2(W_TAG, 0)
	b.tooltip_text = "点这里换这一行的指令类型（当前：%s）" % cur
	b.add_theme_font_override("font", EdTheme.ui())
	b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	b.add_theme_color_override("font_color", _tag_color(_op_tag(line)))
	b.add_theme_color_override("font_hover_color", EdTheme.ACCENT)
	b.add_theme_color_override("font_pressed_color", EdTheme.ACCENT)
	b.add_theme_stylebox_override("normal", EdTheme.sb(EdTheme.BG, 0, 5, 0))
	b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 0, 5, 0))
	b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 0, 5, 0))
	b.pressed.connect(func() -> void: _open_type_menu(_no_of(row)))
	return b


## 这一行当前的「指令类型 id」（对白统一记成 __say）
static func _op_of(line: LineIndex.Line) -> String:
	if line.is_say():
		return "__say"
	if line.kind == LineIndex.Line.DIRECTIVE:
		return line.head
	return ""


static func _op_label(line: LineIndex.Line) -> String:
	# 空行 / 注释行没有「指令」，但类型格还是要显示点什么 ——
	# 否则就是一个孤零零的「▾」，看不出这一格是干嘛的
	if line.kind == LineIndex.Line.BLANK:
		return "空行"
	if line.kind == LineIndex.Line.COMMENT:
		return "注释"
	if line.is_say():
		return "对白" if not line.speaker.is_empty() else "旁白"
	var op := _op_of(line)
	var spec := OpSpec.get_spec(op)
	return String(spec.get("label", op)) if not spec.is_empty() else op


static func _op_tag(line: LineIndex.Line) -> String:
	var op := _op_of(line)
	if op == "__say":
		return "SAY"
	return String(OpSpec.get_spec(op).get("tag", ""))


# ---------------------------------------------------------------------------
# 行：对白 / 选项 / 标签 / 注释
# ---------------------------------------------------------------------------

func _say_row(line: LineIndex.Line) -> PanelContainer:
	var row := _row_base(line)
	var h := _hbox_of(row)

	# 角色
	var char_opt := OptionButton.new()
	char_opt.custom_minimum_size = Vector2(W_FIELD, 0)
	EdTheme.style_option(char_opt)
	char_opt.add_item("（旁白）", 0)
	var ids: PackedStringArray = _ed.index.char_ids()
	for k in ids.size():
		char_opt.add_item(String(ids[k]), k + 1)
	var sel := 0
	for k in ids.size():
		if String(ids[k]) == line.speaker:
			sel = k + 1
	if sel == 0 and not line.speaker.is_empty():
		char_opt.add_item("%s（缺立绘）" % line.speaker, ids.size() + 1)
		sel = ids.size() + 1
	char_opt.select(sel)
	char_opt.tooltip_text = "说话人"
	char_opt.item_selected.connect(func(idx: int) -> void:
		var txt := char_opt.get_item_text(idx)
		if txt.ends_with("（缺立绘）"):
			txt = txt.replace("（缺立绘）", "")
		if idx == 0:
			txt = ""
		_commit_speaker(row, txt))
	h.add_child(char_opt)

	# 表情
	var expr_opt := OptionButton.new()
	expr_opt.custom_minimum_size = Vector2(W_FIELD, 0)
	EdTheme.style_option(expr_opt)
	_populate_exprs(expr_opt, line.speaker, line.expr)
	expr_opt.tooltip_text = "行内表情（写作 角色@表情: 台词）"
	expr_opt.item_selected.connect(func(idx: int) -> void:
		var txt := expr_opt.get_item_text(idx)
		if txt.ends_with("（缺素材）"):
			txt = txt.replace("（缺素材）", "")
		if idx == 0:
			txt = ""
		_commit_expr(row, txt))
	h.add_child(expr_opt)

	# 台词
	var edit := LineEdit.new()
	edit.text = line.text
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_inline_edit(edit, EdTheme.FS_UI)
	var original := line.text
	edit.text_submitted.connect(func(t: String) -> void:
		_commit_text(row, t)
		# 回车 = 「这一句写完了，来下一句」—— 直接在下面接一行并聚焦，
		# 连续写剧本全程不用摸鼠标（Esc 退出编辑态）
		_insert_after_current("__say"))
	edit.focus_exited.connect(func() -> void:
		if edit.text != original:
			_commit_text(row, edit.text))
	h.add_child(edit)

	# 语音
	var voice := LineEdit.new()
	voice.text = _voice_of(line.no)
	voice.custom_minimum_size = Vector2(W_TEXT, 0)
	voice.placeholder_text = "语音"
	_style_inline_edit(voice, EdTheme.FS_SMALL, true)
	var voice_original := voice.text
	voice.text_submitted.connect(func(t: String) -> void: _commit_voice(row, t))
	voice.focus_exited.connect(func() -> void:
		if voice.text != voice_original:
			_commit_voice(row, voice.text))
	h.add_child(voice)

	h.add_child(EdTheme.hfill())
	return row


func _option_row(line: LineIndex.Line) -> PanelContainer:
	var row := _row_base(line)
	var h := _hbox_of(row)

	var edit := LineEdit.new()
	edit.text = line.text
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_inline_edit(edit, EdTheme.FS_UI)
	var original := line.text
	edit.text_submitted.connect(func(t: String) -> void: _commit_option_text(row, t))
	edit.focus_exited.connect(func() -> void:
		if edit.text != original:
			_commit_option_text(row, edit.text))

	var target := LineEdit.new()
	target.text = line.label
	target.custom_minimum_size = Vector2(W_FIELD + 40, 0)
	target.placeholder_text = "跳往标签"
	_style_inline_edit(target, EdTheme.FS_SMALL, true)
	var target_original := target.text
	target.text_submitted.connect(func(t: String) -> void: _commit_option_target(row, t))
	target.focus_exited.connect(func() -> void:
		if target.text != target_original:
			_commit_option_target(row, target.text))

	# **箭头本身就是「点击定位」**：点一下在剧本块里跳到目标标签。
	# 目标不存在时标红 —— 与 jump 行的链接同一套视觉。
	# （先建后放：lambda 要引用 `target`，所以它得先声明；显示顺序另算。）
	var arrow := Button.new()
	arrow.text = "→"
	arrow.flat = true
	arrow.custom_minimum_size = Vector2(26, 0)
	arrow.add_theme_font_override("font", EdTheme.ui())
	arrow.add_theme_font_size_override("font_size", EdTheme.FS_UI)
	var found: bool = not line.label.is_empty() and _ed.doc.label_line(line.label) > 0
	arrow.add_theme_color_override("font_color", EdTheme.ACCENT if found else EdTheme.ERR)
	arrow.add_theme_color_override("font_hover_color", Color.WHITE)
	arrow.add_theme_color_override("font_pressed_color", Color.WHITE)
	arrow.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 0, 4, 0))
	arrow.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 0, 4, 0))
	arrow.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 0, 4, 0))
	arrow.set_meta("no_touch", true)  # 点了要跳走，别把本行设成当前行
	arrow.tooltip_text = ("点一下跳到 label %s" % line.label) if found \
		else ("找不到标签「%s」" % line.label if not line.label.is_empty() else "还没有设置跳转目标")
	arrow.pressed.connect(func() -> void:
		# 先把输入框里改过的目标写回去（用户可能刚改完没按回车），再跳
		var want := (target as LineEdit).text.strip_edges()
		_commit_option_target(row, want)
		_goto_label(want))

	h.add_child(edit)
	h.add_child(arrow)
	h.add_child(target)
	h.add_child(EdTheme.hfill())
	return row


func _label_row(line: LineIndex.Line) -> PanelContainer:
	var row := _row_base(line)
	var h := _hbox_of(row)
	var l := EdTheme.mono_label(line.label, EdTheme.FS_UI, EdTheme.SYN_LABEL)
	l.custom_minimum_size = Vector2(W_FIELD + 60, 0)
	l.clip_text = true
	h.add_child(l)

	# 备注：写成行尾注释（`label X  # 备注`），**分支图的节点会显示它**。
	# 放在剧本里而不是另开一个 sidecar 文件 —— 它跟着剧本走，git 里也看得见。
	var note := LineEdit.new()
	note.text = _label_note_of(line)
	note.placeholder_text = "备注（会显示在分支图节点上）"
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_inline_edit(note, EdTheme.FS_SMALL, true)
	var original := note.text
	note.text_submitted.connect(func(t: String) -> void:
		if t != original:
			_commit_label_note(row, t))
	note.focus_exited.connect(func() -> void:
		if note.text != original:
			_commit_label_note(row, note.text))
	h.add_child(note)

	h.add_child(EdTheme.hfill())
	return row


## 标签行的备注（行尾注释里 `#` 之后的内容）
static func _label_note_of(line: LineIndex.Line) -> String:
	var h := line.raw.find("#")
	return "" if h < 0 else line.raw.substr(h + 1).strip_edges()


## 改标签备注：重写那一行为 `label <名字>  # <备注>`。
## **标签名本身不动**（备注只是行尾注释），所以不会影响跳转。
func _commit_label_note(row: PanelContainer, note_text: String) -> void:
	var line := _row_line(row)
	if line == null or line.label.is_empty():
		return
	var text := "label %s" % line.label
	var n := note_text.strip_edges()
	if not n.is_empty():
		text += "  # %s" % n
	if line.raw.strip_edges() == text:
		return
	_ed.doc.set_raw(line.no, _indent_of(line.raw) + text)
	_refresh_row(line.no)
	_ed._script_panel.mark_dirty_from_panel()


## 注释 / 空行
func _plain_row(line: LineIndex.Line) -> PanelContainer:
	var row := _row_base(line)
	var h := _hbox_of(row)
	var txt := line.raw if line.kind == LineIndex.Line.COMMENT else ""
	var l := EdTheme.mono_label(txt, EdTheme.FS_SMALL, EdTheme.SYN_COMMENT)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.clip_text = true
	h.add_child(l)
	h.add_child(EdTheme.hfill())
	return row


# ---------------------------------------------------------------------------
# 行：指令（可视化控件）
# ---------------------------------------------------------------------------

func _directive_row(line: LineIndex.Line) -> PanelContainer:
	var spec := OpSpec.get_spec(line.head)
	if spec.is_empty():
		return _structural_row(line)

	var row := _row_base(line)
	var h := _hbox_of(row)

	var fields: Array = spec.get("fields", [])
	if fields.is_empty():
		var l := EdTheme.mono_label(line.raw.strip_edges(), EdTheme.FS_SMALL, EdTheme.TEXT_DIM)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.clip_text = true
		h.add_child(l)
	else:
		for f in fields:
			var fd: Dictionary = f
			var ctl := _field_control(line, row, fd)
			if ctl != null:
				h.add_child(ctl)
		h.add_child(EdTheme.hfill())
	return row


func _field_control(line: LineIndex.Line, row: PanelContainer, fd: Dictionary) -> Control:
	match String(fd.get("type", "")):
		OpSpec.F_ASSET:
			return _asset_field(line, row, fd)
		OpSpec.F_EXPR:
			return _expr_field(line, row, fd)
		OpSpec.F_ENUM:
			return _enum_field(line, row, fd)
		OpSpec.F_NUM:
			return _num_field(line, row, fd)
		OpSpec.F_BOOL:
			return _bool_field(line, row, fd)
		OpSpec.F_TEXT:
			return _text_field(line, row, fd)
		OpSpec.F_LABEL:
			return _label_field(line, row, fd)
	return null


## 位置参数的下标偏移。
##
## `set` / `add` / `sub` 允许写成 `set var x 3` —— 那个**可选的** `var`
## 会占掉位置参数的第 0 位，所以字段的 `pos` 要整体后移。
## 两种写法项目里都在用（`set chapter 1` 与 `set var stance "defend"`）。
func _pos_shift(line: LineIndex.Line) -> int:
	var kw := String(OpSpec.get_spec(line.head).get("skip_if_first", ""))
	if not kw.is_empty() and line.args.size() > 0 and String(line.args[0]) == kw:
		return 1
	return 0


## 当前字段的值：位置参数取 args，kv 参数取 params
func _field_value(line: LineIndex.Line, fd: Dictionary) -> Variant:
	if fd.has("pos"):
		var p := int(fd["pos"]) + _pos_shift(line)
		if fd.get("tail", false):
			# 「吃到行尾」字段（`call` 的参数）：连 kv 一起取，所以不能只看 args
			return _unquote(_ed.doc.directive_tail(line.raw, p))
		if fd.get("rest", false):
			# 「整段」字段：值可能含空格，所以是「从它到最后一个位置参数」
			if p >= line.args.size():
				return null
			return _unquote(" ".join(line.args.slice(p)))
		if p < line.args.size():
			var v := String(line.args[p])
			# 文本类字段一律把最外层引号去掉再显示 ——
			# `set var stance "defend"` 的值是 `defend`，不是 `"defend"`。
			# （写回时要不要加引号由字段的 `quoted` 决定。）
			var ty := String(fd.get("type", ""))
			if ty == OpSpec.F_TEXT or ty == OpSpec.F_LABEL:
				return _unquote(v)
			return v
		return null
	return line.params.get(String(fd["key"]), null)


func _field_write(row: PanelContainer, fd: Dictionary, value: Variant) -> void:
	if not visible or _ed._current_page != "table":
		return
	if _stale_row(row):
		rebuild()
		return
	var line := _row_line(row)
	if line == null:
		return
	if fd.has("pos"):
		# **必须走 `_fmt_value`，不能写 `String(value)`。**
		# Godot 4 的 `String()` 只有 String / NodePath / StringName 三个构造函数：
		# 传 bool（置旗标的开关）或 float 进来，运行时会抛
		# 「Invalid call. Nonexistent 'String' constructor.」——
		# 界面照常重绘，值却没写进去，看起来就是「点了没反应」。
		var p := int(fd["pos"]) + _pos_shift(line)
		var text := _fmt_value(value)
		if fd.get("quoted", false):
			text = _quote(text)
		if fd.get("rest", false):
			_ed.doc.set_directive_rest(line.no, p, text)
		elif fd.get("tail", false):
			_ed.doc.set_directive_tail(line.no, p, text)
		else:
			_ed.doc.set_directive_arg(line.no, p, text)
	else:
		var key := String(fd["key"])
		if value == null:
			_ed.doc.strip_directive_param(line.no, key)
		else:
			_ed.doc.set_directive_param(line.no, key, value)
	_refresh_row(line.no)


func _asset_field(line: LineIndex.Line, row: PanelContainer, fd: Dictionary) -> Control:
	var kind := String(fd.get("kind", ""))
	var cur: Variant = _field_value(line, fd)
	var cur_id := "" if cur == null else _to_str(cur)

	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var tex := _asset_thumb(kind, cur_id, THUMB + 6)
	if tex != null:
		box.add_child(_thumb_box(tex, Vector2(THUMB + 10, THUMB + 10)))

	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(170 if fd.get("wide", false) else W_FIELD, 0)
	EdTheme.style_option(opt)
	opt.tooltip_text = String(fd.get("label", ""))

	var ids: PackedStringArray = _ed.index.ids(kind)
	opt.add_item("（未设置）", 0)
	var sel := 0
	for k in ids.size():
		opt.add_item(String(ids[k]), k + 1)
		if String(ids[k]) == cur_id:
			sel = k + 1
	if sel == 0 and not cur_id.is_empty():
		opt.add_item("%s（缺文件）" % cur_id, ids.size() + 1)
		sel = ids.size() + 1
	opt.select(sel)
	opt.item_selected.connect(func(idx: int) -> void:
		var txt := opt.get_item_text(idx)
		if txt.ends_with("（缺文件）"):
			txt = txt.replace("（缺文件）", "")
		if idx == 0:
			txt = ""
		_field_write(row, fd, txt))
	box.add_child(opt)
	return box


func _expr_field(line: LineIndex.Line, row: PanelContainer, fd: Dictionary) -> Control:
	var cur: Variant = _field_value(line, fd)
	var cur_expr := String(fd.get("default", "normal")) if cur == null else _to_str(cur)

	# 位置参数形态（`expr alice smile`）的选项要按角色来定 ——
	# 往前找一个 F_ASSET 字段把角色名取出来
	var speaker := line.speaker
	if speaker.is_empty():
		for f in (OpSpec.get_spec(line.head).get("fields", []) as Array):
			var other: Dictionary = f
			if other.get("type", "") == OpSpec.F_ASSET and other.get("kind", "") == "char":
				var v: Variant = _field_value(line, other)
				if v != null:
					speaker = _to_str(v)
				break

	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(W_FIELD, 0)
	EdTheme.style_option(opt)
	opt.tooltip_text = "表情"
	_populate_exprs(opt, speaker, cur_expr)
	opt.item_selected.connect(func(idx: int) -> void:
		var txt := opt.get_item_text(idx)
		if txt.ends_with("（缺素材）"):
			txt = txt.replace("（缺素材）", "")
		_field_write(row, fd, txt))
	return opt


func _enum_field(line: LineIndex.Line, row: PanelContainer, fd: Dictionary) -> Control:
	var cur: Variant = _field_value(line, fd)
	var cur_s := "" if cur == null else _to_str(cur)
	var values: Array = fd.get("values", [])

	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(W_FIELD, 0)
	EdTheme.style_option(opt)
	opt.tooltip_text = String(fd.get("label", ""))

	var sel := 0
	opt.add_item("（默认）", 0)
	for k in values.size():
		opt.add_item(String(values[k]), k + 1)
		if String(values[k]) == cur_s:
			sel = k + 1
	opt.select(sel)
	opt.item_selected.connect(func(idx: int) -> void:
		if idx == 0:
			# 「默认」= 删掉这个参数，让解析器的默认值生效
			_field_write(row, fd, null)
		else:
			_field_write(row, fd, opt.get_item_text(idx)))
	return opt


func _num_field(line: LineIndex.Line, row: PanelContainer, fd: Dictionary) -> Control:
	var cur: Variant = _field_value(line, fd)
	var value := float(fd.get("default", 0.0)) if cur == null else float(cur)

	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 2)

	if not bool(fd.get("bare", false)):
		box.add_child(EdTheme.label(String(fd.get("label", "")), EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))

	var edit := LineEdit.new()
	edit.text = _fmt_num(value)
	edit.custom_minimum_size = Vector2(W_NUM, 0)
	_style_inline_edit(edit, EdTheme.FS_SMALL, true)
	edit.tooltip_text = "%s（%s ~ %s）" % [String(fd.get("label", "")),
		_fmt_num(float(fd.get("min", 0.0))), _fmt_num(float(fd.get("max", 100.0)))]

	# ⚠️ **回车与失焦都要提交**。只挂 `text_submitted` 的话，改完数值直接去点别处
	# （改下一个框 / 点另一行 / 滚页面）值就丢了 —— 而界面看着像已经改了，
	# 用户报的「点击离开框后源代码没有更新，按保存也还是旧值」就是这个。
	# 重复提交由 `_commit_num` 里的「值没变就不写」挡掉，不会白推一个撤销点。
	edit.text_submitted.connect(func(t: String) -> void: _commit_num(row, fd, t))
	edit.focus_exited.connect(func() -> void: _commit_num(row, fd, edit.text))
	box.add_child(edit)
	return box


## 数值字段的提交。回车与失焦共用这一条路径。
func _commit_num(row: PanelContainer, fd: Dictionary, text: String) -> void:
	var no := _no_of(row)
	if no <= 0:
		return
	var line := _ed.doc.line_at(no) as LineIndex.Line
	if line == null:
		return
	var cur: Variant = _field_value(line, fd)
	var txt := text.strip_edges()

	if txt.is_empty():
		if cur != null:
			_field_write(row, fd, null)
		return
	if not txt.is_valid_float():
		_refresh_row(no)          # 输入非法 → 界面退回原值
		return

	var v := clampf(txt.to_float(), float(fd.get("min", -1e9)), float(fd.get("max", 1e9)))
	var step := float(fd.get("step", 0.0))
	if step > 0.0:
		v = snappedf(v, step)
	# 位置参数（`bare`）写回字符串，kv 参数写回数字 —— 与建行时的读法对称
	var new_val: Variant = _fmt_num(v) if bool(fd.get("bare", false)) else v
	if _same_num(cur, new_val):
		return
	_field_write(row, fd, new_val)


## 数值上是否等价。**按数比而不是按字符串比** ——
## 界面上是 `0.80`、文档里是 `0.8`，字符串不等但值一样，
## 按字符串比会「失焦一次就多写一次盘」（还会多推一个撤销点）。
##
## ⚠️ 用 `str()` 而不是 `String()`：Godot 4 的 `String()` 只收
## String / NodePath / StringName，传 float 会**运行时**抛
## `Invalid call. Nonexistent 'String' constructor.`（`str()` 对任意 Variant 都安全）。
static func _same_num(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == null and b == null
	var sa := str(a)
	var sb := str(b)
	if sa.is_valid_float() and sb.is_valid_float():
		return is_equal_approx(sa.to_float(), sb.to_float())
	return sa == sb


func _bool_field(line: LineIndex.Line, row: PanelContainer, fd: Dictionary) -> Control:
	var cur: Variant = _field_value(line, fd)
	# 位置参数形态下 `_field_value` 返回的是**字符串**（`flag x true` 里的 "true"），
	# 而 `bool("true")` 在 Godot 4 里同样没有构造函数，会抛
	# 「Invalid call. Nonexistent 'bool' constructor.」—— 所以要自己解。
	var value := _as_bool(cur if cur != null else fd.get("default", false))

	var chk := CheckButton.new()
	chk.button_pressed = value
	chk.text = String(fd.get("label", ""))
	chk.add_theme_font_override("font", EdTheme.ui())
	chk.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	# CheckButton 的选中态字体色在 Godot 默认主题里是白色，
	# 只覆盖 font_color 的话「一打开就看不见字」
	for state in ["font_color", "font_pressed_color", "font_hover_color",
			"font_hover_pressed_color", "font_focus_color"]:
		chk.add_theme_color_override(state, EdTheme.TEXT_DIM)
	chk.toggled.connect(func(on: bool) -> void: _field_write(row, fd, on))
	return chk


func _text_field(line: LineIndex.Line, row: PanelContainer, fd: Dictionary) -> Control:
	var cur: Variant = _field_value(line, fd)
	var edit := LineEdit.new()
	edit.text = "" if cur == null else _to_str(cur)
	edit.custom_minimum_size = Vector2(170 if fd.get("wide", false) else W_TEXT, 0)
	edit.placeholder_text = String(fd.get("label", ""))
	_style_inline_edit(edit, EdTheme.FS_SMALL, true)
	var original := edit.text
	edit.text_submitted.connect(func(t: String) -> void:
		if t.strip_edges().is_empty():
			_field_write(row, fd, null)
		elif t != original:
			_field_write(row, fd, t.strip_edges()))
	# ⚠️ 失焦也要提交 —— 与数值框同一个坑（改完直接点别处，值就丢了）
	edit.focus_exited.connect(func() -> void:
		if edit.text == original:
			return
		if edit.text.strip_edges().is_empty():
			_field_write(row, fd, null)
		else:
			_field_write(row, fd, edit.text.strip_edges()))
	return edit


## 标签引用 —— 渲染成一个**可点击的链接**，点了直接跳到那个 label。
##
## 跳转是剧本里最容易写错、也最难查的一类东西（写错名字不报错，只是永远走不到），
## 所以这里顺手把「目标在不在」也标出来：找不到就标红，
## 不用等静态校验跑完才知道。
func _label_field(line: LineIndex.Line, row: PanelContainer, fd: Dictionary) -> Control:
	var cur: Variant = _field_value(line, fd)
	var target := "" if cur == null else _to_str(cur)

	# 跨文件跳转（`jump_file <文件> <标签>`）：目标在另一个剧本里
	var file := ""
	if fd.has("file_pos"):
		var fp := int(fd["file_pos"]) + _pos_shift(line)
		if fp < line.args.size():
			file = String(line.args[fp])

	var found := false
	if target.is_empty():
		found = false
	elif file.is_empty():
		found = _ed.doc.label_line(target) > 0
	else:
		found = _file_has_label(file, target)

	var b := Button.new()
	b.text = target if not target.is_empty() else "（未设置）"
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(W_FIELD + 40, 0)
	b.clip_text = true
	b.add_theme_font_override("font", EdTheme.mono())
	b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	var col := EdTheme.ACCENT if found else EdTheme.ERR
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 0, 5, 0))
	b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 0, 5, 0))
	b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 0, 5, 0))
	b.add_theme_stylebox_override("focus", EdTheme.sb(Color(0, 0, 0, 0), 0, 5, 0))
	b.set_meta("no_touch", true)      # 点了要跳走，别把本行设成当前行

	if target.is_empty():
		b.tooltip_text = "还没有设置跳转目标"
	elif not found:
		b.tooltip_text = "找不到标签「%s」%s" % [target,
			"（在 %s 里）" % file.get_file() if not file.is_empty() else ""]
	elif file.is_empty():
		b.tooltip_text = "点一下跳到第 %d 行（label %s）" % [_ed.doc.label_line(target), target]
	else:
		b.tooltip_text = "点一下打开 %s 并跳到 label %s" % [file.get_file(), target]

	b.pressed.connect(func() -> void:
		if target.is_empty():
			_ed._notice_flash("这一行还没有设置跳转目标", EdTheme.WARN)
			return
		if not found:
			_ed._notice_flash("找不到标签「%s」%s" % [target,
				"（在 %s 里）" % file.get_file() if not file.is_empty() else ""], EdTheme.ERR)
			return
		if file.is_empty():
			_goto_label(target)
		else:
			# 跨文件：打开那个剧本，但**留在剧本块页**
			_ed._open_at_label_in_table(file, target))
	return b


## 在剧本块里定位到某一行（**不切到源码页**）。
##
## 跳转链接、choice 的箭头都用它 —— 用户正在剧本块里工作，
## 点了跳转却被打到源码页会丢掉他看的位置。
## （行号按钮仍然跳源码：那个按钮的 tooltip 明说「跳到源码第 N 行」，
##  是「我要看原始文本」的明确动作。）
func _goto_row(no: int) -> void:
	if no <= 0 or _ed == null or _ed.doc == null:
		return
	_set_current(no)
	_scroll_to_line(no, true)          # 明确导航 → 置顶最直观


## 在剧本块里定位到某个标签（找不到就说一声）
func _goto_label(label_name: String) -> void:
	if label_name.strip_edges().is_empty():
		_ed._notice_flash("这一行还没有设置跳转目标", EdTheme.WARN)
		return
	var no: int = _ed.doc.label_line(label_name.strip_edges())
	if no <= 0:
		_ed._notice_flash("找不到标签「%s」" % label_name, EdTheme.ERR)
		return
	_goto_row(no)


## 某个剧本文件里有没有这个标签（跨文件跳转的「目标在不在」）
func _file_has_label(path: String, label: String) -> bool:
	if label.is_empty() or not FileAccess.file_exists(path):
		return false
	var key := "%s#%s" % [path, label]
	if _label_exists_cache.has(key):
		return bool(_label_exists_cache[key])
	var hit := false
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		if String(raw).strip_edges() == "label %s" % label:
			hit = true
			break
	_label_exists_cache[key] = hit
	return hit


## 去掉最外层的成对引号（与 `GvsParser.unquote` 同一套规则）
static func _unquote(v: String) -> String:
	var s := v.strip_edges()
	if s.length() >= 2:
		var a := s[0]
		var z := s[s.length() - 1]
		if (a == "\"" and z == "\"") or (a == "'" and z == "'"):
			return s.substr(1, s.length() - 2)
	return s


static func _quote(v: String) -> String:
	return "\"%s\"" % _unquote(v)


# ---------------------------------------------------------------------------
# 行：结构指令（只读原文，删除需确认）
# ---------------------------------------------------------------------------

func _structural_row(line: LineIndex.Line) -> PanelContainer:
	var row := _row_base(line)
	var h := _hbox_of(row)

	var l := EdTheme.mono_label(line.raw.strip_edges(), EdTheme.FS_SMALL, EdTheme.TEXT_DIM)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.clip_text = true
	h.add_child(l)

	h.add_child(EdTheme.label("结构行 · 请到源码改", EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))
	h.add_child(EdTheme.hfill())
	return row


# ---------------------------------------------------------------------------
# 事件挂钩
# ---------------------------------------------------------------------------

## 行内任何交互都把它记成「当前行」。
##
## 回调一律用 `_no_of(row)` **现取行号**，不捕获具体数字 ——
## 否则插入/删除后行号位移，回调就会作用到别的行上。
func _hook_row(row: Control) -> void:
	for c in row.get_children():
		_hook_control(c, row)


func _hook_control(node: Node, row: Control) -> void:
	if node is LineEdit:
		(node as LineEdit).focus_entered.connect(func() -> void: _touch_row(row))
	elif node is OptionButton:
		(node as OptionButton).pressed.connect(func() -> void: _touch_row(row))
	elif node is CheckButton:
		(node as CheckButton).toggled.connect(func(_on: bool) -> void: _touch_row(row))
	elif node is Button:
		# 带 `no_touch` 标记的按钮（跳转链接 / choice 的箭头）不参与
		# 「点一下把本行设为当前行」—— 它们的动作是**跳到别处**，
		# 而 `_hook_row` 是在行建好之后才挂的，同步执行会把跳转结果覆盖掉
		# （实测：跳到第 8 行又被拽回本行的第 6 行）。
		if bool((node as Button).get_meta("no_touch", false)):
			return
		(node as Button).pressed.connect(func() -> void: _touch_row(row))
	elif node is Container:
		for g in node.get_children():
			_hook_control(g, row)


# ---------------------------------------------------------------------------
# 键盘：选中行上的结构操作
# ---------------------------------------------------------------------------

## 只在「焦点不在文本输入框」时接管方向键 / 回车 / 退格。
##
## LineEdit 会消费自己认识的键，所以正常情况下这里收不到；
## 但用户可能把焦点放在下拉框上再按退格 —— 那时删掉整行是符合预期的，
## 所以唯一的排除项就是 LineEdit。
func _unhandled_key_input(event: InputEvent) -> void:
	if _ed == null or _ed.doc == null or not visible or _ed._current_page != "table":
		return
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return

	# Ctrl+V：多行粘贴 → 自动拆成多行对白
	if k.ctrl_pressed and k.keycode == KEY_V:
		var clip := DisplayServer.clipboard_get()
		if clip.contains("\n"):
			_paste_multiline(clip)
			accept_event()
		return

	if k.ctrl_pressed or k.alt_pressed:
		return

	var f := get_viewport().gui_get_focus_owner()
	if f is LineEdit:
		if k.keycode == KEY_ESCAPE:
			# 焦点在查找框里按 Esc = 关掉查找条（比「只是失焦」更符合直觉）
			if f == _find_input:
				close_find()
			get_viewport().gui_release_focus()
			accept_event()
		return

	# 查找条开着时 Esc 关掉它（此时焦点不在输入框上）
	if k.keycode == KEY_ESCAPE and is_find_open():
		close_find()
		accept_event()
		return

	match k.keycode:
		KEY_UP:
			_move_selection(-1)
			accept_event()
		KEY_DOWN:
			_move_selection(1)
			accept_event()
		KEY_ENTER, KEY_KP_ENTER:
			_insert_after_current("__say")
			accept_event()
		KEY_BACKSPACE, KEY_DELETE:
			_request_delete(_anchor_no())
			accept_event()
		KEY_ESCAPE:
			get_viewport().gui_release_focus()
			accept_event()


## 多行粘贴：按行拆成多条对白，插在当前行之后
func _paste_multiline(text: String) -> void:
	if not visible or _ed._current_page != "table":
		return
	var at := _anchor_no()
	var indent := ""
	var prev := _ed.doc.line_at(at) as LineIndex.Line
	if prev != null:
		indent = _indent_of(prev.raw)
		if prev.opens_block():
			indent += "    "
	var speaker := _speaker_for_insert(at)
	var block := PackedStringArray()
	for raw in text.split("\n"):
		var s := String(raw).strip_edges()
		if s.is_empty():
			continue
		# 已经是 `角色: 台词` 形态就原样保留，否则补上说话人
		if s.contains(":") and not s.contains("="):
			block.append(indent + s)
		else:
			block.append("%s%s: %s" % [indent, speaker, s])
	if block.is_empty():
		return
	_ed.doc.insert_raw(at + 1, block)
	_commit_structural_change(at, block.size(), "粘贴 %d 行" % block.size())
	_set_current(at + 1)
	_scroll_to_line(at + 1)
	_reveal_notice(at + 1)


# ---------------------------------------------------------------------------
# 指令类型转换
# ---------------------------------------------------------------------------

func _open_type_menu(no: int) -> void:
	if _ed == null or _ed.doc == null:
		return
	var line := _ed.doc.line_at(no) as LineIndex.Line
	if line == null or OpSpec.is_structural(line.head):
		return
	_set_current(no)
	_type_menu.clear()
	_type_menu.set_meta("for_no", no)
	_type_menu.set_meta("rev", _ed.doc.revision)
	var cur := _op_of(line)
	# ⚠️ 下标**必须用 `item_count` 现取**，不能自己数一个计数器。
	#
	# `add_separator()` 也会占掉一个 item 下标，自己数的计数器从第二组起
	# 就整体错位一格 —— 于是每个菜单项挂的是**前一项**的 metadata，
	# 每组的最后一项没有 metadata。表现：点「背景」没反应（拿到 null），
	# 点「立绘入场」插出来的是「立绘退场」……
	# 这个 off-by-one 曾经真的把两行模板插进了 prologue.gvs。
	for group in OpSpec.insert_menu():
		var g: Array = group
		if _type_menu.item_count > 0:
			_type_menu.add_separator()
		var head := _type_menu.item_count
		_type_menu.add_item("── %s ──" % String(g[0]))
		_type_menu.set_item_disabled(head, true)
		for op in (g[1] as Array):
			var o := String(op)
			var label := "对白" if o == "__say" else String(OpSpec.get_spec(o).get("label", o))
			var i := _type_menu.item_count
			_type_menu.add_item("%s   (%s)" % [label, o])
			_type_menu.set_item_metadata(i, o)
			if o == cur:
				# 注意：Godot 4.7 的 PopupMenu **没有** set_item_checkable
				# （加了会抛 Nonexistent function，并直接中断整个填充过程，
				# 表现成「点指令类型没反应」）。勾选只用 set_item_checked。
				_type_menu.set_item_checked(i, true)
	_type_menu.reset_size()
	_type_menu.position = Vector2i(_ed.get_global_mouse_position())
	_type_menu.popup()


## PopupMenu 用 index_pressed（拿的是 item 下标），不是 OptionButton 那个
## item_selected（拿的是 item id）—— 两者容易混
func _on_type_index(index: int) -> void:
	# 分组标题项没有 metadata，`String(null)` 会抛「Nonexistent 'String' constructor.」
	# —— 虽然禁用的项点不动，但这类调用一定要先判空
	var md: Variant = _type_menu.get_item_metadata(index)
	if md == null:
		return
	var op := String(md)
	if op.is_empty():
		return
	if int(_type_menu.get_meta("rev", -1)) != _ed.doc.revision:
		rebuild()
		_ed._notice_flash("剧本已变动，请重新选择类型", EdTheme.WARN)
		return
	var no := int(_type_menu.get_meta("for_no", 0))
	# 结构 / 块级指令**不能把现成的行转过去** —— 把一行台词转成 `end`
	# 会让后面的块结构整体变化，后果隐蔽。所以改成「在下面插一条」：
	# 用户在菜单里选它，想要的是「我要用这条指令」，插入正好满足。
	if OpSpec.is_structural(op) or _touches_blocks(PackedStringArray([op])):
		_insert_block(no, op)
	else:
		_convert_line(no, op)


## 把某一行的指令类型原地换掉。
##
## 尽量把「新指令也认」的参数搬过去，但规则刻意保守：
## 只搬新指令确实声明过、且**类型一致**的字段。搬错比不搬更糟 ——
## `show alice expr=smile` 转成 `bg` 时若把 `expr` 带过去，
## 解析器会静默忽略它，作者却以为自己设了表情。
func _convert_line(no: int, op: String) -> void:
	if not visible or _ed._current_page != "table":
		return
	var line := _ed.doc.line_at(no) as LineIndex.Line
	if line == null:
		return
	if _op_of(line) == op:
		return
	if line.kind == LineIndex.Line.LABEL or OpSpec.is_structural(line.head) \
			or _touches_blocks(PackedStringArray([op])):
		_ed._notice_flash("结构行不能在表格里改类型，请到源码改", EdTheme.WARN)
		return

	var indent := _indent_of(line.raw)
	var carried: Array = []
	var dropped := PackedStringArray()
	var subject := _subject_of(line)

	_ed.doc.begin_batch()
	var text := ""
	var unfilled := PackedStringArray()
	if op == "__say":
		text = "%s%s: 新台词" % [indent, subject if not subject.is_empty()
			else _first_char_or_empty()]
	else:
		var d := _default_text_for(op)
		text = indent + String(d["text"])
		unfilled = d["unfilled"]
		carried = _carry_params(line, op, subject, dropped)
	_ed.doc.set_raw(no, text)
	# 把能沿用的参数补上去。
	# **位置参数必须走 `set_directive_arg`**：`set_directive_param` 会把它当成
	# `char=bob` 追加到行尾，而解析器只把「不含 = 的词」当位置参数 ——
	# 结果是多出一个谁也不认的 kv 参数，角色根本没换过去。
	for c in carried:
		var item: Dictionary = c
		var pos := int(item.get("pos", -1))
		if pos >= 0:
			_ed.doc.set_directive_arg(no, pos, _fmt_value(item["value"]))
		else:
			_ed.doc.set_directive_param(no, String(item["key"]), item["value"])
	_ed.doc.end_batch()

	# 类型变了 → 行的控件结构整个换了，重建这一行
	_refresh_row(no)
	_set_current(no)
	var msg := "已改为 %s" % ("对白" if op == "__say" else String(
		OpSpec.get_spec(op).get("label", op)))
	if unfilled.size() > 0:
		msg += " —— %s 要自己填（素材索引里没有这类素材）" % " ".join(unfilled)
	elif dropped.size() > 0:
		msg += "（未沿用：%s）" % " ".join(dropped)
	_ed._notice_flash(msg, EdTheme.WARN if (unfilled.size() > 0 or dropped.size() > 0) else EdTheme.OK)


## 这一行的「主体」（角色名）：对白取说话人，指令取 char 类位置参数
func _subject_of(line: LineIndex.Line) -> String:
	if line.is_say():
		return line.speaker
	var spec := OpSpec.get_spec(line.head)
	for f in (spec.get("fields", []) as Array):
		var fd: Dictionary = f
		if fd.get("type", "") != OpSpec.F_ASSET or String(fd.get("kind", "")) != "char":
			continue
		if not fd.has("pos"):
			continue
		var p := int(fd["pos"])
		if p < line.args.size():
			return String(line.args[p])
	return ""


## 转换时能沿用的参数。
##
## 返回 `[{"key", "value", "pos"}]` —— `pos >= 0` 表示新指令里它是**位置参数**，
## 写回时必须走 `set_directive_arg`（走错会把角色写成 `char=bob` 那种没人认的 kv）。
func _carry_params(old: LineIndex.Line, op: String, subject: String,
		dropped: PackedStringArray) -> Array:
	var out: Array = []
	var new_spec := OpSpec.get_spec(op)
	var fields: Array = new_spec.get("fields", [])
	# 主体填进第一个 char 位置参数
	for f in fields:
		var fd: Dictionary = f
		if fd.get("type", "") != OpSpec.F_ASSET or String(fd.get("kind", "")) != "char":
			continue
		if fd.has("pos") and not subject.is_empty():
			out.append({"key": String(fd["key"]), "value": subject, "pos": int(fd["pos"])})
		break
	# kv：新指令声明过、类型一致才搬
	for f2 in fields:
		var fd2: Dictionary = f2
		if fd2.has("pos"):
			continue
		var key := String(fd2.get("key", ""))
		if not old.params.has(key):
			continue
		var ty := String(fd2.get("type", ""))
		var v: Variant = old.params[key]
		var ok := false
		if ty == OpSpec.F_BOOL and typeof(v) == TYPE_BOOL:
			ok = true
		elif ty == OpSpec.F_NUM and (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT):
			ok = true
		elif (ty == OpSpec.F_ENUM or ty == OpSpec.F_TEXT) and typeof(v) == TYPE_STRING:
			ok = true
		if ok:
			out.append({"key": key, "value": v, "pos": -1})
		else:
			dropped.append(key)
	# 旧行有、新指令没有的参数，明说丢掉
	for key2 in old.params.keys():
		var k2 := String(key2)
		var kept := false
		for c in out:
			if String((c as Dictionary).get("key", "")) == k2:
				kept = true
				break
		if kept:
			continue
		var declared := false
		for f3 in fields:
			if String((f3 as Dictionary).get("key", "")) == k2:
				declared = true
				break
		if not declared and not dropped.has(k2):
			dropped.append(k2)
	return out


# ---------------------------------------------------------------------------
# 缩略图
# ---------------------------------------------------------------------------

func _asset_thumb(kind: String, id: String, size: int) -> Texture2D:
	if id.is_empty():
		return null
	var entry: Dictionary = _ed.index.get_entry(kind, id)
	if entry.is_empty():
		return null
	return _thumb(String(entry.get("path", "")), size)


func _char_thumb(cid: String, expr: String, size: int) -> Texture2D:
	var entry: Dictionary = _ed.index.get_entry("char", cid)
	if entry.is_empty():
		return null
	var exprs: Dictionary = entry.get("exprs", {})
	if exprs.has(expr):
		return _thumb(String((exprs[expr] as Dictionary).get("path", "")), size)
	# 找不到就退回第一个表情，总比空着强
	for k in exprs.keys():
		return _thumb(String((exprs[k] as Dictionary).get("path", "")), size)
	return null


## 缩略图。
##
## 两级缓存 + 优先用**导入产物**：
##   `_src_cache`   path → 原图（同一张图被不同尺寸请求时只解码一次）
##   `_thumb_cache` path@size → 成品纹理
##
## 为什么先试 `load()`：Godot 导入过的素材是显存友好的纹理，
## `load()` 比现解 PNG 快一个量级（实测 1920×1080 现解一次 ~30ms，
## 而选中一行就要刷一次状态条）。缩略由 `TextureRect` 的
## `STRETCH_KEEP_ASPECT_CENTERED` 在 GPU 上完成，不做 CPU 缩放 ——
## 24px 的小图上两者看不出差别。
## 没导入过的新素材（`ResourceLoader.exists` 为假）才退回直读 + CPU 缩放，
## 这样「刚丢进 assets/ 的图立刻可见」这条性质仍然成立。
func _thumb(path: String, size: int) -> Texture2D:
	if path.is_empty():
		return null
	var key := "%s@%d" % [path, size]
	if _thumb_cache.has(key):
		return _thumb_cache[key]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	if tex == null:
		var src: Image = _src_cache.get(path, null)
		if src == null:
			src = Image.load_from_file(path)
			_src_cache[path] = src
		if src != null:
			var img := Image.new()
			img.copy_from(src)          # 从缓存复制，别把原图缩了
			var h := mini(img.get_height(), size * 2)
			var w := int(float(img.get_width()) * float(h) / maxf(float(img.get_height()), 1.0))
			img.resize(maxi(w, 1), maxi(h, 1), Image.INTERPOLATE_BILINEAR)
			tex = ImageTexture.create_from_image(img)
	_thumb_cache[key] = tex
	return tex


# ---------------------------------------------------------------------------
# 增删
# ---------------------------------------------------------------------------

## 在当前行之后插入一行（或一个块），并选中新行、聚焦它的台词输入框
func _insert_after_current(op: String) -> void:
	var at := _anchor_no()
	if op == "__say":
		_insert_say(at)
	else:
		_insert_block(at, op)


func _insert_say(at: int) -> void:
	if _ed == null or _ed.doc == null:
		return
	if not visible or _ed._current_page != "table":
		return
	at = clampi(at, 0, _ed.doc.line_count())
	var indent := _indent_for(at)
	var raw := "%s%s: 新台词" % [indent, _speaker_for_insert(at)]
	_ed.doc.insert_raw(at + 1, PackedStringArray([raw]))
	_commit_structural_change(at, 1, "插入对白")
	_set_current(at + 1)
	_scroll_to_line(at + 1)
	_reveal_notice(at + 1)
	_focus_row_editor(at + 1)


## 插入块（choice / if / 其他指令模板）。指令模板走增量；块走全量重建
## （块会改变后面所有行的缩进与竖线）。
func _insert_block(at: int, op: String) -> void:
	if _ed == null or _ed.doc == null:
		return
	if not visible or _ed._current_page != "table":
		return
	at = clampi(at, 0, _ed.doc.line_count())
	var indent := _indent_for(at)
	var block: PackedStringArray
	var unfilled := PackedStringArray()
	if op == "choice":
		block = PackedStringArray(["%schoice" % indent,
			"%s    \"选项一\" -> 标签一" % indent,
			"%s    \"选项二\" -> 标签二" % indent,
			"%send" % indent])
	elif op == "if":
		block = PackedStringArray(["%sif flag 新旗标" % indent, "", "%send" % indent])
	elif op == "together":
		# 演出并行组。块内先给一行注释说明用法（注释行不参与解析），
		# 作者照着替换成真正的演出指令即可。
		block = PackedStringArray([
			"%stogether" % indent,
			"%s    # 块内只放演出 / 音频指令（bg / show / move / bgm …）；" % indent,
			"%s    # 块结束会等最长的那条跑完，不用手写 wait。" % indent,
			"%send" % indent])
	elif op == "end":
		block = PackedStringArray(["%send" % indent])
	elif OpSpec.is_structural(op):
		# 结构指令（label / jump / goto / call / return / jump_file）：
		# 它们没有字段规格，用一张专门的骨架表
		block = PackedStringArray([indent + OpSpec.structural_template(op)])
	else:
		var d := _default_text_for(op)
		block = PackedStringArray([indent + String(d["text"])])
		unfilled = d["unfilled"]

	_ed.doc.insert_raw(at + 1, block)
	_commit_structural_change(at, block.size(), "插入 %s" % op)
	_set_current(at + 1)
	_scroll_to_line(at + 1)
	_reveal_notice(at + 1)
	if unfilled.size() > 0:
		_ed._notice_flash("已插入 %s —— 但 %s 要自己填（素材索引里没有这类素材）"
			% [op, " ".join(unfilled)], EdTheme.WARN)
	else:
		_ed._notice_flash("已插入 %s（第 %d 行）" % [op, at + 1], EdTheme.OK)


## 插入了 count 行之后统一收尾。
##
## 行控件常驻，插入之后只需要重刷样式（基本块分隔线 / 块层级缩进会整体位移）。
func _commit_structural_change(at: int, count: int, what: String) -> void:
	_sync_after_insert(at, count)
	_ed._script_panel.mark_dirty_from_panel()


## 插入之后如果新行不在视口里（用户正滚在别处看），明确说一声 ——
## 否则「按了回车但屏幕上什么都没变」会被当成没生效。
func _reveal_notice(no: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if is_inside_tree() and not _row_in_view(no):
		_ed._notice_flash("已插入第 %d 行（在视口外 —— 滚回去就能看到）" % no, EdTheme.WARN)


## 新行插进去之后把光标放进它的台词输入框 —— 连续写剧本不用摸鼠标
func _focus_row_editor(no: int) -> void:
	await get_tree().process_frame
	var row := _row_by_no.get(no, null) as Control
	if row == null or not is_instance_valid(row):
		return
	var e := _find_line_edit(row)
	if e != null:
		e.grab_focus()
		e.select_all()


func _find_line_edit(node: Node) -> LineEdit:
	if node is LineEdit:
		return node
	for c in node.get_children():
		var r := _find_line_edit(c)
		if r != null:
			return r
	return null


func _indent_for(at: int) -> String:
	var prev := _ed.doc.line_at(at) as LineIndex.Line
	if prev == null:
		return ""
	var indent := _indent_of(prev.raw)
	if prev.opens_block():
		indent += "    "
	elif prev.kind == LineIndex.Line.DIRECTIVE and (prev.head == "elif" or prev.head == "else"):
		indent += "    "
	return indent


func _first_char_or_empty() -> String:
	var ids: PackedStringArray = _ed.index.char_ids()
	return String(ids[0]) if ids.size() > 0 else ""


## 新对白的说话人：沿用上一行的说话人。
##
## 作者在谁的对话里加一行，十有八九还是那个人 —— 以前一律取「素材索引里的
## 第一个角色」，于是在 bob 的对话里插一行会冒出个 alice，
## 看上去就是「添加出来的东西跟上下文对不上」。
func _speaker_for_insert(at: int) -> String:
	var prev := _ed.doc.line_at(at) as LineIndex.Line
	if prev != null and prev.is_say() and not prev.speaker.is_empty():
		return prev.speaker
	return _first_char_or_empty()


## 插入一条指令时的默认文本。
##
## `OpSpec.default_text()` 会把素材字段写成 `<角色>` / `<语音>` 这种占位符 ——
## 那是给作者「照着填」看的提示，但它本身**不是合法内容**：
## 插进剧本后 `hide <角色>` 只是静默什么都不做，静态审计也只把它算作
## 「缺素材」（0 错 0 提醒），于是「加了东西但结果对不上」。
##
## 所以：素材索引里有该类素材就用**真实存在的 id**；一条都没有
## （例如本项目根本没有 `assets/voice/`）就保留占位符，
## 但把剩下的占位符回传给调用方去**显式提醒** —— 不能静默。
func _default_text_for(op: String) -> Dictionary:
	var text := OpSpec.default_text(op)
	var unfilled := PackedStringArray()
	for f in (OpSpec.get_spec(op).get("fields", []) as Array):
		var fd: Dictionary = f
		if String(fd.get("type", "")) != OpSpec.F_ASSET:
			continue
		var ph := "<%s>" % String(fd.get("label", "id"))
		if not text.contains(ph):
			continue
		var ids: PackedStringArray = _ed.index.ids(String(fd.get("kind", "")))
		if ids.size() > 0:
			text = text.replace(ph, String(ids[0]))
		else:
			unfilled.append(ph)
	return {"text": text, "unfilled": unfilled}


func _request_delete(no: int) -> void:
	if _ed == null or _ed.doc == null:
		return
	var line := _ed.doc.line_at(no) as LineIndex.Line
	if line == null:
		return
	# 结构行删除的后果隐蔽（删掉 end 会让后面整段落进块里），要确认
	if line.kind == LineIndex.Line.LABEL or OpSpec.is_structural(line.head):
		_pending_delete = no
		_confirm.dialog_text = "第 %d 行是结构行：\n\n    %s\n\n删掉它可能让后续内容掉进或掉出 if / choice 块，\n而剧本不会报错 —— 剧情会静默走错。确定要删吗？" % [no, line.raw.strip_edges()]
		_confirm.popup_centered()
		return
	_do_delete(no)


func _do_pending_delete() -> void:
	if _pending_delete > 0:
		_do_delete(_pending_delete)
		_pending_delete = 0


## 把某一行滚到可见区域。
##
## **按行号查行控件**，不能拿「行号 - 1」当表体的子节点下标 ——
## 关掉「显示注释与空行」、开着过滤或折叠了块时，表体行数与文档行数不相等。
##
## `pin = true`（明确导航到某一行）：置顶最直观。
##
## `pin = false`（插入 / 删除）：**只向下滚，不向上滚**。
## 目标行在视口上方时什么都不做 —— 用户主动滚去看别处是有意为之，
## 把他拽回去比「新行暂时看不见」更糟：实测被拽一次能从 7139 跳到 794，
## 用户描述成「跳到最顶层」。
## （这条与 VS Code 一致：光标在视口外时按回车，文本插在光标处，视图不动。）
func _scroll_to_line(no: int, pin: bool = false) -> void:
	await get_tree().process_frame
	if not is_inside_tree():
		return
	var row := _row_by_no.get(_reveal_no(no), null) as Control
	if row == null or not is_instance_valid(row) or not row.visible:
		return
	if row.size.y <= 0.0:
		return                    # 还没布局好，位置是假的（下一帧再滚也没人看）
	var top := float(row.position.y)
	if pin:
		_scroll.scroll_vertical = int(top)
		return
	var view_h := float(_scroll.size.y)
	var view_top := float(_scroll.scroll_vertical)
	if top >= view_top + view_h:
		_scroll.scroll_vertical = int(ceil(top + row.size.y - view_h))


func _row_visible(no: int) -> bool:
	var row := _row_by_no.get(no, null) as Control
	return row != null and is_instance_valid(row) and row.visible


## 目标行被隐藏时（默认不显示空行与注释、或折叠了块）退到**最近的可见行**。
##
## 这条很关键：`show_page("table")` 会拿源码视图的光标行来调 `goto_line`，
## 而光标常常正停在空行或注释上 —— 那些行现在默认不显示。
## 如果因为「这一行不显示」就整个放弃滚动，视图会停在文件开头，
## 用户看到的就是「切到表格页时跳到最顶层」。
func _reveal_no(no: int) -> int:
	if _row_visible(no):
		return no
	var down := _nearest_visible(no, 1)
	if down != no and _row_visible(down):
		return down
	var up := _nearest_visible(no, -1)
	if up != no and _row_visible(up):
		return up
	return no


func _do_delete(no: int) -> void:
	if not visible or _ed._current_page != "table":
		return
	var line := _ed.doc.line_at(no) as LineIndex.Line
	if line == null:
		return
	var what := line.raw.strip_edges()
	_ed.doc.remove_raw(no)
	_sync_after_delete(no)
	# 删完之后选中**上一行** —— 与「文本编辑器里退格合并到上一行」的直觉一致。
	# 落到下一行会让光标往下掉一格，连续删的时候手感很别扭。
	# 上一行可能是个默认隐藏的空行，所以要朝上找第一个可见的。
	_set_current(_nearest_visible(clampi(no - 1, 1, maxi(1, _ed.doc.line_count())), -1))
	_scroll_to_line(_current_no)
	_ed._script_panel.mark_dirty_from_panel()
	_ed._notice_flash("已删除：%s" % what, EdTheme.WARN)


# ---------------------------------------------------------------------------
# 提交改动（只重写被改的那一行）
# ---------------------------------------------------------------------------

func _commit_text(row: PanelContainer, text: String) -> void:
	if _rebuilding:
		return
	var line := _row_line(row)
	if line == null or line.text == text:
		return
	_ed.doc.set_dialogue_text(line.no, text)
	# 内容变了但控件不用重建（否则正在输入的框会被销毁）——只把 meta 里的原文对齐
	row.set_meta("raw", _ed.doc.text_at(line.no))
	_ed._script_panel.mark_dirty_from_panel()


func _commit_speaker(row: PanelContainer, speaker: String) -> void:
	var line := _row_line(row)
	if line == null or line.speaker == speaker:
		return
	_ed.doc.set_dialogue_speaker(line.no, speaker)
	_refresh_row(line.no)
	_ed._script_panel.mark_dirty_from_panel()


func _commit_expr(row: PanelContainer, expr: String) -> void:
	var line := _row_line(row)
	if line == null or line.expr == expr:
		return
	_ed.doc.set_dialogue_expr(line.no, expr)
	_refresh_row(line.no)
	_ed._script_panel.mark_dirty_from_panel()


func _commit_option_text(row: PanelContainer, text: String) -> void:
	var line := _row_line(row)
	if line == null or line.text == text:
		return
	_ed.doc.set_dialogue_text(line.no, text)
	row.set_meta("raw", _ed.doc.text_at(line.no))
	_ed._script_panel.mark_dirty_from_panel()


func _commit_option_target(row: PanelContainer, target: String) -> void:
	var line := _row_line(row)
	if line == null or line.label == target:
		return
	var arrow := line.raw.find("->")
	if arrow == -1:
		return
	_ed.doc.set_raw(line.no, line.raw.substr(0, arrow + 2) + " " + target.strip_edges())
	_refresh_row(line.no)
	_ed._script_panel.mark_dirty_from_panel()


## 语音列：改写该对白上方紧邻的 `voice` 指令；没有就新建一条插在台词前
func _commit_voice(row: PanelContainer, voice_id: String) -> void:
	var line := _row_line(row)
	if line == null:
		return
	var no := line.no
	var doc = _ed.doc
	var i := no - 2
	while i >= 0:
		var l := doc.lines[i] as LineIndex.Line
		if l.kind == LineIndex.Line.BLANK or l.kind == LineIndex.Line.COMMENT:
			i -= 1
			continue
		if l.kind == LineIndex.Line.DIRECTIVE and l.head == "voice":
			if voice_id.strip_edges().is_empty():
				doc.remove_raw(l.no)
			else:
				doc.set_raw(l.no, "%svoice %s" % [_indent_of(l.raw), voice_id.strip_edges()])
			rebuild()
			return
		break
	if voice_id.strip_edges().is_empty():
		return
	var indent := _indent_of(line.raw)
	doc.insert_raw(no, PackedStringArray(["%svoice %s" % [indent, voice_id.strip_edges()]]))
	rebuild()


# ---------------------------------------------------------------------------
# 参数写回辅助
# ---------------------------------------------------------------------------

## Variant → 写回剧本用的字面量。
##
## 存在的理由：Godot 4 的 `String()` 只接受 String / NodePath / StringName，
## 拿 bool / float 去调会**运行时**抛「Invalid call. Nonexistent 'String' constructor.」。
## 位置参数的值来自控件，类型是 Variant（开关给 bool、数字给 float），
## 所以写回前必须自己转。
static func _fmt_value(v: Variant) -> String:
	match typeof(v):
		TYPE_BOOL:
			return "true" if bool(v) else "false"
		TYPE_INT:
			return str(int(v))
		TYPE_FLOAT:
			return _fmt_num(float(v))
	return str(v)


## Variant → 界面显示用的字符串。`str()` 是唯一对所有类型都成立的转换。
static func _to_str(v: Variant) -> String:
	return str(v)


## Variant → bool。字符串形态（`flag x true` 的位置参数）要能解出来，
## 不能直接 `bool("false")` —— 那会抛「Nonexistent 'bool' constructor.」。
static func _as_bool(v: Variant) -> bool:
	match typeof(v):
		TYPE_BOOL:
			return bool(v)
		TYPE_INT, TYPE_FLOAT:
			return float(v) != 0.0
		TYPE_STRING, TYPE_STRING_NAME:
			var s := String(v).strip_edges().to_lower()
			return s == "true" or s == "1" or s == "yes" or s == "on"
	return false


static func _fmt_num(f: float) -> String:
	if is_equal_approx(f, roundf(f)):
		return str(int(roundf(f)))
	return String.num(f, 2)


static func _indent_of(raw: String) -> String:
	var i := 0
	while i < raw.length() and (raw[i] == " " or raw[i] == "\t"):
		i += 1
	return raw.substr(0, i)


func _style_inline_edit(e: LineEdit, size: int, dim: bool = false) -> void:
	e.add_theme_font_override("font", EdTheme.mono() if dim else EdTheme.ui())
	e.add_theme_font_size_override("font_size", size)
	e.add_theme_stylebox_override("normal", EdTheme.sb(EdTheme.BG, 0, 7, 0))
	e.add_theme_stylebox_override("focus",
		EdTheme.sb(EdTheme.BG_ELEV, 0, 7, 0, EdTheme.ACCENT, 1))
	e.add_theme_color_override("font_color", EdTheme.TEXT_DIM if dim else EdTheme.TEXT)
	e.add_theme_color_override("font_placeholder_color", EdTheme.TEXT_FAINT)
	e.add_theme_color_override("caret_color", EdTheme.ACCENT)
	e.add_theme_color_override("selection_color", EdTheme.SEL_BG)


## 指令类型那一格的颜色 —— 按用途分类，八类在色相环上大致等距。
## 表在 `EdTheme.TAG_COLORS` 里（那里有配色理由与「CHAR/SAY 曾经同色」的教训）。
static func _tag_color(tag: String) -> Color:
	return EdTheme.tag_color(tag)


func _populate_exprs(opt: OptionButton, speaker: String, current: String) -> void:
	opt.clear()
	if speaker.is_empty():
		opt.add_item("—", 0)
		opt.disabled = true
		return
	opt.disabled = false
	opt.add_item("（默认）", 0)
	var exprs: PackedStringArray = _ed.index.char_all_exprs(speaker)
	var sel := 0
	for k in exprs.size():
		opt.add_item(String(exprs[k]), k + 1)
		if String(exprs[k]) == current:
			sel = k + 1
	if sel == 0 and not current.is_empty():
		opt.add_item("%s（缺素材）" % current, exprs.size() + 1)
		sel = exprs.size() + 1
	opt.select(sel)


## 该对白行关联的语音 id（往上找最近的 voice 指令，允许跨过空行与注释）
func _voice_of(no: int) -> String:
	var doc = _ed.doc
	var i := no - 2
	while i >= 0:
		var l := doc.lines[i] as LineIndex.Line
		if l.kind == LineIndex.Line.BLANK or l.kind == LineIndex.Line.COMMENT:
			i -= 1
			continue
		if l.kind == LineIndex.Line.DIRECTIVE and l.head == "voice":
			return l.args[0] if l.args.size() > 0 else ""
		break
	return ""
