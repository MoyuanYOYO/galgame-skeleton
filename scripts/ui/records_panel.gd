class_name RecordsPanel
extends Control

## 记录面板：结局收集 / 路线图 / 已读率 / 章节选择
##
## 整个面板由代码搭出来，不改 main.tscn 的结构 ——
## 这几块内容的排版会经常调，代码里改比在场景里拖快得多。
##
## 四块内容放在同一页里（而不是做成标签页）：
## 它们本来就是「这一周目走到哪了」的四个侧面，摊开看比来回切更有信息量。

signal chapter_requested(file: String, label: String)
signal closed()

const PANEL_SIZE := Vector2(1420.0, 860.0)
const ENDING_CARD := Vector2(240.0, 150.0)
const ENDING_COLUMNS := 4

var _dim: ColorRect
var _panel: PanelContainer
var _title: Label
var _close_button: Button
var _body: VBoxContainer


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	_dim = ColorRect.new()
	_dim.color = Color(0.02, 0.02, 0.05, 0.72)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = PANEL_SIZE
	UiTheme.apply_panel(_panel, "default")
	center.add_child(_panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 18)
	_panel.add_child(outer)

	outer.add_child(_make_header())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 26)
	scroll.add_child(_body)


func present() -> void:
	_rebuild()
	visible = true


func hide_panel() -> void:
	visible = false
	closed.emit()


# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------

func _make_header() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)

	_title = Label.new()
	_title.text = "记 录"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UiTheme.apply_label(_title, UiTheme.TEXT, 32)
	row.add_child(_title)

	_close_button = Button.new()
	_close_button.text = "关闭"
	UiTheme.apply_button(_close_button, "default")
	_close_button.pressed.connect(hide_panel)
	row.add_child(_close_button)
	return row


func _rebuild() -> void:
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()

	_body.add_child(_make_progress_section())
	_body.add_child(_make_chapter_section())
	_body.add_child(_make_ending_section())
	_body.add_child(_make_route_section())


## 顶部概览：已读率 + 结局进度
func _make_progress_section() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)

	var total := ScriptStats.total_lines()
	var read := ReadTracker.read_count()
	var rate := 0.0 if total <= 0 else minf(1.0, float(read) / float(total))

	var line := Label.new()
	line.text = "已读 %d / %d 句（%.0f%%）" % [read, total, rate * 100.0]
	UiTheme.apply_label(line, UiTheme.TEXT, 22)
	box.add_child(line)

	var bar := ProgressBar.new()
	bar.max_value = 1.0
	bar.value = rate
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0.0, 14.0)
	box.add_child(bar)

	var endings := CollectionManager.get_progress("endings")
	var ending_line := Label.new()
	ending_line.text = "结局 %d / %d　·　CG %d / %d　·　音乐 %d / %d" % [
		endings.x, endings.y,
		CollectionManager.get_progress("cg").x, CollectionManager.get_progress("cg").y,
		CollectionManager.get_progress("music").x, CollectionManager.get_progress("music").y,
	]
	UiTheme.apply_label(ending_line, UiTheme.TEXT_DIM, 20)
	box.add_child(ending_line)

	# 已读记录和路线记录都存在 user:// 下、和存档分离，
	# 给玩家一个「清空」的出口（不然测试或重玩时没法重置）
	var clear_row := HBoxContainer.new()
	clear_row.add_theme_constant_override("separation", 12)
	var clear_button := Button.new()
	clear_button.text = "清空已读记录"
	UiTheme.apply_button(clear_button, "small")
	clear_button.pressed.connect(_on_clear_read)
	clear_row.add_child(clear_button)
	box.add_child(clear_row)
	return box


