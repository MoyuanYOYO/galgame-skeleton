extends Control

## 翻译中心
##
## 项目的 i18n 机制有个特点：**中文原文就是 key**，`data/i18n/en.json`
## 只存差异（见 en.json 的 `_comment`）。所以这里的核心不是「管理 key」，
## 而是**找出漏翻** —— 漏一条只会让那句保持中文，不报错、不崩溃，
## 属于最容易长期潜伏的那类问题。
##
## 三件事：
##   1. **界面文案** —— 从 .tscn / .gd 里扫出所有中文文案，对照翻译表列缺失
##   2. **剧本台词** —— 列出全部台词原文（供译者拿去做参考/对照）
##   3. **编辑译文** —— 直接改翻译表并写回 json
##
## 不做的：**剧本多语言的行对齐**。那是 DESIGN 里明确列出的已知限制，
## 真正的难点是「原文改一行，译文全错位」，不是翻译本身，
## 需要单独的段落对齐工具，不适合塞进这个面板。

const EdTheme = preload("res://tools/editor/ed_theme.gd")
const JsonUtil = preload("res://scripts/core/json_util.gd")
const LineIndex = preload("res://tools/editor/core/line_index.gd")

const I18N_DIR := "res://data/i18n/"
const SOURCE_LANG := "zh_CN"

var _ed: Control
var _tab := 0                      # 0 = 界面文案，1 = 剧本台词
var _lang := "en"
var _stat: Label
var _body: VBoxContainer
var _search: LineEdit
var _scroll: ScrollContainer

var _ui_keys: Array = []           # [{key, source, where:[]}]
var _table: Dictionary = {}        # 当前语言的翻译表
var _editing: Dictionary = {}      # key → LineEdit（用于写回）


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

	_stat = EdTheme.label("", EdTheme.FS_SMALL, EdTheme.TEXT_DIM)
	h.add_child(_stat)
	h.add_child(_vsep())

	for spec in [["界面文案", 0], ["剧本台词", 1]]:
		var b := EdTheme.chip(String(spec[0]))
		var idx := int(spec[1])
		b.pressed.connect(func() -> void:
			_tab = idx
			rebuild())
		h.add_child(b)
		_chips.append(b)

	h.add_child(EdTheme.hfill())

	_search = LineEdit.new()
	_search.placeholder_text = "搜索文案…"
	_search.custom_minimum_size = Vector2(200, 0)
	EdTheme.style_line_edit(_search)
	_search.text_changed.connect(func(_t: String) -> void: rebuild())
	h.add_child(_search)

	var btn_scan := EdTheme.chip("重新扫描")
	btn_scan.pressed.connect(func() -> void:
		_scan()
		rebuild())
	h.add_child(btn_scan)

	var btn_save := EdTheme.chip("保存翻译")
	btn_save.pressed.connect(_save)
	h.add_child(btn_save)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 1)
	_scroll.add_child(_body)


var _chips: Array = []


func _vsep() -> Control:
	var s := VSeparator.new()
	s.add_theme_stylebox_override("separator", EdTheme.sb(EdTheme.BORDER, 0, 0, 0))
	s.custom_minimum_size = Vector2(1, 0)
	return s


func on_shown() -> void:
	if _ui_keys.is_empty():
		_scan()
	rebuild()


# ---------------------------------------------------------------------------
# 扫描
# ---------------------------------------------------------------------------

## 扫 .tscn 与 .gd，把「中文原文」捞出来。
##
## 两类来源：
##   .tscn  `text = "开始游戏"`              界面上的静态文字
##   .gd    `I18n.t("开始游戏")`             代码里的动态文案
##          `I18n.set_text(node, "开始游戏")`
##
## 判断「是不是中文」用码点区间，不依赖正则的 Unicode 支持 ——
## Godot 的 RegEx 对 \u 转义的支持不稳定，用字符码判断更可靠。
func _scan() -> void:
	_ui_keys.clear()
	_load_table()

	var seen: Dictionary = {}
	for path in _collect_files("res://scenes", ".tscn"):
		_scan_text_file(path, seen, true)
	for path in _collect_files("res://scripts", ".gd"):
		_scan_text_file(path, seen, false)

	var keys: Array = seen.keys()
	keys.sort()
	for k in keys:
		_ui_keys.append(seen[k])


