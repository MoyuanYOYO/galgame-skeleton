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


func _ready() -> void:
	UiTheme.apply_label(_title_label, UiTheme.TEXT, 78)
	UiTheme.apply_label(_subtitle_label, UiTheme.TEXT_DIM, 24)
	for button in [_start_button, _continue_button, _load_button,
			_gallery_button, _records_button, _settings_button, _quit_button]:
		var btn := button as Button
		UiTheme.apply_button(btn, "title")
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