## 章节选择
func _make_chapter_section() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.add_child(_make_section_title("章节选择"))

	var chapters := ScriptStats.chapters()
	if chapters.is_empty():
		box.add_child(_make_hint("chapters.json 里没有章节"))
		return box

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	for entry in chapters:
		var chapter: Dictionary = entry
		var available := RouteTracker.is_chapter_available(chapter)
		var visited := RouteTracker.has_visited(String(chapter.get("id", "")))

		var button := Button.new()
		button.custom_minimum_size = Vector2(360.0, 96.0)
		button.text = "%s%s\n%s" % [
			String(chapter.get("title", "")),
			"" if visited else "（未读）",
			String(chapter.get("subtitle", "")),
		]
		button.disabled = not available
		UiTheme.apply_button(button, "default")
		if available:
			button.pressed.connect(_on_chapter_pressed.bind(chapter))
		row.add_child(button)
	box.add_child(row)
	return box


## 结局收集：解锁的显示标题，未解锁显示 ???
func _make_ending_section() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.add_child(_make_section_title("结局收集"))

	var items := CollectionRegistry.get_items("endings")
	if items.is_empty():
		box.add_child(_make_hint("endings.json 里没有条目"))
		return box

	var grid := GridContainer.new()
	grid.columns = ENDING_COLUMNS
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 16)

	for entry in items:
		var item: Dictionary = entry
		var id := String(item.get("id", ""))
		var unlocked := CollectionManager.is_unlocked("endings", id)

		var card := PanelContainer.new()
		card.custom_minimum_size = ENDING_CARD
		UiTheme.apply_panel(card, "default")

		var text := VBoxContainer.new()
		text.add_theme_constant_override("separation", 6)
		text.alignment = BoxContainer.ALIGNMENT_CENTER

		var name_label := Label.new()
		name_label.text = String(item.get("title", id)) if unlocked else "？？？"
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UiTheme.apply_label(name_label, UiTheme.TEXT if unlocked else UiTheme.TEXT_DIM, 21)
		text.add_child(name_label)

		var hint := Label.new()
		hint.text = String(item.get("hint", "")) if unlocked else "尚未抵达"
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UiTheme.apply_label(hint, UiTheme.TEXT_DIM, 18)
		text.add_child(hint)

		card.add_child(text)
		grid.add_child(card)

	box.add_child(grid)
	return box


## 路线图：列出每个选项点 + 玩家当时选了什么
func _make_route_section() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.add_child(_make_section_title("路线图"))

	var choices := ScriptStats.choices()
	if choices.is_empty():
		box.add_child(_make_hint("剧本里还没有选项"))
		return box

	var picked_total := 0
	for entry in choices:
		var node: Dictionary = entry
		var file := String(node.get("file", ""))
		var label := String(node.get("label", ""))
		var picked := RouteTracker.get_pick(file, label)
		var options: Array = node.get("options", [])
		if picked >= 0:
			picked_total += 1

		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 4)

		var head := Label.new()
		head.text = "%s · %s" % [file, label if not label.is_empty() else "（无标签）"]
		UiTheme.apply_label(head, UiTheme.TEXT_DIM, 18)
		row.add_child(head)

		for i in options.size():
			var opt := Label.new()
			var mark := "▸" if i == picked else "　"
			opt.text = "%s %s" % [mark, String(options[i])]
			UiTheme.apply_label(opt,
				UiTheme.ACCENT if i == picked else UiTheme.TEXT_DIM, 20)
			row.add_child(opt)

		box.add_child(row)

	var summary := Label.new()
	summary.text = "共 %d 个选项点，走过 %d 个" % [choices.size(), picked_total]
	UiTheme.apply_label(summary, UiTheme.TEXT_DIM, 19)
	box.add_child(summary)
	return box


func _make_section_title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	UiTheme.apply_label(label, UiTheme.TEXT, 24)
	return label


func _make_hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	UiTheme.apply_label(label, UiTheme.TEXT_DIM, 19)
	return label


# ---------------------------------------------------------------------------
# 交互
# ---------------------------------------------------------------------------

func _on_chapter_pressed(chapter: Dictionary) -> void:
	chapter_requested.emit(
		String(chapter.get("file", "")), String(chapter.get("label", "")))


func _on_clear_read() -> void:
	ReadTracker.clear()
	_rebuild()