func _collect_files(root: String, ext: String, out: Array = []) -> Array:
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	for f in dir.get_files():
		if String(f).ends_with(ext):
			out.append(root + "/" + String(f))
	for d in dir.get_directories():
		_collect_files(root + "/" + String(d), ext, out)
	return out


func _scan_text_file(path: String, seen: Dictionary, is_scene: bool) -> void:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return
	var short := path.replace("res://", "")
	for raw_line in text.split("\n"):
		var line := String(raw_line)
		if not _has_cjk(line):
			continue
		# 注释行跳过（作者注释不需要翻译）
		var stripped := line.strip_edges()
		if stripped.begins_with("#") or stripped.begins_with("//"):
			continue

		if is_scene:
			# `text = "开始游戏"`
			var i := line.find("text = \"")
			if i == -1:
				continue
			var body := _quoted(line, i + 8)
			if not body.is_empty() and _has_cjk(body):
				_add_key(seen, body, short)
		else:
			for marker in ["I18n.t(\"", "set_text("]:
				var m := String(marker)
				var idx := line.find(m)
				while idx != -1:
					var start: int = idx + m.length()
					if m == "set_text(":
						# set_text(node, "文案") —— 跳到逗号后的引号
						var q := line.find("\"", start)
						if q == -1:
							break
						start = q + 1
					var body2 := _quoted_from(line, start)
					if not body2.is_empty() and _has_cjk(body2):
						_add_key(seen, body2, short)
					idx = line.find(m, start)


static func _quoted(line: String, from: int) -> String:
	# from 指向引号之后
	var end := line.find("\"", from)
	if end == -1:
		return ""
	return line.substr(from, end - from)


static func _quoted_from(line: String, from: int) -> String:
	var end := line.find("\"", from)
	if end == -1:
		return ""
	return line.substr(from, end - from)


static func _add_key(seen: Dictionary, key: String, where: String) -> void:
	if key.strip_edges().is_empty():
		return
	if not seen.has(key):
		seen[key] = {"key": key, "where": []}
	((seen[key] as Dictionary)["where"] as Array).append(where)


