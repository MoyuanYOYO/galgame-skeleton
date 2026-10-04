extends Control

## 全局搜索 —— 跨全部剧本找素材 id / 台词 / 指令
##
## 为什么需要：素材改名、删素材、查一个 flag 到底在哪几处用过，
## 都是「先要看清全貌」的动作。以前只能一个文件一个文件 Ctrl+F。
## 这个面板把命中按「文件 · 行号 · 原文」列出来，点一条就跳过去。
##
## 两个细节：
##   1. **当前打开的文件读内存里的行**，不是磁盘 —— 手动保存模式下编辑器里
##      可能有未保存改动，按磁盘搜会搜出「我刚写的怎么搜不到」。
##   2. 大小写不敏感（作者搜 `Alice` 也想找到 `alice`），但**不做正则** ——
##      剧本里 `[](){}` 满地都是，正则反而容易写错。
##
## 跑法：编辑器顶栏「搜索」页，或 Ctrl+Shift+F。

const EdTheme = preload("res://tools/editor/ed_theme.gd")
const LineIndex = preload("res://tools/editor/core/line_index.gd")
const ScriptPaths = preload("res://scripts/core/script_paths.gd")
const ScriptStats = preload("res://scripts/core/script_stats.gd")

## 命中上限。超过就停下并提示「还有更多」—— 一屏几千个按钮既慢又没用。
const MAX_HITS := 800
const SNIPPET_PAD := 34

## 打字时的防抖。逐键全量扫一遍在剧本多了以后会卡（10 万字量级要几十毫秒）。
const DEBOUNCE_SEC := 0.25

var _ed: Control
var _query: LineEdit
var _hint: Label
var _list: VBoxContainer
var _scroll: ScrollContainer
var _debounce: Timer

var _results: Array = []


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

	_query = LineEdit.new()
	_query.placeholder_text = "搜索素材 id / 台词 / 指令…（Ctrl+Shift+F）"
	_query.custom_minimum_size = Vector2(320, 0)
	_query.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	EdTheme.style_line_edit(_query)
	_query.text_changed.connect(func(_t: String) -> void: _debounce.start())
	_query.text_submitted.connect(func(_t: String) -> void: _run())
	h.add_child(_query)

	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = DEBOUNCE_SEC
	_debounce.timeout.connect(_run)
	add_child(_debounce)

	var btn := EdTheme.chip("搜索")
	btn.pressed.connect(_run)
	h.add_child(btn)

	_hint = EdTheme.label("输入关键词开始搜索", EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	h.add_child(_hint)

	# --- 结果 ---
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 1)
	_scroll.add_child(_list)


## 切到这一页时让输入框直接拿到焦点 —— 搜完一轮回来接着搜是常态
func on_shown() -> void:
	if _query != null:
		_query.call_deferred("grab_focus")


func focus_input() -> void:
	if _query == null:
		return
	_query.call_deferred("grab_focus")
	_query.select_all()


# ---------------------------------------------------------------------------
# 搜索
# ---------------------------------------------------------------------------

func _run() -> void:
	var q := _query.text.strip_edges()
	_clear()
	_results = []
	if q.is_empty():
		_hint.text = "输入关键词开始搜索"
		_hint.add_theme_color_override("font_color", EdTheme.TEXT_FAINT)
		return

	var needle := q.to_lower()
	var files := ScriptStats.script_files()
	var truncated := false

	for p in files:
		var logical := String(p)
		var raws := _lines_of(logical)
		for i in raws.size():
			if _results.size() >= MAX_HITS:
				truncated = true
				break
			var raw := String(raws[i])
			if raw.strip_edges().is_empty():
				continue
			var at := raw.to_lower().find(needle)
			if at < 0:
				continue
			_results.append({
				"file": logical.get_file(),
				"path": logical,
				"line": i + 1,
				"raw": raw,
				"at": at,
			})
		if truncated:
			break

	for r in _results:
		_list.add_child(_row(r as Dictionary, q.length()))

	if _results.is_empty():
		_hint.text = "没有命中"
		_hint.add_theme_color_override("font_color", EdTheme.WARN)
		_list.add_child(_empty_row("没有命中「%s」" % q))
		return
	_hint.text = "%d 处命中%s · 搜了 %d 个剧本" % [
		_results.size(), "（已截断）" if truncated else "", files.size()]
	_hint.add_theme_color_override("font_color", EdTheme.OK)


## 某个剧本的原始行。当前打开的那个读**内存**（可能有未保存改动）。
func _lines_of(logical: String) -> PackedStringArray:
	if _ed.doc != null and _ed.doc.path == logical:
		var out := PackedStringArray()
		for l in _ed.doc.lines:
			out.append(String((l as LineIndex.Line).raw))
		return out
	return FileAccess.get_file_as_string(ScriptPaths.resolve(logical)).split("\n")


func _row(r: Dictionary, qlen: int) -> Control:
	var raw := String(r.get("raw", ""))
	var at := int(r.get("at", 0))
	var snippet := _snippet(raw, at, qlen)

	var b := Button.new()
	b.text = "%s:%d  │  %s" % [String(r.get("file", "")), int(r.get("line", 0)), snippet]
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.custom_minimum_size = Vector2(0, 22)
	b.tooltip_text = "%s 第 %d 行\n%s" % [
		String(r.get("file", "")), int(r.get("line", 0)), raw.strip_edges()]
	b.add_theme_font_override("font", EdTheme.mono())
	b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	b.add_theme_color_override("font_color", EdTheme.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", EdTheme.ACCENT)
	b.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 3, 6, 1))
	b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 6, 1))
	b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 6, 1))

	var path := String(r.get("path", ""))
	var no := int(r.get("line", 0))
	b.pressed.connect(func() -> void:
		_ed._open_at_file(String(path).get_file())
		_ed.goto_source(no))
	return b


## 命中位置前后各留一点上下文。命中在很靠后时从命中处往前截，
## 否则长行前面的缩进会把关键词挤出屏幕。
static func _snippet(raw: String, at: int, qlen: int) -> String:
	var s := raw.strip_edges()
	if s.length() <= SNIPPET_PAD * 2:
		return s
	var start := maxi(0, at - SNIPPET_PAD)
	var end := mini(s.length(), at + qlen + SNIPPET_PAD)
	var head := "…" if start > 0 else ""
	var tail := "…" if end < s.length() else ""
	return head + s.substr(start, end - start) + tail


func _empty_row(text: String) -> Control:
	var l := EdTheme.label(text, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	l.custom_minimum_size = Vector2(0, 28)
	return l


func _clear() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
