extends Control

## 变量页：旗标 / 变量 / 好感度的清单
##
## 三栏目的：看全貌、揪静默错误、点一条跳过去。
## 判定逻辑全在 `core/var_index.gd`，这里只负责摆出来。
##
## 跑法：编辑器顶栏「变量」页。

const EdTheme = preload("res://tools/editor/ed_theme.gd")
const VarIndex = preload("res://tools/editor/core/var_index.gd")

var _ed: Control
var _input: LineEdit
var _hint: Label
var _only_bad: Button
var _list: VBoxContainer
var _scroll: ScrollContainer

var _data: Dictionary = {}


func setup(ed: Control) -> void:
	_ed = ed
	_build()


func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

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

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 1)
	_scroll.add_child(_list)


func on_shown() -> void:
	rescan()


## 重扫全部剧本。切到这一页时跑一次 —— 剧本改完切过来就能看到新的。
func rescan() -> void:
	_data = VarIndex.scan()
	_fill()


func focus_input() -> void:
	if _input != null:
		_input.call_deferred("grab_focus")


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

	var n_total := 0
	var n_bad := VarIndex.problem_count(_data)

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
			_list.add_child(_row(kind, name, entry, bad.get("%s/%s" % [kind, name], {})))
			n_total += 1

	if n_total == 0:
		var msg := "没有符合条件的变量"
		if _data.is_empty() or VarIndex.total(_data) == 0:
			msg = "剧本里还没有任何旗标 / 变量 / 好感度"
		_list.add_child(_pad(msg))

	_hint.text = "%d 个变量 · %d 个有问题" % [VarIndex.total(_data), n_bad]
	_hint.add_theme_color_override("font_color", EdTheme.WARN if n_bad > 0 else EdTheme.OK)


func _row(kind: String, name: String, entry: Dictionary, issue: Dictionary) -> Control:
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
	b.tooltip_text = _tip(kind, name, entry, issue)
	b.add_theme_font_override("font", EdTheme.mono())
	b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	b.add_theme_color_override("font_color", _color(entry, issue))
	b.add_theme_color_override("font_hover_color", EdTheme.ACCENT)
	b.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 3, 6, 1))
	b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 6, 1))
	b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 6, 1))

	var site := _first_site(entry)
	b.pressed.connect(func() -> void: _jump(site))
	return b


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
	lines.append("写：")
	for s in (entry.get("writes", []) as Array):
		lines.append("  %s" % _site_text(s))
	if (entry.get("writes", []) as Array).is_empty():
		lines.append("  （无）")
	lines.append("读：")
	for s in (entry.get("reads", []) as Array):
		lines.append("  %s" % _site_text(s))
	if (entry.get("reads", []) as Array).is_empty():
		lines.append("  （无）")
	lines.append("")
	lines.append("点一下跳到第一处")
	return "\n".join(PackedStringArray(lines))


static func _site_text(s: Variant) -> String:
	var d: Dictionary = s
	return "%s 第 %d 行  %s" % [
		String(d.get("file", "")).get_file(), int(d.get("line", 0)), String(d.get("raw", ""))]


## 优先跳到「写」，没有写就跳到「读」
static func _first_site(entry: Dictionary) -> Dictionary:
	var w: Array = entry.get("writes", [])
	if not w.is_empty():
		return w[0]
	var r: Array = entry.get("reads", [])
	if not r.is_empty():
		return r[0]
	return {}


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
	return l
