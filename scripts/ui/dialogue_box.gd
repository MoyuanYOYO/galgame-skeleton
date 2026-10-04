class_name DialogueBox
extends Control

## 对话框
##
## 打字机效果完全由时间戳驱动：记下「开始显示的毫秒数」，每帧用
## 已流逝时间 × 速度反算应该显示到第几个字。好处是快进、跳过、
## 暂停都不会让显示进度错乱（用累加 tick 的写法就会）。
##
## 它不处理输入 —— 点击推进由 main.gd 统一分发。
##
## **停顿点（stop point）**：时间轴上「会停一下」的位置，两类 ——
##   · 自动停顿（剧本 `[wait=0.5]`）—— 停一下自己接着走
##   · 点击门控（剧本 `[stop]`）—— 停住，等玩家点一下才接着走
## 玩家点击时**不是**直接显示全文，而是快进到**下一个停顿点**；
## 后面没有停顿点了才补完整句。这既是 galgame 的惯例，也让作者能精确
## 控制「这句要在这里断一下」。
##
## **内联音频效果器**：剧本 `[fx=glitch bus=bgm]` 这类标记会在
## 显示到那个字时触发一次音频效果 —— 由本类负责在正确的时刻调 AudioManager。

signal advance_requested()
## 玩家点了说话人名字牌 —— 通常用来重播这一句的语音
signal voice_replay_requested()

## 打字音效的间隔（每显示这么多字响一次）。太密会糊成噪音，
## 太疏就不像在打字；2 是「能听出节奏但不会吵」的常见取值。
const TYPING_SFX_INTERVAL := 2

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
## 停顿点（升序）：[{index: 可见字符数, gate: 是否需点击}]
var _stops: Array = []
## 下一个待处理的停顿点在 _stops 里的下标
var _stop_cursor: int = 0
## 正停在点击门控上（此时 _typing 仍为 true，等 advance_typing 放行）
var _halted: bool = false
## 效果器触发点（升序）：[{index, kind, bus, duration, strength, pitch}]
var _events: Array = []
var _event_cursor: int = 0
## 上次响打字音时已显示到第几个字
var _sfx_at: int = 0


func _ready() -> void:
	set_process(false)

	# 尺寸、位置来自 data/ui/ui_theme.json 的 dialogue 段。
	# 样式统一走 UiTheme：配了九宫格贴图就用贴图，没配就回退到程序化圆角矩形。
	# 这里不关心是哪一种，所以 radius / border_width 不再需要单独取。
	_box.offset_left = UiTheme.dialogue_value("offset_left", 130.0)
	_box.offset_top = UiTheme.dialogue_value("offset_top", -320.0)
	_box.offset_right = UiTheme.dialogue_value("offset_right", -130.0)
	_box.offset_bottom = UiTheme.dialogue_value("offset_bottom", -70.0)

	# 编辑器里手动 override 过的 StyleBox 优先（同 UiTheme.apply_panel 的约定），
	# 手改贴图 / 样式不会被运行时代码盖掉。
	if not _box.has_theme_stylebox_override("panel"):
		_box.add_theme_stylebox_override("panel", UiTheme.dialogue_stylebox(
			Color(UiTheme.BG_DEEP.r, UiTheme.BG_DEEP.g, UiTheme.BG_DEEP.b, 0.97)))
	if not _name_plate.has_theme_stylebox_override("panel"):
		_name_plate.add_theme_stylebox_override("panel", UiTheme.nameplate_stylebox(
			Color(UiTheme.NAME_PLATE.r, UiTheme.NAME_PLATE.g, UiTheme.NAME_PLATE.b, 0.98)))
	UiTheme.apply_label(_name_label, UiTheme.SPEAKER,
		int(UiTheme.number("speaker", 26)), "dialogue")
	UiTheme.apply_rich_text(_text_label, UiTheme.TEXT,
		int(UiTheme.number("dialogue", 30)), "dialogue")

	# BBCode 文字特效。[shake] / [wave] / [rainbow] / [fade] / [pulse] 等
	# 是 Godot 内置的，直接可用；项目自定义的那几个登记在 TextEffects 里
	# （列表只有一份，否则「谁漏注册了谁就漏成文本」）。
	_text_label.bbcode_enabled = true
	_text_label.custom_effects = TextEffects.all()

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

	# ① 越过效果器触发点 → 触发
	while _event_cursor < _events.size() \
			and reveal >= int((_events[_event_cursor] as Dictionary).get("index", 0)):
		_fire_fx(_events[_event_cursor] as Dictionary)
		_event_cursor += 1

	# ② 自动停顿点（[wait]）走过去了就滑过它 —— 它不需要点击放行
	while _stop_cursor < _stops.size():
		var s: Dictionary = _stops[_stop_cursor]
		if bool(s.get("gate", false)) or reveal <= int(s.get("index", 0)):
			break
		_stop_cursor += 1

	# ③ 撞上点击门控 → 停住。注意这里**必须**钳位并 return，
	#    否则 elapsed 继续涨，门控会被整段跳过去。
	if _stop_cursor < _stops.size():
		var gate: Dictionary = _stops[_stop_cursor]
		if bool(gate.get("gate", false)):
			var gate_index := int(gate.get("index", 0))
			if reveal >= gate_index:
				_halted = true
				_tick_typing_sfx(gate_index)
				_text_label.visible_characters = gate_index
				return

	_tick_typing_sfx(reveal)
	if reveal >= _timeline.size():
		_finish_typing()
	else:
		_text_label.visible_characters = reveal


