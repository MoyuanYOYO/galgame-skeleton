class_name DialogueBox
extends Control

## 对话框
##
## 打字机效果完全由时间戳驱动：记下「开始显示的毫秒数」，每帧用
## 已流逝时间 × 速度反算应该显示到第几个字。好处是快进、跳过、
## 暂停都不会让显示进度错乱（用累加 tick 的写法就会）。
##
## 它不处理输入 —— 点击推进由 main.gd 统一分发。

signal advance_requested()
## 玩家点了说话人名字牌 —— 通常用来重播这一句的语音
signal voice_replay_requested()

@onready var _box: PanelContainer = %Box
@onready var _name_plate: PanelContainer = %NamePlate
@onready var _name_label: Label = %NameLabel
@onready var _text_label: RichTextLabel = %TextLabel
@onready var _indicator: Control = %Indicator

var _full_text: String = ""
var _reveal_start_ms: int = 0
var _typing: bool = false
var _indicator_tween: Tween
## 每个可见字符的显示时刻（秒）。由 TypingTimeline 预编译，
## 这样停顿 / 变速 / 跳过都只是换个 elapsed 去查表，不会错乱。
var _timeline := PackedFloat64Array()


func _ready() -> void:
	set_process(false)

	# 尺寸、内边距、位置全部来自 data/ui/ui_theme.json 的 dialogue 段
	var radius := int(UiTheme.dialogue_value("radius", 18))
	var border := int(UiTheme.dialogue_value("border_width", 1))
	var pad_h := int(UiTheme.dialogue_value("pad_h", 46))
	var pad_v := int(UiTheme.dialogue_value("pad_v", 30))

	_box.offset_left = UiTheme.dialogue_value("offset_left", 130.0)
	_box.offset_top = UiTheme.dialogue_value("offset_top", -320.0)
	_box.offset_right = UiTheme.dialogue_value("offset_right", -130.0)
	_box.offset_bottom = UiTheme.dialogue_value("offset_bottom", -70.0)

	_box.add_theme_stylebox_override("panel", UiTheme.stylebox(
		Color(UiTheme.BG_DEEP.r, UiTheme.BG_DEEP.g, UiTheme.BG_DEEP.b, 0.97),
		radius, UiTheme.BORDER, border, pad_h, pad_v))
	_name_plate.add_theme_stylebox_override("panel", UiTheme.stylebox(
		Color(UiTheme.NAME_PLATE.r, UiTheme.NAME_PLATE.g, UiTheme.NAME_PLATE.b, 0.98),
		10, UiTheme.BORDER, 1,
		int(UiTheme.dialogue_value("name_pad_h", 24)),
		int(UiTheme.dialogue_value("name_pad_v", 6))))
	UiTheme.apply_label(_name_label, UiTheme.SPEAKER,
		int(UiTheme.number("speaker", 26)), "dialogue")
	UiTheme.apply_rich_text(_text_label, UiTheme.TEXT,
		int(UiTheme.number("dialogue", 30)), "dialogue")

	# BBCode 文字特效。[shake] / [wave] / [rainbow] / [fade] / [pulse] 等
	# 是 Godot 内置的，直接可用；下面三个是项目自定义的。
	_text_label.bbcode_enabled = true
	_text_label.custom_effects = [
		BounceEffect.new(),
		GlitchEffect.new(),
		BlinkEffect.new(),
	]

	_indicator.add_child(UiTheme.make_triangle(20.0))

	# 名字牌做成可点的 —— 点一下重播这一句的语音。
	# 必须吃掉点击事件，否则会顺着 _unhandled_input 把对白推进下去。
	_name_plate.mouse_filter = Control.MOUSE_FILTER_STOP
	_name_plate.tooltip_text = I18n.t("点击重播语音")
	_name_plate.gui_input.connect(_on_name_plate_input)

	_stop_indicator()
	hide_box()


func _on_name_plate_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var click := event as InputEventMouseButton
		if click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
			voice_replay_requested.emit()
			accept_event()


func _process(_delta: float) -> void:
	if not _typing:
		return
	var elapsed := float(Time.get_ticks_msec() - _reveal_start_ms) / 1000.0
	# 二分查表，长文本也不会每帧线性扫描
	var reveal := TypingTimeline.revealed_count(_timeline, elapsed)
	if reveal >= _timeline.size():
		_finish_typing()
	else:
		_text_label.visible_characters = reveal


# ---------------------------------------------------------------------------
# 对外接口
# ---------------------------------------------------------------------------

## already_read 由调用方传入，而不是这里自己查 ReadTracker ——
## _on_say 在显示之前就把它标记成已读，这里再查永远是「已读」。
func show_line(speaker: String, text: String, already_read: bool = false) -> void:
	visible = true
	_full_text = text

	if speaker.is_empty():
		_name_plate.visible = false
	else:
		_name_plate.visible = true
		_name_label.text = speaker

	# 已读文本变暗：只改**默认字色**，不去给文本包一层 [color] ——
	# 包起来会跟剧本里已有的颜色标记、自定义特效打架。
	var dim := already_read and bool(ConfigManager.get_value("dim_read_text", false))
	_text_label.add_theme_color_override(
		"default_color", UiTheme.TEXT_DIM if dim else UiTheme.TEXT)

	# 先把节奏标记编译成时间轴，再交给 RichTextLabel 渲染。
	# 顺序很重要：display 里已经剥掉了 [wait=] / [speed=]，
	# 所以「可见字符数」和「时间轴长度」必然一致。
	var speed := maxf(1.0, float(ConfigManager.get_value("text_speed", 45.0)))
	var compiled := TypingTimeline.build(text, speed)
	_text_label.text = String(compiled.get("display", text))
	var times: PackedFloat64Array = compiled.get("times", PackedFloat64Array())
	_timeline = times

	_text_label.visible_characters = 0
	_reveal_start_ms = Time.get_ticks_msec()
	_typing = true
	_stop_indicator()
	set_process(true)


## 若正在打字则立刻显示完整文本；返回是否发生了「补完」
func complete_typing() -> bool:
	if not _typing:
		return false
	_finish_typing()
	return true


func is_typing() -> bool:
	return _typing


func hide_box() -> void:
	_typing = false
	set_process(false)
	_timeline = PackedFloat64Array()
	_stop_indicator()
	visible = false


func get_full_text() -> String:
	return _full_text


# ---------------------------------------------------------------------------
# 内部
# ---------------------------------------------------------------------------

func _finish_typing() -> void:
	_typing = false
	set_process(false)
	_text_label.visible_characters = -1
	_start_indicator()


func _start_indicator() -> void:
	_stop_indicator()
	_indicator.visible = true
	_indicator.modulate.a = 1.0
	_indicator_tween = create_tween().set_loops()
	_indicator_tween.tween_property(_indicator, "modulate:a", 0.15, 0.6)
	_indicator_tween.tween_property(_indicator, "modulate:a", 1.0, 0.6)


func _stop_indicator() -> void:
	if _indicator_tween != null and _indicator_tween.is_valid():
		_indicator_tween.kill()
	_indicator_tween = null
	if _indicator != null:
		_indicator.visible = false
