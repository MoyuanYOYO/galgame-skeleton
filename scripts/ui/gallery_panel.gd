class_name GalleryPanel
extends Control

## 鉴赏主面板（CG / 音乐两个页签）
##
## · CG 网格：未解锁显示锁图标 + ???，已解锁显示缩略图与标题
## · 音乐页签：内嵌 MusicPanel
## · 所有视觉参数（列数、卡片尺寸、间距、配色、文案）都来自 gallery_theme.json
##
## 卡片是运行时按注册表生成的 —— 加一张 CG 只要往 cg.json 里加一条，
## 界面自动多出一格。

signal closed()
signal cg_activated(cg_id: String)
signal music_track_selected(id: String)

const TAB_CG := "cg"
const TAB_MUSIC := "music"

@onready var _title: Label = %GalleryTitle
@onready var _progress: Label = %GalleryProgress
@onready var _tab_cg: Button = %TabCg
@onready var _tab_music: Button = %TabMusic
@onready var _close: Button = %GalleryClose
@onready var _cg_scroll: ScrollContainer = %CgScroll
@onready var _cg_grid: GridContainer = %CgGrid
@onready var _music_root: MusicPanel = %MusicRoot
@onready var _panel: PanelContainer = $Panel

var _current_tab: String = TAB_CG
var _tab_active: StyleBoxFlat
var _tab_idle: StyleBoxFlat


func _ready() -> void:
	visible = false

	var font_size := GalleryTheme.count("button_font_size", 22)
	_title.add_theme_font_size_override("font_size", GalleryTheme.count("title_font_size", 34))
	_title.add_theme_color_override("font_color", GalleryTheme.color("text"))
	_progress.add_theme_font_size_override("font_size", 20)
	_progress.add_theme_color_override("font_color", GalleryTheme.color("text_dim"))

	_panel.add_theme_stylebox_override("panel", UiTheme.stylebox(
		GalleryTheme.color("panel"), 20, GalleryTheme.color("panel_border"), 1, 0, 0))

	_tab_active = UiTheme.stylebox(
		Color(GalleryTheme.color("accent").r, GalleryTheme.color("accent").g,
			GalleryTheme.color("accent").b, 0.40), 10,
		GalleryTheme.color("accent_bright"), 2, 26, 10)
	_tab_idle = UiTheme.stylebox(Color(0, 0, 0, 0.16), 10,
		GalleryTheme.color("card_border"), 1, 26, 10)

	for button in [_tab_cg, _tab_music]:
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
	_title.text = GalleryTheme.label("title", "鉴 赏")
	_close.text = GalleryTheme.label("close_button", "关闭")

	_cg_grid.columns = maxi(1, GalleryTheme.count("columns", 3))
	var spacing := GalleryTheme.count("grid_spacing", 22)
	_cg_grid.add_theme_constant_override("h_separation", spacing)
	_cg_grid.add_theme_constant_override("v_separation", spacing)

	_tab_cg.pressed.connect(func() -> void: show_tab(TAB_CG))
	_tab_music.pressed.connect(func() -> void: show_tab(TAB_MUSIC))
	_close.pressed.connect(hide_panel)
	_music_root.track_selected.connect(func(id: String) -> void: music_track_selected.emit(id))


# ---------------------------------------------------------------------------
# 对外
# ---------------------------------------------------------------------------

func present(tab: String = "") -> void:
	if tab == TAB_CG or tab == TAB_MUSIC:
		_current_tab = tab
	refresh()
	visible = true


func hide_panel() -> void:
	visible = false
	_music_root.stop_preview()
	closed.emit()


func refresh() -> void:
	_rebuild_cg_grid()
	_update_progress()
	_music_root.refresh()
	show_tab(_current_tab)


func get_current_tab() -> String:
	return _current_tab


func show_tab(tab: String) -> void:
	_current_tab = tab
	var show_cg := tab == TAB_CG
	_cg_scroll.visible = show_cg
	_music_root.visible = not show_cg
	_tab_cg.add_theme_stylebox_override("normal", _tab_active if show_cg else _tab_idle)
	_tab_music.add_theme_stylebox_override("normal", _tab_idle if show_cg else _tab_active)
	_tab_cg.add_theme_color_override("font_color",
		GalleryTheme.color("text") if show_cg else GalleryTheme.color("text_dim"))
	_tab_music.add_theme_color_override("font_color",
		GalleryTheme.color("text_dim") if show_cg else GalleryTheme.color("text"))
	_update_progress()


# ---------------------------------------------------------------------------
# CG 网格
# ---------------------------------------------------------------------------

func _rebuild_cg_grid() -> void:
	for child in _cg_grid.get_children():
		_cg_grid.remove_child(child)
		child.queue_free()

	for item in CollectionRegistry.get_items(TAB_CG):
		var id := String((item as Dictionary).get("id", ""))
		_cg_grid.add_child(_build_card(item, CollectionManager.is_unlocked(TAB_CG, id)))


func _build_card(item: Dictionary, unlocked: bool) -> Control:
	var cg_id := String(item.get("id", ""))
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
		caption.text = String(item.get("title", cg_id))
		caption.add_theme_color_override("font_color", GalleryTheme.color("text"))
	else:
		caption.text = GalleryTheme.label("locked_hint", "尚未解锁")
		caption.add_theme_color_override("font_color", GalleryTheme.color("text_locked"))
	title_margin.add_child(caption)

	# 交互
	card.gui_input.connect(_on_card_input.bind(cg_id, unlocked))
	if unlocked:
		card.mouse_entered.connect(func() -> void:
			card.add_theme_stylebox_override("panel", style_hover))
		card.mouse_exited.connect(func() -> void:
			card.add_theme_stylebox_override("panel", style_normal))

	return card


func _on_card_input(event: InputEvent, cg_id: String, unlocked: bool) -> void:
	if not unlocked:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			cg_activated.emit(cg_id)


func _update_progress() -> void:
	var key := "progress_label" if _current_tab == TAB_CG else "music_progress_label"
	var prefix := GalleryTheme.label(key, "收集进度")
	var progress := CollectionManager.get_progress(_current_tab)
	_progress.text = "%s   %d / %d" % [prefix, progress.x, progress.y]


static func _fill(node: Control) -> void:
	node.set_anchors_preset(Control.PRESET_FULL_RECT)
	node.offset_left = 0.0
	node.offset_top = 0.0
	node.offset_right = 0.0
	node.offset_bottom = 0.0
