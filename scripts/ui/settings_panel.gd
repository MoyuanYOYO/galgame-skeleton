class_name SettingsPanel
extends Control

## 设置面板
##
## 整块界面由 **一张有序的 `LAYOUT` 表**驱动：`"#组名"` 是分组标题，
## 其余是设置行。想加一项 / 换分组 / 调顺序，只改这张表，
## 界面、持久化、实时生效三件事同时完成，不用碰渲染代码。
##
## 分组标题是后来加的：设置项一多（现在 16 项）整页铺满就找不到东西，
## 加一行小标题的成本极低，收益是「一眼知道这块在管什么」。

## 设置面板的完整布局（按顺序渲染）。
##
## 行规格的公共字段：
##   `key`    —— 配置键（也是 `_slider_nodes` / `_toggle_nodes` / `_choice_nodes` 的键）
##   `type`   —— slider / toggle / choice / language / voice（缺省 = slider，兼容老写法）
##   `label`  —— 界面文案（会走 I18n）
## slider 追加：`min` `max` `step` `display`
## choice 追加：`source`（选项从哪来，见 `_fill_choice`）
const LAYOUT: Array = [
	"#文本",
	{"key": "text_speed", "label": "文字速度", "min": 10.0, "max": 120.0, "step": 1.0, "display": "chars"},
	{"key": "auto_delay", "label": "自动播放间隔", "min": 0.3, "max": 5.0, "step": 0.1, "display": "seconds"},
	{"key": "click_skip_to_stop", "type": "toggle", "label": "点击先跳到下一个停顿"},
	{"key": "auto_wait_voice", "type": "toggle", "label": "自动播放等语音念完"},

	"#音频",
	{"key": "master_volume", "label": "总音量", "min": 0.0, "max": 1.0, "step": 0.05, "display": "percent"},
	{"key": "bgm_volume", "label": "背景音乐", "min": 0.0, "max": 1.0, "step": 0.05, "display": "percent"},
	{"key": "se_volume", "label": "音效", "min": 0.0, "max": 1.0, "step": 0.05, "display": "percent"},
	{"key": "voice_volume", "label": "语音", "min": 0.0, "max": 1.0, "step": 0.05, "display": "percent"},
	{"key": "text_sfx", "type": "toggle", "label": "打字音效"},
	{"key": "duck_bgm", "type": "toggle", "label": "对白时压低音乐"},

	"#显示与操作",
	{"key": "fullscreen", "type": "toggle", "label": "全屏显示"},
	{"key": "skip_unread", "type": "toggle", "label": "允许跳过未读文本"},
	{"key": "dim_read_text", "type": "toggle", "label": "已读文本变暗"},
	{"key": "rollback_wheel", "type": "toggle", "label": "滚轮用于回滚剧情"},

	"#语言与标题",
	{"key": "title_bgm", "type": "choice", "label": "标题音乐", "source": "unlocked_music"},
	{"key": "__language", "type": "language", "label": "语言"},

	"#角色语音",
	{"key": "__voice_mute", "type": "voice"},
]

## 设置行的正文字号。跟其他功能窗口的正文对齐（存档 / 记录 / 回看都是 19~20），
## 原来用 22 会显得比别处大一号。
const ROW_FONT_SIZE := 20
## 分组标题的字号（比正文小一号 + 强调色，做出「标题」的层次）
const GROUP_FONT_SIZE := 17

## 角色名清单。优先读 data/characters.json（导出后仍可靠），
## 缺文件时退回扫描 assets/sprites/ 下的目录名。
const CHARACTERS_PATH := "res://data/characters.json"

@onready var _rows: VBoxContainer = %SettingsRows
@onready var _close_button: Button = %SettingsClose
@onready var _reset_button: Button = %SettingsReset
@onready var _panel: PanelContainer = $Panel

var _slider_nodes: Dictionary = {}
var _value_nodes: Dictionary = {}
## key → 该滑块怎么格式化数值（`_refresh` 要按 key 重新格式化）
var _slider_display: Dictionary = {}
var _toggle_nodes: Dictionary = {}
var _choice_nodes: Dictionary = {}
var _voice_checks: Dictionary = {}
var _language_select: OptionButton


