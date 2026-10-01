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

const PANEL_MARGIN_X := 70.0
const PANEL_MARGIN_Y := 60.0
const ENDING_CARD := Vector2(240.0, 116.0)
const ENDING_COLUMNS := 4

var _dim: ColorRect
var _panel: PanelContainer
var _title: Label
var _close_button: Button
var _body: VBoxContainer


func _ready() -> void:
	visible = false
	# 这个面板由代码创建、直接挂在 CanvasLayer 下 —— 这种 Control 的锚点
	# **拿不到视口尺寸**：set_anchors_preset(FULL_RECT) 之后 size 仍是由内容
	# 撑出来的值（约 1422×890），于是「满屏面板」只占住左上角一块，
	# 右边和下边各留一大片空 —— 这正是「记录界面没占全」的根因。
	# 必须显式按视口设一次 offset，并跟着视口变化。
	_fit_to_viewport()
	if not get_viewport().size_changed.is_connected(_fit_to_viewport):
		get_viewport().size_changed.connect(_fit_to_viewport)
	mouse_filter = Control.MOUSE_FILTER_STOP

	_dim = ColorRect.new()
	# 和鉴赏面板用同一个遮罩色。面板满屏之后遮罩只露一圈边，
	# 但那一圈的颜色不一致会一眼看出来。
	_dim.color = Color(0.031, 0.027, 0.055, 0.94)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	# 面板铺满全屏，只留出与鉴赏面板相同的边距（两处风格保持一致）。
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = PANEL_MARGIN_X
	_panel.offset_top = PANEL_MARGIN_Y
	_panel.offset_right = -PANEL_MARGIN_X
	_panel.offset_bottom = -PANEL_MARGIN_Y
	UiTheme.apply_panel(_panel, "default")
	add_child(_panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 14)
	_panel.add_child(outer)

	outer.add_child(_make_header())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 14)
	scroll.add_child(_body)


## 把自己撑满视口。
##
## 两个坑叠在一起，必须这么写：
##
## 1. CanvasLayer 不是 Control，挂在它下面的 Control **拿不到父级尺寸**；
## 2. FULL_RECT 的左右（上下）锚点是**非等值**的，此时矩形由锚点位置 + offset
##    共同决定 —— 写 `offset_right = 视口宽` 会得到「视口宽 + 视口宽」，
##    面板直接被撑成两倍大（1920 的视口撑出 3840 的矩形）。
##
## 所以锚点全部固定在左上角（BEGIN），矩形**完全由 offset 决定**：
## 这样不管父级是 CanvasLayer 还是普通 Control，尺寸都正好等于视口，
## 也不会触发引擎那条「非等值锚点下 size 会被 offset 反推」的警告。
func _fit_to_viewport() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var rect := viewport.get_visible_rect().size
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	offset_left = 0.0
	offset_top = 0.0
	offset_right = rect.x
	offset_bottom = rect.y


func present() -> void:
	# 每次打开都重新按视口校一次尺寸。
	#
	# 只在 _ready() 里校是不够的：_ready 可能比视口就绪更早 ——
	# 实测那时 get_visible_rect() 读到的是 3840×2160，一帧之后才是真正的
	# 1920×1080（同一现象在 debug_console 里也打印过）。玩家打开面板时
	# 一定已经过了好几帧，在这里校一次才拿得到正确值。
	_fit_to_viewport()
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


## 已读进度（**当前剧本口径**），返回 (已读句数, 总句数)。
##
## 分子不能用 ReadTracker.read_count()：那是全局去重计数（跨存档、跨剧本版本，
## 连测试随手标的探针句子都算在内），而分母只是当前剧本的台词数。两者口径不同，
## 直接相除会显示出「已读 150 / 62 句」这种分子大于分母的结果。
## 公开出来也是为了让测试能直接断言这条不变式。
static func read_progress() -> Vector2i:
	return Vector2i(
		ReadTracker.read_count_of(ScriptStats.line_texts()),
		ScriptStats.total_lines())


## 顶部概览：已读率 + 结局进度
func _make_progress_section() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)

	var progress := read_progress()
	var total := progress.y
	var read := progress.x
	var rate := 0.0 if total <= 0 else float(read) / float(total)

	var line := Label.new()
	line.set_meta(I18n.META_SKIP, true)
	line.text = I18n.t("已读 {read} / {total} 句（{rate}%）", {
		"read": read, "total": total, "rate": "%d" % roundi(rate * 100.0),
	})
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
			"" if visited else I18n.t("（未读）"),
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
		# 卡片用小内边距预设，别用 default（那是给大面板留的边距）
		UiTheme.apply_panel(card, "card")

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
		head.text = "%s · %s" % [file, label if not label.is_empty() else I18n.t("（无标签）")]
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
	summary.set_meta(I18n.META_SKIP, true)
	summary.text = I18n.t("共 {total} 个选项点，走过 {picked} 个",
		{"total": choices.size(), "picked": picked_total})
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
