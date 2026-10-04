extends Control

## 问题列表 —— 直接调 `ScriptAudit.audit()`，与 CI 校验同一套规则
##
## 这一块是「白送」的：项目里那 296 行校验规则（悬空跳转、重复结局 id、
## 死标签、没人设置的解锁旗标、空台词、carry 引用了不存在的旗标……）
## 本来就是纯静态函数，拿过来就是编辑器的实时校验内核，一行都不用改。
##
## 唯一的额外工作是把它的输出格式拆开：
## ScriptAudit 的消息形如 `文件名：消息`，行号可能藏在消息里的 `:27:`，
## 所以这里用正则把「文件名 + 行号」提出来，供点击跳转。

const EdTheme = preload("res://tools/editor/ed_theme.gd")
const ScriptAudit = preload("res://scripts/core/script_audit.gd")

signal issue_activated(file_name: String, line_no: int)

const MAX_ROWS := 200

var _summary: Label
var _list: VBoxContainer
var _issues: Array = []
var _last_audit_ms: int = -100000
const THROTTLE_MS := 400


func setup(_ed: Control) -> void:
	_build()


func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	# --- 标题行 ---
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	root.add_child(head)

	_summary = EdTheme.label("校验中…", EdTheme.FS_SMALL, EdTheme.TEXT_DIM)
	head.add_child(_summary)
	head.add_child(EdTheme.hfill())

	root.add_child(EdTheme.hline())

	# --- 列表 ---
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 1)
	scroll.add_child(_list)


# ---------------------------------------------------------------------------

## 重新校验。带节流 —— 击键会以每秒几十次的频率触发刷新，
## 而全量校验要读遍所有剧本文件，不节流会明显卡顿。
func refresh(force: bool = false) -> void:
	var now := Time.get_ticks_msec()
	if not force and now - _last_audit_ms < THROTTLE_MS:
		return
	_last_audit_ms = now

	var result := ScriptAudit.audit()
	var errors: Array = result.get("errors", [])
	var warnings: Array = result.get("warnings", [])

	_issues.clear()
	for e in errors:
		_issues.append(_parse(String(e), "error"))
	for w in warnings:
		_issues.append(_parse(String(w), "warn"))

	_render(errors.size(), warnings.size(), int(result.get("commands", 0)))


## 从 `文件名：消息` 里拆出文件名与行号
func _parse(text: String, level: String) -> Dictionary:
	var file_name := ""
	var line_no := 0

	# 行号：消息里的第一个 `:数字:`
	var re := RegEx.new()
	re.compile(":(\\d+):")
	var m := re.search(text)
	if m != null:
		line_no = m.get_string(1).to_int()

	# 文件名：以 .gvs / .json 结尾的片段
	var re2 := RegEx.new()
	re2.compile("([A-Za-z0-9_\\-]+\\.(?:gvs|json))")
	var m2 := re2.search(text)
	if m2 != null:
		file_name = m2.get_string(1)

	return {"text": text, "file": file_name, "line": line_no, "level": level}


func _render(error_count: int, warn_count: int, commands: int) -> void:
	for c in _list.get_children():
		c.queue_free()

	if error_count == 0:
		_summary.text = "0 错误 · %d 提醒 · 共 %d 条指令" % [warn_count, commands]
		_summary.add_theme_color_override("font_color", EdTheme.OK)
	else:
		_summary.text = "%d 错误 · %d 提醒 · 共 %d 条指令" % [error_count, warn_count, commands]
		_summary.add_theme_color_override("font_color", EdTheme.ERR)

	if _issues.is_empty():
		var ok := EdTheme.label("没有发现问题", EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
		_list.add_child(ok)
		return

	var shown := 0
	for issue in _issues:
		if shown >= MAX_ROWS:
			_list.add_child(EdTheme.label("…（还有 %d 条，已省略）"
				% (_issues.size() - MAX_ROWS), EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))
			break
		_list.add_child(_make_row(issue as Dictionary))
		shown += 1


## 一行问题。
##
## 用 `Button.text` 而不是往 Button 里塞 HBox —— **Button 不是 Container**，
## 它的子节点不会参与布局（size 会停在 0，整行看不见）。
## 想给行加色点/图标的话，得改用 HBoxContainer + 自己处理点击，
## 那样又会丢掉按钮的 hover / focus 反馈，不划算。
func _make_row(issue: Dictionary) -> Control:
	var level := String(issue.get("level", "warn"))
	var color := EdTheme.ERR if level == "error" else EdTheme.WARN
	var mark := "[错误] " if level == "error" else "[提醒] "

	var row := Button.new()
	row.text = mark + String(issue.get("text", ""))
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.clip_text = true
	row.flat = true
	row.custom_minimum_size = Vector2(0, 22)
	row.add_theme_font_override("font", EdTheme.ui())
	row.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	row.add_theme_color_override("font_color", color)
	row.add_theme_color_override("font_hover_color", Color.WHITE)
	row.add_theme_color_override("font_pressed_color", Color.WHITE)
	row.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 3, 6, 1))
	row.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 6, 1))
	row.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 6, 1))
	row.add_theme_stylebox_override("focus", EdTheme.sb(Color(0, 0, 0, 0), 3, 6, 1))

	row.tooltip_text = String(issue.get("text", ""))
	var file_name := String(issue.get("file", ""))
	var line_no := int(issue.get("line", 0))
	row.pressed.connect(func() -> void: issue_activated.emit(file_name, line_no))
	return row


func issue_count() -> int:
	return _issues.size()


## 某个剧本文件的问题，按行号归好组：{行号: [{"level","text"}]}
##
## 给剧本块的「行内错误标记」用。数据就是这里已经解析好的 `_issues`，
## 不额外跑一遍 `ScriptAudit.audit()`（那要读遍所有剧本，很贵）。
func issues_for_file(file_name: String) -> Dictionary:
	var out := {}
	if file_name.is_empty():
		return out
	for issue in _issues:
		var it: Dictionary = issue
		if String(it.get("file", "")) != file_name:
			continue
		var no := int(it.get("line", 0))
		if no <= 0:
			continue          # 没有行号的问题（如「结局 id 重复」）标不到行上
		if not out.has(no):
			out[no] = []
		(out[no] as Array).append({
			"level": String(it.get("level", "warn")),
			"text": String(it.get("text", "")),
		})
	return out


## 当前文件的问题总数（错误 / 提醒），给状态栏用
func count_for_file(file_name: String) -> Vector2i:
	var err := 0
	var warn := 0
	for issue in _issues:
		var it: Dictionary = issue
		if String(it.get("file", "")) != file_name:
			continue
		if String(it.get("level", "warn")) == "error":
			err += 1
		else:
			warn += 1
	return Vector2i(err, warn)