static func _has_cjk(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		# CJK 统一表意文字（含扩展 A）
		if (c >= 0x4E00 and c <= 0x9FFF) or (c >= 0x3400 and c <= 0x4DBF):
			return true
	return false


func _load_table() -> void:
	_table = {}
	var p := I18N_DIR + _lang + ".json"
	var raw: Variant = JsonUtil.load_json(p)
	if typeof(raw) == TYPE_DICTIONARY:
		_table = raw as Dictionary


# ---------------------------------------------------------------------------
# 渲染
# ---------------------------------------------------------------------------

func rebuild() -> void:
	if _body == null:
		return
	for i in range(_chips.size()):
		EdTheme.style_chip(_chips[i] as Button, i == _tab)
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()

	var filter := _search.text.strip_edges().to_lower()

	if _tab == 0:
		_render_ui(filter)
	else:
		_render_script(filter)


func _render_ui(filter: String) -> void:
	_load_table()
	_editing.clear()

	var missing := 0
	var shown := 0
	for entry in _ui_keys:
		var e: Dictionary = entry
		var key := String(e["key"])
		if not filter.is_empty() and not key.to_lower().contains(filter):
			continue
		shown += 1
		var translated := String(_table.get(key, ""))
		if translated.is_empty():
			missing += 1
		_body.add_child(_ui_row(key, translated, e["where"] as Array))

	_stat.text = "界面文案 %d 条 · 漏翻 %d 条 · 目标语言 %s.json" % [
		_ui_keys.size(), missing, _lang]


func _ui_row(key: String, translated: String, where: Array) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	row.custom_minimum_size = Vector2(0, 28)

	var src := EdTheme.label(key, EdTheme.FS_UI, EdTheme.TEXT)
	src.custom_minimum_size = Vector2(300, 0)
	src.clip_text = true
	src.tooltip_text = "来源：%s" % ", ".join(where)
	row.add_child(src)

	var edit := LineEdit.new()
	edit.text = translated
	edit.placeholder_text = "（未翻译）"
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.add_theme_font_override("font", EdTheme.ui())
	edit.add_theme_font_size_override("font_size", EdTheme.FS_UI)
	edit.add_theme_stylebox_override("normal",
		EdTheme.sb(EdTheme.BG if translated.is_empty() else EdTheme.BG_ELEV, 0, 8, 0))
	edit.add_theme_stylebox_override("focus",
		EdTheme.sb(EdTheme.BG_ELEV, 0, 8, 0, EdTheme.ACCENT, 1))
	edit.add_theme_color_override("font_color",
		EdTheme.TEXT if not translated.is_empty() else EdTheme.WARN)
	edit.add_theme_color_override("font_placeholder_color", EdTheme.TEXT_FAINT)
	edit.add_theme_color_override("caret_color", EdTheme.ACCENT)
	_editing[key] = edit
	row.add_child(edit)

	var mark := EdTheme.label("缺" if translated.is_empty() else "✓",
		EdTheme.FS_SMALL, EdTheme.WARN if translated.is_empty() else EdTheme.OK)
	mark.custom_minimum_size = Vector2(34, 0)
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(mark)

	return row


func _render_script(filter: String) -> void:
	var doc = _ed.doc
	if doc == null:
		return
	var says := 0
	var chars := 0
	for l in doc.lines:
		var line := l as LineIndex.Line
		if not line.is_say():
			continue
		if not filter.is_empty() and not line.text.to_lower().contains(filter):
			continue
		says += 1
		chars += line.text.length()
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		row.custom_minimum_size = Vector2(0, 24)

		var no_l := EdTheme.mono_label(str(line.no), EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
		no_l.custom_minimum_size = Vector2(46, 0)
		row.add_child(no_l)

		var who := EdTheme.label(line.speaker if not line.speaker.is_empty() else "旁白",
			EdTheme.FS_SMALL, EdTheme.SYN_SPEAKER)
		who.custom_minimum_size = Vector2(88, 0)
		who.clip_text = true
		row.add_child(who)

		var txt := EdTheme.label(line.text, EdTheme.FS_UI, EdTheme.TEXT)
		txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		txt.clip_text = true
		txt.tooltip_text = line.text
		row.add_child(txt)

		_body.add_child(row)

	_stat.text = "%s · %d 句 · 共 %d 字（供译者参考；剧本多语言需另做段落对齐）" % [
		doc.path.get_file(), says, chars]


# ---------------------------------------------------------------------------
# 保存
# ---------------------------------------------------------------------------

func _save() -> void:
	if _editing.is_empty():
		_ed._notice_flash("没有可保存的改动", EdTheme.WARN)
		return
	_load_table()
	var changed := 0
	for key in _editing.keys():
		var edit: LineEdit = _editing[key]
		# rebuild 会 remove_child + queue_free 旧的输入框；若这里还握着
		# 已释放的引用，访问 .text 就是 "previously freed instance"。
		if not is_instance_valid(edit):
			continue
		var val := edit.text.strip_edges()
		var old := String(_table.get(String(key), ""))
		if val == old:
			continue
		if val.is_empty():
			_table.erase(key)
		else:
			_table[key] = val
		changed += 1

	if changed == 0:
		_ed._notice_flash("没有改动", EdTheme.WARN)
		return

	var path := I18N_DIR + _lang + ".json"
	if JsonUtil.save_json(path, _table):
		_ed._notice_flash("已保存 %d 条翻译到 %s" % [changed, path.get_file()], EdTheme.OK)
		rebuild()
	else:
		_ed._notice_flash("保存失败：%s" % path, EdTheme.ERR)
