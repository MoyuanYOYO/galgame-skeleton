extends Node

## 设置管理器（Autoload）
##
## 负责玩家偏好设置的读写与持久化，落盘到 user://config.json。
## 任何一处 set_value() 都会触发 config_changed 信号，
## AudioManager / UI 订阅它即可实时响应。

signal config_changed(key: String, value: Variant)

const CONFIG_PATH := "user://config.json"

const DEFAULTS := {
	"text_speed": 45.0,      # 打字机速度：每秒显示字符数
	"auto_delay": 1.6,       # 自动播放时每句停留秒数
	"master_volume": 1.0,
	"bgm_volume": 0.8,
	"se_volume": 0.9,
	"voice_volume": 1.0,
	"fullscreen": false,
	"skip_unread": false,
}

var data: Dictionary = {}


func _ready() -> void:
	load_config()
	apply_fullscreen()
	# 外观配置要在任何界面创建之前就位 —— Autoload 的 _ready 早于主场景实例化，
	# 所以这里是唯一能保证 UiTheme 的调色板/字体已经生效的时机。
	UiTheme.reload()
	UiTheme.install_global_font(self)


func get_value(key: String, default_value: Variant = null) -> Variant:
	if data.has(key):
		return data[key]
	if DEFAULTS.has(key):
		return DEFAULTS[key]
	return default_value


func set_value(key: String, value: Variant, persist: bool = true) -> void:
	data[key] = value
	if key == "fullscreen":
		apply_fullscreen()
	config_changed.emit(key, value)
	if persist:
		save_config()


func load_config() -> void:
	data = DEFAULTS.duplicate(true)
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var file := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if file == null:
		push_warning("[Config] 无法读取 %s，使用默认设置" % CONFIG_PATH)
		return
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[Config] 配置文件格式错误，使用默认设置")
		return
	for key in (parsed as Dictionary).keys():
		data[String(key)] = (parsed as Dictionary)[key]


func save_config() -> void:
	var file := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[Config] 无法写入 %s" % CONFIG_PATH)
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()


func reset_to_default() -> void:
	data = DEFAULTS.duplicate(true)
	save_config()
	for key in data.keys():
		config_changed.emit(String(key), data[key])


func apply_fullscreen() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var want_fullscreen := bool(get_value("fullscreen", false))
	var mode := DisplayServer.window_get_mode()
	var is_fullscreen := mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if want_fullscreen == is_fullscreen:
		return
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if want_fullscreen
		else DisplayServer.WINDOW_MODE_WINDOWED)