func _ready() -> void:
	visible = false
	UiTheme.apply_panel(_panel, "settings")
	UiTheme.apply_button(_close_button, "default")
	UiTheme.apply_button(_reset_button, "small")
	_close_button.pressed.connect(hide_panel)
	_reset_button.pressed.connect(_on_reset)
	_build()


func present() -> void:
	# 标题音乐的候选是「已解锁曲目」，玩过一局就会变 —— 每次打开都重建选项，
	# 否则面板开着时新解锁的曲子看不到。
	_refresh()
	visible = true


## 切语言后重建整块内容。滑块 / 开关 / 下拉的标签、语言下拉的选项都得重来一遍。
func rebuild() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	_slider_nodes.clear()
	_value_nodes.clear()
	_slider_display.clear()
	_toggle_nodes.clear()
	_choice_nodes.clear()
	_voice_checks.clear()
	_language_select = null
	_build()
	_refresh()


func hide_panel() -> void:
	visible = false


# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------

func _build() -> void:
	for entry in LAYOUT:
		if typeof(entry) == TYPE_STRING:
			_rows.add_child(_group_header(String(entry).substr(1)))
			continue
		var spec: Dictionary = entry
		match String(spec.get("type", "slider")):
			"toggle":
				_rows.add_child(_make_toggle_row(spec))
			"choice":
				_rows.add_child(_make_choice_row(spec))
			"language":
				_rows.add_child(_make_language_row(spec))
			"voice":
				_rows.add_child(_make_voice_section())
			_:
				_rows.add_child(_make_slider_row(spec))


## 分组标题。用小一号 + 强调色 + 上边距做出层次 —— 不画分隔线
## （一页里画太多线反而更乱）。
func _group_header(title: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.custom_minimum_size = Vector2(0.0, 34.0)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 10.0)
	box.add_child(spacer)

	var label := Label.new()
	label.text = I18n.t(title)
	label.custom_minimum_size = Vector2(0.0, 24.0)
	UiTheme.apply_label(label, UiTheme.color("accent", UiTheme.TEXT), GROUP_FONT_SIZE)
	box.add_child(label)
	return box


## 语言是「几选一」而不是滑块或开关，所以单独一行。
## 选项文字用各自语言写的语言名，本身不参与翻译。
func _make_language_row(spec: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)

	var name_label := Label.new()
	name_label.text = String(spec.get("label", "语言"))
	name_label.custom_minimum_size = Vector2(220.0, 0.0)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UiTheme.apply_label(name_label, UiTheme.TEXT, ROW_FONT_SIZE)
	row.add_child(name_label)

	var select := OptionButton.new()
	select.custom_minimum_size = Vector2(260.0, 48.0)
	for code in I18n.languages():
		select.add_item(I18n.language_name(String(code)))
		select.set_item_metadata(select.item_count - 1, String(code))
	var current_code := String(ConfigManager.get_value(I18n.CONFIG_KEY, I18n.DEFAULT_LANG))
	for i in select.item_count:
		if String(select.get_item_metadata(i)) == current_code:
			select.select(i)
			break
	select.item_selected.connect(_on_language_selected.bind(select))
	UiTheme.apply_button(select, "small")
	row.add_child(select)
	_language_select = select
	return row


func _on_language_selected(_index: int, select: OptionButton) -> void:
	var code := String(select.get_item_metadata(select.selected))
	if code.is_empty():
		return
	# 切语言由 main 统一处理：它会重新翻译整棵界面树并刷新动态面板。
	# 这里只负责改配置 —— 否则设置面板自己重建时，别的面板还是旧语言。
	I18n.set_language(code)