## 打字音：每 `TYPING_SFX_INTERVAL` 个可见字符响一次。
##
## 触发点是「已显示字符数」而不是「经过的时间」—— 这样快进、变速、停顿
## 都不会让音效和字的出现脱节（同一套时间轴口径）。
func _tick_typing_sfx(reveal: int) -> void:
	if reveal - _sfx_at < TYPING_SFX_INTERVAL:
		return
	_sfx_at = reveal
	AudioManager.play_typing()


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
	# 顺序很重要：display 里已经剥掉了 [wait=] / [stop] / [fx=]，
	# 所以「可见字符数」和「时间轴长度」必然一致。
	var speed := maxf(1.0, float(ConfigManager.get_value("text_speed", 45.0)))
	var compiled := TypingTimeline.build(text, speed)
	_text_label.text = String(compiled.get("display", text))
	var times: PackedFloat64Array = compiled.get("times", PackedFloat64Array())
	_timeline = times
	_stops = compiled.get("stops", []) as Array
	_events = compiled.get("events", []) as Array
	_stop_cursor = 0
	_event_cursor = 0
	_halted = false
	_sfx_at = 0

	_text_label.visible_characters = 0
	_reveal_start_ms = Time.get_ticks_msec()
	_typing = true
	_stop_indicator()
	set_process(true)


## 玩家点击推进。
##
## 三种情况：
##   1. 正停在点击门控上 → 放行，接着显示
##   2. 正在打字 → **快进到下一个停顿点**（没有下一个就补完整句）
##   3. 已经打完 → 返回 false，交给调用方推进剧本
##
## 返回 true 表示「这次点击被对话框消化了」。
func advance_typing() -> bool:
	if not _typing:
		return false
	# 设置里可以关掉「跳到停顿点」，回到「一点就显示全文」的老手感
	if not _click_to_stop_enabled():
		_finish_typing()
		return true
	if _halted:
		_halted = false
		_stop_cursor += 1
		return true
	var target := _next_stop_index()
	if target < 0:
		_finish_typing()
		return true
	_seek_to(target)
	# 落点是个自动停顿（[wait]）→ 直接把它划掉，下一次点击去找再下一个。
	# 不划的话连点两下会原地不动，手感像卡住。
	if _stop_cursor < _stops.size() \
			and not bool((_stops[_stop_cursor] as Dictionary).get("gate", false)):
		_stop_cursor += 1
	return true


## 立刻显示完整文本（跳过 / 自动播放用）。silent=true 时不触发剩余的效果器
## —— 快进时把整句的 glitch 一次性全放出来只会是一团噪音。
func complete_typing(silent: bool = false) -> bool:
	if not _typing:
		return false
	_finish_typing(not silent)
	return true


func is_typing() -> bool:
	return _typing


## 是否正停在点击门控上（测试 / 状态查询用）
func is_halted() -> bool:
	return _typing and _halted


## 这一句还剩几个停顿点没走（测试用）
func remaining_stops() -> int:
	return maxi(0, _stops.size() - _stop_cursor)


func hide_box() -> void:
	_typing = false
	_halted = false
	set_process(false)
	_timeline = PackedFloat64Array()
	_stops = []
	_events = []
	_stop_cursor = 0
	_event_cursor = 0
	_sfx_at = 0
	_stop_indicator()
	visible = false


func get_full_text() -> String:
	return _full_text


# ---------------------------------------------------------------------------
# 内部
# ---------------------------------------------------------------------------

## 下一个停顿点在时间轴上的可见字符下标；没有则 -1
func _next_stop_index() -> int:
	if _stop_cursor < _stops.size():
		return int((_stops[_stop_cursor] as Dictionary).get("index", 0))
	return -1


## 把「已流逝时间」直接拨到「第 index 个可见字符刚出现」的那一刻。
##
## 时间轴是升序的，所以第 index 个字符出现的时刻就是 times[index-1]。
## 加 1ms 是为了跨过等号（revealed_count 用的是 `times[mid] <= elapsed`），
## 否则会正好停在前一个字符上。
func _seek_to(index: int) -> void:
	var t := 0.0
	if index > 0 and index - 1 < _timeline.size():
		t = _timeline[index - 1]
	_reveal_start_ms = Time.get_ticks_msec() - int(t * 1000.0) - 1


func _click_to_stop_enabled() -> bool:
	return bool(ConfigManager.get_value("click_skip_to_stop", true))


## 触发一次内联音频效果器。kind == "off" 表示清除该总线上加过的效果器。
func _fire_fx(ev: Dictionary) -> void:
	var bus := String(ev.get("bus", TypingTimeline.FX_DEFAULT_BUS))
	var kind := String(ev.get("kind", "glitch"))
	if kind == "off" or kind == "none" or kind == "clear":
		AudioManager.clear_audio_fx(bus)
		return
	AudioManager.apply_audio_fx(bus, kind, {
		"duration": float(ev.get("duration", TypingTimeline.FX_DEFAULT_DURATION)),
		"strength": float(ev.get("strength", 1.0)),
		"pitch": float(ev.get("pitch", 1.0)),
	})


func _finish_typing(fire_events: bool = true) -> void:
	# 收尾时把没走到（或刚被快进跳过）的触发点补上，
	# 否则剧本末尾的 `[fx=off]` 永远不执行，效果会一直挂在总线上。
	if fire_events:
		while _event_cursor < _events.size():
			_fire_fx(_events[_event_cursor] as Dictionary)
			_event_cursor += 1
	else:
		_event_cursor = _events.size()
	_typing = false
	_halted = false
	_stop_cursor = _stops.size()
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
