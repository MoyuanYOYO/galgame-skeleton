extends Control

## 变量页：旗标 / 变量 / 好感度的清单 + **右侧「引用」侧边栏**
##
## 三栏目的：看全貌、揪静默错误、**看这一条到底在哪儿被读写、点一条跳过去**。
## 判定逻辑全在 `core/var_index.gd`，这里只负责摆出来。
##
## 交互（用户定的）：
##   · **单击 = 选中**，右侧侧边栏列出它的全部读写位置，每条可点着跳过去
##   · 变量行本身**不再跳转** —— 跳转由侧边栏承担，一行有十几处引用时
##     「点一下跳到第一处」根本不够用，而且「点一下」与「选中看详情」会打架
##
## 跑法：编辑器侧栏「变量」标题旁的「详细」进。

const EdTheme = preload("res://tools/editor/ed_theme.gd")
const VarIndex = preload("res://tools/editor/core/var_index.gd")

var _ed: Control
var _input: LineEdit
var _hint: Label
var _only_bad: Button
var _list: VBoxContainer
var _scroll: ScrollContainer

## 右侧引用栏
var _refs_title: Label
var _refs_meta: Label
var _refs_list: VBoxContainer

var _data: Dictionary = {}
## 当前选中的变量（`kind` / `name`）。空 = 还没选
var _sel_kind: String = ""
var _sel_name: String = ""


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
	h.add_theme_constant_override("separation", 8)
	bar.add_child(h)

	_hint = EdTheme.label("", EdTheme.FS_SMALL, EdTheme.TEXT_DIM)
	h.add_child(_hint)
	h.add_child(EdTheme.hfill())

	_only_bad = EdTheme.chip("只看有问题的")
	_only_bad.toggle_mode = true
	_only_bad.tooltip_text = "只列出「只读不写」和「只写不读」的变量"
	_only_bad.toggled.connect(func(_on: bool) -> void: _fill())
	h.add_child(_only_bad)

	_input = LineEdit.new()
	_input.placeholder_text = "过滤名字…"
	_input.custom_minimum_size = Vector2(180, 0)
	EdTheme.style_line_edit(_input)
	_input.text_changed.connect(func(_t: String) -> void: _fill())
	h.add_child(_input)

	# --- 左：变量清单；右：引用 ---
	# 用 HSplitContainer 而不是固定比例 —— 引用行的原文可能很长，
	# 作者想拉宽一点看的时候不该被代码拦住。
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 6)
	# ⚠️ `split_offset` 是**相对第一个子控件最小宽度**的偏移。左边是
	# ScrollContainer（最小宽度 0），不给偏移的话分隔线会贴到最左边 ——
	# 变量清单被挤成一条缝，侧边栏反而占掉整个宽度。
	split.split_offset = 420
	root.add_child(split)

	_scroll = ScrollContainer.new()
	# 给个下限，免得拖分隔线时把清单压到看不见
	_scroll.custom_minimum_size = Vector2(220, 0)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 1)
	_scroll.add_child(_list)

	split.add_child(_build_refs())


## 右侧「引用」栏：标题 + 判定摘要 + 写 / 读 两组可点击的位置
func _build_refs() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	panel.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_PANEL, 8, 10, 8, EdTheme.BORDER, 1))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)

	_refs_title = EdTheme.label("引用", EdTheme.FS_UI, EdTheme.ACCENT)
	box.add_child(_refs_title)

	_refs_meta = EdTheme.label("", EdTheme.FS_SMALL, EdTheme.TEXT_DIM)
	_refs_meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_refs_meta)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	_refs_list = VBoxContainer.new()
	_refs_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_refs_list.add_theme_constant_override("separation", 1)
	scroll.add_child(_refs_list)

	return panel


func on_shown() -> void:
	rescan()


## 重扫全部剧本。切到这一页时跑一次 —— 剧本改完切过来就能看到新的。
##
## `files` 非空时只扫这些（测试用）—— 与 `VarIndex.scan` 自己的钩子一致，
## 否则测试只能依赖项目里真实剧本的内容，改一句台词就红。
func rescan(files := PackedStringArray()) -> void:
	_data = VarIndex.scan(files)
	_fill()


func focus_input() -> void:
	if _input != null:
		_input.call_deferred("grab_focus")


# ---------------------------------------------------------------------------
# 左侧清单
# ---------------------------------------------------------------------------

