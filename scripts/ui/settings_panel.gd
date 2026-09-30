class_name SettingsPanel
extends Control

## 设置面板
##
## 所有控件由 SPEC 表驱动生成 —— 想加一项设置，只要在表里加一行，
## 界面、持久化、实时生效三件事同时完成。

const SLIDERS: Array = [
	{"key": "text_speed", "label": "文字速度", "min": 10.0, "max": 120.0, "step": 1.0, "display": "chars"},
	{"key": "auto_delay", "label": "自动播放间隔", "min": 0.3, "max": 5.0, "step": 0.1, "display": "seconds"},
	{"key": "master_volume", "label": "总音量", "min": 0.0, "max": 1.0, "step": 0.05, "display": "percent"},
	{"key": "bgm_volume", "label": "背景音乐", "min": 0.0, "max": 1.0, "step": 0.05, "display": "percent"},
	{"key": "se_volume", "label": "音效", "min": 0.0, "max": 1.0, "step": 0.05, "display": "percent"},
	{"key": "voice_volume", "label": "语音", "min": 0.0, "max": 1.0, "step": 0.05, "display": "percent"},
]

const TOGGLES: Array = [
	{"key": "fullscreen", "label": "全屏显示"},
	{"key": "skip_unread", "label": "允许跳过未读文本"},
]

@onready var _rows: VBoxContainer = %SettingsRows
@onready var _close_button: Button = %SettingsClose
@onready var _reset_button: Button = %SettingsReset
@onready var _panel: PanelContainer = $Panel

var _slider_nodes: Dictionary = {}
var _value_nodes: Dictionary = {}
var _toggle_nodes: Dictionary = {}


func _ready() -> void:
	visible = false
	UiTheme.apply_panel(_panel, "default")
	UiTheme.apply_button(_close_button, "default")
	UiTheme.apply_button(_reset_button, "small")
	_close_button.pressed.connect(hide_panel)
	_reset_button.pressed.connect(_on_reset)
	_build()


func present() -> void:
	_refresh()
	visible = true


func hide_panel() -> void:
	visible = false


# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------

func _build() -> void:
	for spec in SLIDERS:
		_rows.add_child(_make_slider_row(spec))
	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(0.0, 12.0)
	_rows.add_child(sep)
	for spec in TOGGLES:
		_rows.add_child(_make_toggle_row(spec))


func _make_slider_row(spec: Dictionary) -> HBoxContainer:
	var key := String(spec["key"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)

	var name_label := Label.new()
	name_label.text = String(spec["label"])
	name_label.custom_minimum_size = Vector2(220.0, 0.0)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UiTheme.apply_label(name_label, UiTheme.TEXT_DIM, 22)
	row.add_child(name_label)

	var slider := HSlider.new()
	slider.min_value = float(spec["min"])
	slider.max_value = float(spec["max"])
	slider.step = float(spec["step"])
	slider.value = float(ConfigManager.get_value(key, float(spec["min"])))
	slider.custom_minimum_size = Vector2(420.0, 34.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(150.0, 0.0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value_label.text = _format_value(String(spec["display"]), slider.value)
	UiTheme.apply_label(value_label, UiTheme.TEXT, 22)
	row.add_child(value_label)

	slider.value_changed.connect(_on_slider_changed.bind(key, String(spec["display"]), value_label))
	_slider_nodes[key] = slider
	_value_nodes[key] = value_label
	return row


func _make_toggle_row(spec: Dictionary) -> HBoxContainer:
	var key := String(spec["key"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)

	var check := CheckButton.new()
	check.text = String(spec["label"])
	check.button_pressed = bool(ConfigManager.get_value(key, false))
	check.add_theme_color_override("font_color", UiTheme.TEXT)
	check.add_theme_color_override("font_hover_color", Color.WHITE)
	check.add_theme_font_size_override("font_size", 22)
	check.toggled.connect(_on_toggled.bind(key))
	row.add_child(check)
	_toggle_nodes[key] = check
	return row


# ---------------------------------------------------------------------------
# 交互
# ---------------------------------------------------------------------------

func _on_slider_changed(value: float, key: String, display: String, label: Label) -> void:
	ConfigManager.set_value(key, value)
	label.text = _format_value(display, value)


func _on_toggled(pressed: bool, key: String) -> void:
	ConfigManager.set_value(key, pressed)


func _on_reset() -> void:
	ConfigManager.reset_to_default()
	_refresh()


func _refresh() -> void:
	for key in _slider_nodes.keys():
		var slider := _slider_nodes[key] as HSlider
		if slider != null:
			slider.set_value_no_signal(float(ConfigManager.get_value(String(key), slider.value)))
	for spec in SLIDERS:
		var key := String(spec["key"])
		var label := _value_nodes.get(key) as Label
		var slider := _slider_nodes.get(key) as HSlider
		if label != null and slider != null:
			label.text = _format_value(String(spec["display"]), slider.value)
	for key in _toggle_nodes.keys():
		var check := _toggle_nodes[key] as CheckButton
		if check != null:
			check.set_pressed_no_signal(bool(ConfigManager.get_value(String(key), false)))


static func _format_value(display: String, value: float) -> String:
	match display:
		"percent":
			return "%d%%" % int(round(value * 100.0))
		"chars":
			return "%d 字/秒" % int(round(value))
		"seconds":
			return "%.1f 秒" % value
	return str(value)
