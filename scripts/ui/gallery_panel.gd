class_name GalleryPanel
extends Control

## 鉴赏主面板（CG / 音乐 / 视频 三个页签）
##
## · CG 网格：未解锁显示锁图标 + ???，已解锁显示缩略图与标题
## · 音乐页签：内嵌 MusicPanel
## · 视频页签：与 CG 同样的网格，点了交给 VideoViewer 播放
## · 所有视觉参数（列数、卡片尺寸、间距、配色、文案）都来自 gallery_theme.json
##
## 卡片是运行时按注册表生成的 —— 加一张 CG / 一段视频只要往对应的 json 里加一条，
## 界面自动多出一格。
##
## ⚠️ **视频页签的控件是代码建的**（Button + ScrollContainer + GridContainer），
## 没写进 main.tscn —— 加一个页签不值得动场景文件，而且页签与网格的结构完全对称，
## 代码里复制一份比在 tscn 里手抄 20 行节点更不容易出错。

signal closed()
signal cg_activated(cg_id: String)
signal video_activated(video_id: String)
signal music_track_selected(id: String)

const TAB_CG := "cg"
const TAB_MUSIC := "music"
const TAB_VIDEO := "video"

@onready var _title: Label = %GalleryTitle
@onready var _progress: Label = %GalleryProgress
@onready var _tab_cg: Button = %TabCg
@onready var _tab_music: Button = %TabMusic
@onready var _close: Button = %GalleryClose
@onready var _cg_scroll: ScrollContainer = %CgScroll
@onready var _cg_grid: GridContainer = %CgGrid
@onready var _music_root: MusicPanel = %MusicRoot
@onready var _panel: PanelContainer = $Panel

var _tab_video: Button
var _video_scroll: ScrollContainer
var _video_grid: GridContainer

var _current_tab: String = TAB_CG
var _tab_active: StyleBoxFlat
var _tab_idle: StyleBoxFlat


func _ready() -> void:
	visible = false

	# CG / 视频网格里装的是标题 / 提示这类「内容」，不是界面文案 ——
	# 它们的多语言由剧本和注册表负责，不该被界面翻译表按原文去查
	_cg_grid.set_meta(I18n.META_SKIP, true)
	# 进度文字每帧都在变（含数字），只能走代码里的显式翻译
	_progress.set_meta(I18n.META_SKIP, true)

	var font_size := GalleryTheme.count("button_font_size", 22)
	_title.add_theme_font_size_override("font_size", GalleryTheme.count("title_font_size", 34))
	_title.add_theme_color_override("font_color", GalleryTheme.color("text"))
	_progress.add_theme_font_size_override("font_size", 20)
	_progress.add_theme_color_override("font_color", GalleryTheme.color("text_dim"))

	# 走 apply_panel 这一套，别再手写 stylebox —— 之前这里把内边距硬编码成 (0, 0)，
	# 结果鉴赏面板的文字全贴到边上，而且面板贴图也套不上来。
	# 用 apply_panel 而不是 panel_stylebox：只有它带整图尺寸自检。
	UiTheme.apply_panel(_panel, "gallery", GalleryTheme.color("panel"))

	_tab_active = UiTheme.stylebox(
		Color(GalleryTheme.color("accent").r, GalleryTheme.color("accent").g,
			GalleryTheme.color("accent").b, 0.40), 10,
		GalleryTheme.color("accent_bright"), 2, 26, 10)
	_tab_idle = UiTheme.stylebox(Color(0, 0, 0, 0.16), 10,
		GalleryTheme.color("card_border"), 1, 26, 10)

	_build_video_tab()

	for button in [_tab_cg, _tab_music, _tab_video]:
		var btn := button as Button
		btn.add_theme_font_size_override("font_size", font_size)
		btn.add_theme_stylebox_override("hover", _tab_active)
		btn.add_theme_stylebox_override("pressed", _tab_active)
		btn.add_theme_stylebox_override("focus", _tab_idle)
		btn.add_theme_color_override("font_color", GalleryTheme.color("text_dim"))
		btn.add_theme_color_override("font_hover_color", GalleryTheme.color("text"))

	UiTheme.apply_button(_close, "default")
	_tab_cg.text = GalleryTheme.label("tab_cg", "CG 鉴赏")
	_tab_music.text = GalleryTheme.label("tab_music", "音乐鉴赏")
	_tab_video.text = GalleryTheme.label("tab_video", "视频鉴赏")
	_title.text = GalleryTheme.label("title", "鉴 赏")
	_close.text = GalleryTheme.label("close_button", "关闭")

	var columns := maxi(1, GalleryTheme.count("columns", 3))
	var spacing := GalleryTheme.count("grid_spacing", 22)
	for grid in [_cg_grid, _video_grid]:
		(grid as GridContainer).columns = columns
		(grid as GridContainer).add_theme_constant_override("h_separation", spacing)
		(grid as GridContainer).add_theme_constant_override("v_separation", spacing)

	_tab_cg.pressed.connect(func() -> void: show_tab(TAB_CG))
	_tab_music.pressed.connect(func() -> void: show_tab(TAB_MUSIC))
	_tab_video.pressed.connect(func() -> void: show_tab(TAB_VIDEO))
	_close.pressed.connect(hide_panel)
	_music_root.track_selected.connect(func(id: String) -> void: music_track_selected.emit(id))


