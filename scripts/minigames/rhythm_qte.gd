class_name RhythmQte
extends MinigameBase

## 节奏 QTE 示例小游戏
##
## 玩法：指针在横条上往返扫动，玩家在指针进入绿色判定区时按下
## 空格 / 回车 / 鼠标左键。命中达到 need 次即成功。
##
## 剧本用法：
##     minigame rhythm_qte rounds=5 need=3 speed=1.6
##
## 结果会写入变量 minigame_success / minigame_score / minigame_max，
## 并在成功时点亮旗标 rhythm_qte_cleared。

const DESIGN := Vector2(1920.0, 1080.0)
const BAR_WIDTH := 900.0
const BAR_HEIGHT := 28.0
const MARKER_WIDTH := 10.0
const BAR_Y := 640.0
const FEEDBACK_HOLD := 0.45
const RESULT_HOLD := 1.0

var _rounds: int = 5
var _need: int = 3
var _speed: float = 1.4
var _round_index: int = 0
var _hits: int = 0
var _marker_t: float = 0.0
var _direction: float = 1.0
var _zone_center: float = 0.5
var _zone_half: float = 0.09
var _finished: bool = false
var _locked: bool = false

var _status_label: Label
var _feedback_label: Label
var _result_label: Label
var _zone_rect: ColorRect
var _marker_rect: ColorRect


func _ready() -> void:
	# 根节点在场景里已是 full-rect 锚点，尺寸交给布局系统，不要手动设 size
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	set_process(false)


# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------

func _on_start() -> void:
	_rounds = maxi(1, param_int("rounds", 5))
	_need = clampi(param_int("need", 3), 0, _rounds)
	_speed = maxf(0.2, param_float("speed", 1.4))
	_round_index = 0
	_hits = 0
	_finished = false
	_locked = false
	_feedback_label.text = ""
	_result_label.visible = false
	_next_round()
	set_process(true)


func _process(delta: float) -> void:
	if _finished or _locked:
		return
	_marker_t += _direction * _speed * delta
	if _marker_t >= 1.0:
		_marker_t = 1.0
		_direction = -1.0
	elif _marker_t <= 0.0:
		_marker_t = 0.0
		_direction = 1.0
	_update_visuals()


func _input(event: InputEvent) -> void:
	if not _started or _finished or _locked:
		return
	var triggered := false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		triggered = mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	elif event is InputEventKey:
		var key := event as InputEventKey
		triggered = key.pressed and not key.echo \
			and (key.keycode == KEY_SPACE or key.keycode == KEY_ENTER)
	if triggered:
		get_viewport().set_input_as_handled()
		_judge()


# ---------------------------------------------------------------------------
# 回合逻辑
# ---------------------------------------------------------------------------

func _next_round() -> void:
	if _round_index >= _rounds:
		_finish_now()
		return
	_round_index += 1
	_locked = false
	_marker_t = 0.0
	_direction = 1.0
	_zone_center = randf_range(0.20, 0.80)
	_update_labels()
	_update_visuals()


func _judge() -> void:
	var hit := absf(_marker_t - _zone_center) <= _zone_half
	if hit:
		_hits += 1
	_locked = true
	_feedback_label.text = "命中！" if hit else "失手…"
	_feedback_label.add_theme_color_override(
		"font_color", UiTheme.SUCCESS if hit else UiTheme.DANGER)
	_update_labels()

	var tw := create_tween()
	tw.tween_interval(FEEDBACK_HOLD)
	tw.tween_callback(_next_round)


func _finish_now() -> void:
	if _finished:
		return
	_finished = true
	_locked = true
	set_process(false)

	var success := _hits >= _need
	_result_label.text = "命中 %d / %d —— %s" % [_hits, _rounds, "通过" if success else "未通过"]
	_result_label.add_theme_color_override(
		"font_color", UiTheme.SUCCESS if success else UiTheme.DANGER)
	_result_label.visible = true

	var tw := create_tween()
	tw.tween_interval(RESULT_HOLD)
	tw.tween_callback(func() -> void:
		finish({
			"success": success,
			"score": _hits,
			"max": _rounds,
			"need": _need,
		}))


func _update_labels() -> void:
	_status_label.text = "第 %d / %d 回合      命中 %d  （需 %d）" % [
		_round_index, _rounds, _hits, _need]


func _update_visuals() -> void:
	var bar_x := (DESIGN.x - BAR_WIDTH) * 0.5
	var zone_w := BAR_WIDTH * _zone_half * 2.0
	_zone_rect.position = Vector2(bar_x + BAR_WIDTH * _zone_center - zone_w * 0.5, BAR_Y)
	_marker_rect.position = Vector2(bar_x + (BAR_WIDTH - MARKER_WIDTH) * _marker_t, BAR_Y - 13.0)


# ---------------------------------------------------------------------------
# 界面构建
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var overlay := ColorRect.new()
	overlay.color = Color(0.043, 0.039, 0.078, 0.94)
	overlay.position = Vector2.ZERO
	overlay.size = DESIGN
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)

	_make_label("节奏 QTE", 56, UiTheme.TEXT, 190.0, HORIZONTAL_ALIGNMENT_CENTER)
	_status_label = _make_label("", 30, UiTheme.SPEAKER, 288.0, HORIZONTAL_ALIGNMENT_CENTER)

	var bar_bg := ColorRect.new()
	bar_bg.color = Color(0.16, 0.15, 0.26, 1.0)
	bar_bg.position = Vector2((DESIGN.x - BAR_WIDTH) * 0.5, BAR_Y)
	bar_bg.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar_bg)

	_zone_rect = ColorRect.new()
	_zone_rect.color = Color(0.443, 0.784, 0.612, 0.6)
	_zone_rect.size = Vector2(BAR_WIDTH * _zone_half * 2.0, BAR_HEIGHT)
	_zone_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_zone_rect)

	_marker_rect = ColorRect.new()
	_marker_rect.color = UiTheme.TEXT
	_marker_rect.size = Vector2(MARKER_WIDTH, BAR_HEIGHT + 26.0)
	_marker_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_marker_rect)

	_make_label("按下 [空格] 或 [鼠标左键] —— 让指针停在绿色判定区内",
		24, UiTheme.TEXT_DIM, 770.0, HORIZONTAL_ALIGNMENT_CENTER)
	_feedback_label = _make_label("", 46, UiTheme.TEXT, 840.0, HORIZONTAL_ALIGNMENT_CENTER)
	_result_label = _make_label("", 40, UiTheme.SPEAKER, 920.0, HORIZONTAL_ALIGNMENT_CENTER)
	_result_label.visible = false

	_update_visuals()


func _make_label(text: String, font_size: int, color: Color, y: float, align: int) -> Label:
	var label := Label.new()
	label.text = text
	label.position = Vector2(0.0, y)
	label.size = Vector2(DESIGN.x, float(font_size) + 18.0)
	label.horizontal_alignment = align as HorizontalAlignment
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", font_size)
	add_child(label)
	return label