func _make_slider_row(spec: Dictionary) -> HBoxContainer:
	var key := String(spec["key"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)

	var name_label := Label.new()
	name_label.text = String(spec["label"])
	name_label.custom_minimum_size = Vector2(220.0, 0.0)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UiTheme.apply_label(name_label, UiTheme.TEXT, ROW_FONT_SIZE)
	row.add_child(name_label)

	var slider := HSlider.new()
	slider.min_value = float(spec["min"])
	slider.max_value = float(spec["max"])
	slider.step = float(spec["step"])
	slider.value = float(ConfigManager.get_value(key, float(spec["min"])))
	slider.custom_minimum_size = Vector2(420.0, 34.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UiTheme.apply_slider(slider)
	row.add_child(slider)

	var value_label := Label.new()
	# 数值是随滑块变的动态文字，翻译在 _format_value 里做，别让它再被查表
	value_label.set_meta(I18n.META_SKIP, true)
	value_label.custom_minimum_size = Vector2(150.0, 0.0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value_label.text = _format_value(String(spec["display"]), slider.value)
	UiTheme.apply_label(value_label, UiTheme.TEXT, ROW_FONT_SIZE)
	row.add_child(value_label)

	slider.value_changed.connect(_on_slider_changed.bind(key, String(spec["display"]), value_label))
	_slider_nodes[key] = slider
	_value_nodes[key] = value_label
	_slider_display[key] = String(spec["display"])
	return row


func _make_toggle_row(spec: Dictionary) -> HBoxContainer:
	var key := String(spec["key"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)

	var check := CheckButton.new()
	check.text = String(spec["label"])
	check.button_pressed = bool(ConfigManager.get_value(key, false))
	# 走统一的开关样式：六个状态色全部覆盖。
	# 以前只写了 font_color，还把 hover 显式设成白色 —— 浅色面板上
	# 「开关打开 / 鼠标悬停」时文字就变白看不见了。
	UiTheme.apply_check_button(check, UiTheme.TEXT, ROW_FONT_SIZE)
	check.toggled.connect(_on_toggled.bind(key))
	row.add_child(check)
	_toggle_nodes[key] = check
	return row


## 下拉类设置行（「标题音乐」等）。
##
## 选项在 `_refresh()` 里填 —— 因为它的候选项会随游戏进程变化
## （新解锁一首曲子就多一个选项），不能在 `_build()` 时定死。
func _make_choice_row(spec: Dictionary) -> HBoxContainer:
	var key := String(spec["key"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)

	var name_label := Label.new()
	name_label.text = String(spec["label"])
	name_label.custom_minimum_size = Vector2(220.0, 0.0)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UiTheme.apply_label(name_label, UiTheme.TEXT, ROW_FONT_SIZE)
	row.add_child(name_label)

	var select := OptionButton.new()
	select.custom_minimum_size = Vector2(360.0, 48.0)
	# 曲名是「内容」不是界面文案，别让界面翻译表按原文去查
	select.set_meta(I18n.META_SKIP, true)
	select.item_selected.connect(_on_choice_selected.bind(key, select))
	UiTheme.apply_button(select, "small")
	row.add_child(select)
	_choice_nodes[key] = select
	return row


## 角色语音静音段：每个角色一个开关，关掉后该角色的语音不播
## （包括点名字牌重播）。列表来自 data/characters.json，缺文件时扫立绘目录。
func _make_voice_section() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)

	var chars := _character_list()
	if chars.is_empty():
		var hint := Label.new()
		hint.text = I18n.t("没有找到任何角色（data/characters.json 或 assets/sprites/）")
		UiTheme.apply_label(hint, UiTheme.TEXT_DIM, ROW_FONT_SIZE - 2)
		box.add_child(hint)
		return box

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 30)
	grid.add_theme_constant_override("v_separation", 8)
	for entry in chars:
		var char_id := String((entry as Dictionary).get("id", ""))
		var check := CheckButton.new()
		check.text = String((entry as Dictionary).get("name", char_id))
		check.button_pressed = AudioManager.is_voice_muted(char_id)
		UiTheme.apply_check_button(check, UiTheme.TEXT, ROW_FONT_SIZE)
		check.toggled.connect(_on_voice_mute_toggled.bind(char_id))
		grid.add_child(check)
		_voice_checks[char_id] = check
	box.add_child(grid)

	var note := Label.new()
	note.text = I18n.t("勾选 = 该角色的语音静音（仍显示台词）")
	UiTheme.apply_label(note, UiTheme.TEXT_DIM, ROW_FONT_SIZE - 3)
	box.add_child(note)
	return box


# ---------------------------------------------------------------------------
# 交互
# ---------------------------------------------------------------------------

func _on_slider_changed(value: float, key: String, display: String, label: Label) -> void:
	ConfigManager.set_value(key, value)
	label.text = _format_value(display, value)


func _on_toggled(pressed: bool, key: String) -> void:
	ConfigManager.set_value(key, pressed)


func _on_choice_selected(index: int, key: String, select: OptionButton) -> void:
	if index < 0 or index >= select.item_count:
		return
	ConfigManager.set_value(key, String(select.get_item_metadata(index)))


func _on_voice_mute_toggled(pressed: bool, char_id: String) -> void:
	AudioManager.set_voice_muted(char_id, pressed)


func _on_reset() -> void:
	ConfigManager.reset_to_default()
	_refresh()


func _refresh() -> void:
	for key in _slider_nodes.keys():
		var slider := _slider_nodes[key] as HSlider
		if slider != null:
			slider.set_value_no_signal(float(ConfigManager.get_value(String(key), slider.value)))
		var label := _value_nodes.get(key) as Label
		if label != null and slider != null:
			label.text = _format_value(String(_slider_display.get(key, "")), slider.value)
	for key in _toggle_nodes.keys():
		var check := _toggle_nodes[key] as CheckButton
		if check != null:
			check.set_pressed_no_signal(bool(ConfigManager.get_value(String(key), false)))
	for spec in LAYOUT:
		if typeof(spec) != TYPE_DICTIONARY:
			continue
		var cspec: Dictionary = spec
		if String(cspec.get("type", "")) != "choice":
			continue
		var ckey := String(cspec["key"])
		var select := _choice_nodes.get(ckey) as OptionButton
		if select == null:
			continue
		_fill_choice(select, String(cspec.get("source", "")))
		var current := String(ConfigManager.get_value(ckey, ""))
		# 配置里的曲子万一已不在候选里（比如收藏被清空），退回第一项（不播放）
		select.select(maxi(0, _index_of_meta(select, current)))
	# 静音列表可能被别处改过（比如调试控制台），同步一次界面
	for char_id in _voice_checks.keys():
		var check := _voice_checks[char_id] as CheckButton
		if check != null:
			check.set_pressed_no_signal(AudioManager.is_voice_muted(String(char_id)))


## 按 `source` 填一个下拉的选项。每项 metadata 存「值」（空串 = 不播放）。
func _fill_choice(select: OptionButton, source: String) -> void:
	select.clear()
	match source:
		"unlocked_music":
			select.add_item(I18n.t("（不播放）"))
			select.set_item_metadata(0, "")
			# 只列**已解锁**的曲目 —— 未解锁的曲子连标题都不该暴露
			for item in CollectionManager.get_unlocked_items("music"):
				var id := String((item as Dictionary).get("id", ""))
				select.add_item(String((item as Dictionary).get("title", id)))
				select.set_item_metadata(select.item_count - 1, id)
		_:
			select.add_item(I18n.t("（无）"))
			select.set_item_metadata(0, "")


static func _index_of_meta(select: OptionButton, value: String) -> int:
	for i in select.item_count:
		if String(select.get_item_metadata(i)) == value:
			return i
	return -1


# ---------------------------------------------------------------------------
# 角色清单
# ---------------------------------------------------------------------------

## 返回 [{id, name}]。优先 data/characters.json，再并上立绘目录里多出来的角色。
func _character_list() -> Array:
	var out: Array = []
	var seen := {}
	var raw: Variant = JsonUtil.load_json(CHARACTERS_PATH)
	if typeof(raw) == TYPE_DICTIONARY:
		var items: Variant = (raw as Dictionary).get("items", [])
		if typeof(items) == TYPE_ARRAY:
			for entry in (items as Array):
				if typeof(entry) != TYPE_DICTIONARY:
					continue
				var id := String((entry as Dictionary).get("id", "")).strip_edges()
				if id.is_empty() or seen.has(id):
					continue
				seen[id] = true
				out.append({"id": id, "name": String((entry as Dictionary).get("name", id))})
	# 立绘目录里多出来的角色也列上（没登记进 characters.json 的角色照样能静音）
	for id in PlaceholderAssets.list_characters():
		if seen.has(id):
			continue
		seen[id] = true
		out.append({"id": id, "name": id})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"]))
	return out


static func _format_value(display: String, value: float) -> String:
	match display:
		"percent":
			return "%d%%" % int(round(value * 100.0))
		"chars":
			return I18n.t("{n} 字/秒", {"n": int(round(value))})
		"seconds":
			return I18n.t("{n} 秒", {"n": "%.1f" % value})
	return str(value)