## 视频页签：按钮插在「关闭」之前，网格插在 CG 网格之后（音乐面板之前）。
## 位置靠 `move_child` 按现有节点的下标算，不写死数字 —— 以后往 VBox 里
## 加东西时不会把这块挤到奇怪的地方。
func _build_video_tab() -> void:
	var vbox := _panel.get_node("VBox") as VBoxContainer
	var header := vbox.get_node("Header") as HBoxContainer

	_tab_video = Button.new()
	_tab_video.name = "TabVideo"
	header.add_child(_tab_video)
	header.move_child(_tab_video, _close.get_index())

	_video_scroll = ScrollContainer.new()
	_video_scroll.name = "VideoScroll"
	_video_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_video_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_video_scroll.visible = false

	_video_grid = GridContainer.new()
	_video_grid.name = "VideoGrid"
	_video_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_video_grid.set_meta(I18n.META_SKIP, true)
	_video_scroll.add_child(_video_grid)

	vbox.add_child(_video_scroll)
	vbox.move_child(_video_scroll, _cg_scroll.get_index() + 1)


# ---------------------------------------------------------------------------
# 对外
# ---------------------------------------------------------------------------

func present(tab: String = "") -> void:
	if tab == TAB_CG or tab == TAB_MUSIC or tab == TAB_VIDEO:
		_current_tab = tab
	refresh()
	visible = true


func hide_panel() -> void:
	visible = false
	closed.emit()


func refresh() -> void:
	_rebuild_grid(_cg_grid, TAB_CG)
	_rebuild_grid(_video_grid, TAB_VIDEO)
	_update_progress()
	_music_root.refresh()
	show_tab(_current_tab)


func get_current_tab() -> String:
	return _current_tab


func show_tab(tab: String) -> void:
	_current_tab = tab
	_cg_scroll.visible = tab == TAB_CG
	_music_root.visible = tab == TAB_MUSIC
	_video_scroll.visible = tab == TAB_VIDEO
	var tabs := {TAB_CG: _tab_cg, TAB_MUSIC: _tab_music, TAB_VIDEO: _tab_video}
	for key in tabs.keys():
		var btn := tabs[key] as Button
		var active := String(key) == tab
		btn.add_theme_stylebox_override("normal", _tab_active if active else _tab_idle)
		btn.add_theme_color_override("font_color",
			GalleryTheme.color("text") if active else GalleryTheme.color("text_dim"))
	_update_progress()


# ---------------------------------------------------------------------------
# 网格（CG / 视频共用同一套卡片）
# ---------------------------------------------------------------------------

func _rebuild_grid(grid: GridContainer, tab: String) -> void:
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()

	for item in CollectionRegistry.get_items(tab):
		var id := String((item as Dictionary).get("id", ""))
		grid.add_child(_build_card(item, CollectionManager.is_unlocked(tab, id), tab))


