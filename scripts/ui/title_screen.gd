class_name TitleScreen
extends Control

## 标题画面
##
## 提供两条读档路径：
##   「继续游戏」—— 一键读最近一次存档（快捷）
##   「读取存档」—— 打开存档面板手动挑槽位
## 两者在没有存档时都会置灰，避免玩家点进去看到一片「空」。

signal start_requested()
signal continue_requested()
signal load_requested()
signal gallery_requested()
signal settings_requested()
signal records_requested()

@onready var _title_label: Label = %TitleLabel
@onready var _subtitle_label: Label = %SubtitleLabel
@onready var _start_button: Button = %StartButton
@onready var _continue_button: Button = %ContinueButton
@onready var _load_button: Button = %LoadButton
@onready var _gallery_button: Button = %GalleryButton
@onready var _records_button: Button = %RecordsButton
@onready var _settings_button: Button = %SettingsButton
@onready var _quit_button: Button = %QuitButton

## 周目提示（「第 2 周目 · 已通关 1 次」）。代码建、插在副标题下面 ——
## 不动 main.tscn：这一行是可选的装饰，加在场景里反而让 tscn 更难读。
var _cycle_label: Label


## 标题画面底板：照片 + 暖色纱罩（对齐选型页 mockup 的「樱花照片上浮着菜单」）。
## bg 没配 / 文件缺失时回退成不透明的 BG_DEEP 纯色底 ——
## 舞台是空的，半透明纱罩会露出窗口底色，所以回退分支必须压满不透明。
func _build_backdrop() -> void:
	var cfg := UiTheme.section("title")
	var dim := $Dim as ColorRect
	var path := String(cfg.get("bg", "")).strip_edges()
	if path.is_empty() or not ResourceLoader.exists(path):
		dim.color = Color(UiTheme.BG_DEEP.r, UiTheme.BG_DEEP.g,
			UiTheme.BG_DEEP.b, 1.0)
		return
	var bg := TextureRect.new()
	bg.name = "Backdrop"
	bg.texture = load(path) as Texture2D
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	move_child(bg, 0)
	var scrim := Color.from_string(String(cfg.get("scrim", "#2a1f26")),
		Color(UiTheme.BG_DEEP.r, UiTheme.BG_DEEP.g, UiTheme.BG_DEEP.b, 1.0))
	scrim.a = float(cfg.get("scrim_alpha", 1.0))
	dim.color = scrim


func _ready() -> void:
	_build_backdrop()
	_build_cycle_label()
	# 标题文字直接坐在深色底板上，不跟着 palette.text 走 ——
	# 浅色主题里 text 是深墨色，放在深色标题底板上会看不清。
	# 颜色单独给键（title_text / title_text_dim），换主题不用改代码。
	_title_label.add_theme_color_override("font_shadow_color",
		Color(0, 0, 0, 0.45))
	_title_label.add_theme_constant_override("shadow_offset_y", 4)
	_title_label.add_theme_constant_override("shadow_outline_size", 2)
	UiTheme.apply_label(_title_label, UiTheme.color("title_text", UiTheme.TEXT), 78)
	UiTheme.apply_label(_subtitle_label,
		UiTheme.color("title_text_dim", UiTheme.TEXT_DIM), 24)
	# 「开始游戏」是主按钮（玫红），其余是白芯片 —— 与选型页 mockup 一致
	for button in [_start_button, _continue_button, _load_button,
			_gallery_button, _records_button, _settings_button, _quit_button]:
		var btn := button as Button
		var preset := "title_sub" if button != _start_button else "title"
		UiTheme.apply_button(btn, preset)
		# VBox 子节点默认横向 FILL：不收窄的话按钮会被拉成全屏宽的横条，
		# 预设里的 width 只是「最小宽度」。收到预设宽并水平居中（mockup 的窄菜单）。
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_start_button.pressed.connect(func() -> void: start_requested.emit())
	_continue_button.pressed.connect(func() -> void: continue_requested.emit())
	_load_button.pressed.connect(func() -> void: load_requested.emit())
	_gallery_button.pressed.connect(func() -> void: gallery_requested.emit())
	_records_button.pressed.connect(func() -> void: records_requested.emit())
	_settings_button.pressed.connect(func() -> void: settings_requested.emit())
	_quit_button.pressed.connect(func() -> void: get_tree().quit())
	_start_button.grab_focus()


## 有存档时才允许「继续游戏」和「读取存档」
func set_save_available(available: bool) -> void:
	_continue_button.disabled = not available
	_load_button.disabled = not available


# ---------------------------------------------------------------------------
# 周目提示
# ---------------------------------------------------------------------------

## 在副标题下面挂一行周目提示。找不到 VBox（场景被改过）就安静跳过 ——
## 这只是锦上添花的信息，不该因为它让标题界面报错。
func _build_cycle_label() -> void:
	var box := get_node_or_null("Center/VBox") as VBoxContainer
	if box == null:
		return
	_cycle_label = Label.new()
	_cycle_label.name = "CycleLabel"
	_cycle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cycle_label.visible = false
	UiTheme.apply_label(_cycle_label,
		UiTheme.color("title_text_dim", UiTheme.TEXT_DIM), 22)
	box.add_child(_cycle_label)
	# 插到副标题后面。用副标题的实际下标算，而不是写死数字 ——
	# 以后往 VBox 里加控件时不会把这一行挤到奇怪的位置。
	if _subtitle_label != null and _subtitle_label.get_parent() == box:
		box.move_child(_cycle_label, _subtitle_label.get_index() + 1)


## main.gd 在回标题 / 关 CG 重播时调用。
##
## 一周目且一次都没通关 → 整行隐藏：首次游玩的玩家不该先看到「周目」这个词，
## 那会提前剧透「这游戏要玩好几遍」。
func set_cycle_info(cycle: int, clears: int) -> void:
	if _cycle_label == null:
		return
	if cycle <= 1 and clears <= 0:
		_cycle_label.visible = false
		return
	_cycle_label.visible = true
	I18n.set_text(_cycle_label, "第 {cycle} 周目 · 已通关 {clears} 次",
		{"cycle": cycle, "clears": clears})