func _fill() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()

	var filter := _input.text.strip_edges().to_lower()
	var only_bad := _only_bad.button_pressed
	var issues: Array = VarIndex.issues(_data)
	var bad := {}
	for it in issues:
		var d: Dictionary = it
		bad["%s/%s" % [d["kind"], d["name"]]] = d

	# 单选组：整页只允许一个变量处于选中态
	var group := ButtonGroup.new()

	var n_total := 0
	var n_bad := VarIndex.problem_count(_data)
	var first_key := ""

	for kind in VarIndex.KINDS:
		var table: Dictionary = _data.get(kind, {})
		var names: Array = table.keys()
		names.sort()

		var rows: Array = []
		for nm in names:
			var name := String(nm)
			var key := "%s/%s" % [kind, name]
			var it: Dictionary = bad.get(key, {})
			# 「只看有问题的」把 info 也滤掉 —— info 是「引擎侧有同名，应该没问题」
			if only_bad and (it.is_empty() or String(it.get("level", "")) == "info"):
				continue
			if not filter.is_empty() and not name.to_lower().contains(filter):
				continue
			rows.append(name)
		if rows.is_empty():
			continue

		_list.add_child(_section("%s（%d）" % [VarIndex.LABELS[kind], table.size()]))
		for nm in rows:
			var name := String(nm)
			var entry: Dictionary = table[name]
			if first_key.is_empty():
				first_key = "%s/%s" % [kind, name]
			_list.add_child(_row(kind, name, entry, bad.get("%s/%s" % [kind, name], {}), group))
			n_total += 1

	if n_total == 0:
		var msg := "没有符合条件的变量"
		if _data.is_empty() or VarIndex.total(_data) == 0:
			msg = "剧本里还没有任何旗标 / 变量 / 好感度"
		_list.add_child(_pad(msg))

	_hint.text = "%d 个变量 · %d 个有问题" % [VarIndex.total(_data), n_bad]
	_hint.add_theme_color_override("font_color", EdTheme.WARN if n_bad > 0 else EdTheme.TEXT_DIM)

	# 选中项可能被过滤掉了（或者压根还没选）→ 落到第一行，
	# 免得右侧一直空着像坏了一样。`_fill` 之后 `_select` 会重建右侧内容。
	if not _still_present():
		_sel_kind = ""
		_sel_name = ""
		if not first_key.is_empty():
			var parts := first_key.split("/", true, 1)
			_sel_kind = String(parts[0])
			_sel_name = String(parts[1]) if parts.size() > 1 else ""
	_show_refs()


## 当前选中的变量还在（且没被过滤掉）吗
func _still_present() -> bool:
	if _sel_name.is_empty():
		return false
	return (_data.get(_sel_kind, {}) as Dictionary).has(_sel_name)


func _row(kind: String, name: String, entry: Dictionary, issue: Dictionary,
		group: ButtonGroup) -> Control:
	var b := Button.new()
	var lv := String(issue.get("level", ""))
	var mark := ""
	if lv == "error":
		mark = "✕ "
	elif lv == "warn":
		mark = "⚠ "
	elif lv == "info":
		mark = "· "
	b.text = "%s%s　%s" % [mark, name, VarIndex.summary(entry)]
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, 22)
	b.clip_text = true
	b.tooltip_text = _tip(kind, name, entry, issue)
	b.add_theme_font_override("font", EdTheme.mono())
	b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	b.add_theme_color_override("font_color", _color(entry, issue))
	b.add_theme_color_override("font_hover_color", EdTheme.ACCENT)
	b.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 3, 6, 1))
	b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 6, 1))
	b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 6, 1))

	# 单选：点一条就把别条弹起来。用 `toggle_mode` + `ButtonGroup` 而不是
	# 自己管高亮 —— 自管的话「点同一条两次」会把选中态弄丢。
	b.toggle_mode = true
	b.button_group = group
	var is_sel := kind == _sel_kind and name == _sel_name
	b.set_pressed_no_signal(is_sel)
	b.toggled.connect(func(on: bool) -> void:
		if not on:
			return
		_sel_kind = kind
		_sel_name = name
		_show_refs())
	return b


# ---------------------------------------------------------------------------
# 右侧引用栏
# ---------------------------------------------------------------------------