func _build_card(item: Dictionary, unlocked: bool, tab: String) -> Control:
	var item_id := String(item.get("id", ""))
	var card_width := GalleryTheme.number("card_width", 350.0)
	var card_height := card_width * GalleryTheme.number("card_ratio", 0.5625)
	var title_height := GalleryTheme.number("card_title_font_size", 20) + 30.0
	var radius := GalleryTheme.count("card_radius", 14)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(card_width, card_height + title_height)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	if unlocked:
		card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var style_normal := UiTheme.stylebox(
		GalleryTheme.color("card") if unlocked else GalleryTheme.color("card_locked"),
		radius,
		GalleryTheme.color("card_border") if unlocked
			else GalleryTheme.color("card_border").darkened(0.45),
		1, 0, 0)
	var style_hover := UiTheme.stylebox(
		GalleryTheme.color("card_hover"), radius,
		GalleryTheme.color("accent_bright"), 2, 0, 0)
	card.add_theme_stylebox_override("panel", style_normal)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(column)

	# 缩略图区
	var thumb_host := Control.new()
	thumb_host.custom_minimum_size = Vector2(card_width, card_height)
	thumb_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(thumb_host)

	if unlocked:
		var thumb := TextureRect.new()
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		thumb.texture = CollectionRegistry.resolve_texture(item)
		_fill(thumb)
		thumb_host.add_child(thumb)
	else:
		var backdrop := ColorRect.new()
		backdrop.color = GalleryTheme.color("card_locked")
		backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fill(backdrop)
		thumb_host.add_child(backdrop)

		var lock := LockIcon.new()
		lock.body_color = GalleryTheme.color("text_locked")
		lock.shackle_color = GalleryTheme.color("text_locked").lightened(0.18)
		lock.keyhole_color = GalleryTheme.color("card_locked").darkened(0.4)
		var icon_size := float(GalleryTheme.section("locked_icon").get("size", 58.0))
		lock.set_anchors_preset(Control.PRESET_CENTER)
		lock.offset_left = -icon_size * 0.5
		lock.offset_top = -icon_size * 0.5
		lock.offset_right = icon_size * 0.5
		lock.offset_bottom = icon_size * 0.5
		thumb_host.add_child(lock)

		var locked_label := Label.new()
		locked_label.text = GalleryTheme.label("locked_label", "???")
		locked_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		locked_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		locked_label.add_theme_font_size_override("font_size", 26)
		locked_label.add_theme_color_override("font_color", GalleryTheme.color("text_locked"))
		locked_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		locked_label.offset_top = -icon_size - 46.0
		locked_label.offset_bottom = -14.0
		thumb_host.add_child(locked_label)

	# 标题区
	var title_margin := MarginContainer.new()
	title_margin.add_theme_constant_override("margin_left", 14)
	title_margin.add_theme_constant_override("margin_right", 14)
	title_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(title_margin)

	var caption := Label.new()
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.add_theme_font_size_override("font_size",
		GalleryTheme.count("card_title_font_size", 20))
	if unlocked:
		caption.text = String(item.get("title", item_id))
		caption.add_theme_color_override("font_color", GalleryTheme.color("text"))
	else:
		caption.text = GalleryTheme.label("locked_hint", "尚未解锁")
		caption.add_theme_color_override("font_color", GalleryTheme.color("text_locked"))
	title_margin.add_child(caption)

	# 交互
	card.gui_input.connect(_on_card_input.bind(item_id, unlocked, tab))
	if unlocked:
		card.mouse_entered.connect(func() -> void:
			card.add_theme_stylebox_override("panel", style_hover))
		card.mouse_exited.connect(func() -> void:
			card.add_theme_stylebox_override("panel", style_normal))

	return card


func _on_card_input(event: InputEvent, item_id: String, unlocked: bool, tab: String) -> void:
	if not unlocked:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if tab == TAB_VIDEO:
				video_activated.emit(item_id)
			else:
				cg_activated.emit(item_id)


func _update_progress() -> void:
	var key := "progress_label"
	if _current_tab == TAB_MUSIC:
		key = "music_progress_label"
	elif _current_tab == TAB_VIDEO:
		key = "video_progress_label"
	var prefix := GalleryTheme.label(key, "收集进度")
	var progress := CollectionManager.get_progress(_current_tab)
	_progress.text = "%s   %d / %d" % [I18n.t(prefix), progress.x, progress.y]


static func _fill(node: Control) -> void:
	node.set_anchors_preset(Control.PRESET_FULL_RECT)
	node.offset_left = 0.0
	node.offset_top = 0.0
	node.offset_right = 0.0
	node.offset_bottom = 0.0
