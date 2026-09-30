class_name SpectrumBars
extends Control

## 跳动的音轨频谱
##
## 数据来自 AudioManager 挂在 BGM 总线上的 AudioEffectSpectrumAnalyzer。
## 没有音频在播（骨架阶段没有素材）时会退化成一条缓慢起伏的「呼吸波」，
## 而不是死平的一条线 —— 既好看，也让人一眼知道控件是活的。

var bar_count: int = 32
var gap: float = 4.0
var scale_factor: float = 6.0
var idle_wave: float = 0.07

var bar_color: Color = Color(0.50, 0.47, 0.87)
var peak_color: Color = Color(0.95, 0.93, 1.0)

var _values := PackedFloat32Array()
var _phase: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	_values.resize(maxi(1, bar_count))


func set_bar_count(count: int) -> void:
	bar_count = maxi(1, count)
	_values.resize(bar_count)
	queue_redraw()


func _process(delta: float) -> void:
	_phase = fmod(_phase + delta * 1.6, TAU)
	var raw := AudioManager.get_spectrum_magnitudes(bar_count)
	if raw.size() != bar_count:
		raw.resize(bar_count)

	for i in bar_count:
		var target := clampf(raw[i] * scale_factor, 0.0, 1.0)
		if target < idle_wave:
			target = idle_wave * (0.45 + 0.55 * sin(_phase + float(i) * 0.42))
		# 平滑跟随，避免逐帧抖动
		_values[i] = lerpf(_values[i], target, 0.35)
	queue_redraw()


func _draw() -> void:
	var width := size.x
	var height := size.y
	if bar_count <= 0 or width <= 4.0 or height <= 4.0:
		return

	var bar_width := (width - gap * float(bar_count - 1)) / float(bar_count)
	if bar_width <= 0.5:
		return

	for i in bar_count:
		var value := clampf(_values[i], 0.0, 1.0)
		var bar_height := maxf(2.0, height * value)
		var x := float(i) * (bar_width + gap)
		draw_rect(Rect2(x, height - bar_height, bar_width, bar_height),
			bar_color.lerp(peak_color, value), true)