func _show_refs() -> void:
	for c in _refs_list.get_children():
		_refs_list.remove_child(c)
		c.queue_free()

	if _sel_name.is_empty():
		_refs_title.text = "引用"
		_refs_meta.text = "点左边一个变量，这里列出它被读写的位置。"
		return

	var entry: Dictionary = (_data.get(_sel_kind, {}) as Dictionary).get(_sel_name, {})
	var issue: Dictionary = {}
	for it in VarIndex.issues(_data):
		var d: Dictionary = it
		if String(d.get("kind", "")) == _sel_kind and String(d.get("name", "")) == _sel_name:
			issue = d
			break

	_refs_title.text = "%s「%s」" % [VarIndex.LABELS.get(_sel_kind, _sel_kind), _sel_name]
	var meta: Array = [VarIndex.summary(entry)]
	if not issue.is_empty():
		meta.append(String(issue.get("message", "")))
	_refs_meta.text = "\n".join(PackedStringArray(meta))
	var lv := String(issue.get("level", ""))
	_refs_meta.add_theme_color_override("font_color",
		EdTheme.ERR if lv == "error" else (EdTheme.WARN if lv == "warn" else EdTheme.TEXT_DIM))

	_add_site_group("写（%d）" % (entry.get("writes", []) as Array).size(),
		entry.get("writes", []), "没写过 —— 只读不写，多半是名字拼错了")
	_add_site_group("读（%d）" % (entry.get("reads", []) as Array).size(),
		entry.get("reads", []), "没人读过 —— 只写不读，是不是忘了接条件？")


func _add_site_group(title: String, sites: Array, empty_hint: String) -> void:
	var l := EdTheme.label(title, EdTheme.FS_SMALL, EdTheme.ACCENT)
	l.custom_minimum_size = Vector2(0, 22)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_refs_list.add_child(l)

	if sites.is_empty():
		_refs_list.add_child(_pad("　%s" % empty_hint))
		return

	for s in sites:
		_refs_list.add_child(_site_row(s))


## 一条引用位置。点一下跳到那一行。
func _site_row(site: Variant) -> Control:
	var d: Dictionary = site
	var line := int(d.get("line", 0))
	var file := String(d.get("file", ""))
	var raw := String(d.get("raw", "")).strip_edges()

	var b := Button.new()
	b.text = "%s · 第 %d 行　%s" % [file.get_file(), line, raw]
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, 20)
	b.clip_text = true
	b.add_theme_font_override("font", EdTheme.mono())
	b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	b.add_theme_color_override("font_color", EdTheme.TEXT)
	b.add_theme_color_override("font_hover_color", EdTheme.ACCENT)
	b.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 3, 5, 1))
	b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 5, 1))
	b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 5, 1))
	# 原文可能很长，被 `clip_text` 截掉 —— 完整内容放 tooltip
	b.tooltip_text = "%s 第 %d 行\n%s\n\n点一下跳过去" % [file, line, raw]
	b.pressed.connect(func() -> void: _jump(d))
	return b


# ---------------------------------------------------------------------------

func _color(entry: Dictionary, issue: Dictionary) -> Color:
	var lv := String(issue.get("level", ""))
	if lv == "error":
		return EdTheme.ERR
	if lv == "warn":
		return EdTheme.WARN
	if lv == "info":
		return EdTheme.TEXT_FAINT
	if (entry.get("reads", []) as Array).is_empty():
		return EdTheme.TEXT_DIM
	return EdTheme.TEXT


func _tip(kind: String, name: String, entry: Dictionary, issue: Dictionary) -> String:
	var lines: Array = ["%s「%s」" % [VarIndex.LABELS[kind], name], VarIndex.summary(entry)]
	if not issue.is_empty():
		lines.append(String(issue.get("message", "")))
	lines.append("")
	lines.append("点一下：右侧列出全部读写位置")
	return "\n".join(PackedStringArray(lines))


func _jump(site: Dictionary) -> void:
	if site.is_empty():
		return
	_ed._open_at_file(String(site.get("file", "")))
	_ed.goto_source(int(site.get("line", 1)))


func _section(text: String) -> Control:
	var l := EdTheme.label(text, EdTheme.FS_SMALL, EdTheme.ACCENT)
	l.custom_minimum_size = Vector2(0, 24)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _pad(text: String) -> Control:
	var l := EdTheme.label(text, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	l.custom_minimum_size = Vector2(0, 28)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l
