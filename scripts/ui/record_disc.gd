class_name RecordDisc
extends Control

## 旋转的黑胶唱片
##
## 纯程序化绘制，不依赖任何贴图素材。
## 注意：唱片主体与纹路是旋转对称的，光靠它们看不出在转 —— 所以标签上画了
## 一个偏心标记，转起来才肉眼可见。
##
## 外观（半径 / 转速 / 配色比例）全部来自 gallery_theme.json。

var spin_speed: float = 0.85
var hole_ratio: float = 0.17
var label_ratio: float = 0.44

var vinyl_color: Color = Color(0.07, 0.07, 0.10)
var groove_color: Color = Color(0.17, 0.17, 0.24)
var label_color: Color = Color(0.91, 0.54, 0.45)   # 珊瑚：对齐水彩绘本主题（原薰衣草紫）
var marker_color: Color = Color(1.0, 0.97, 0.94)
var hole_color: Color = Color(0.06, 0.06, 0.09)

var _angle: float = 0.0
var _spinning: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	set_process(false)


func set_spinning(on: bool) -> void:
	if _spinning == on:
		return
	_spinning = on
	set_process(on)
	if not on:
		queue_redraw()


func is_spinning() -> bool:
	return _spinning


func _process(delta: float) -> void:
	_angle = fmod(_angle + delta * spin_speed, TAU)
	queue_redraw()


func _draw() -> void:
	var side := minf(size.x, size.y)
	if side <= 4.0:
		return

	var center := size * 0.5
	var radius := side * 0.5

	# 唱片主体
	draw_circle(center, radius, vinyl_color)

	# 同心纹路
	var groove_radius := radius * 0.94
	var groove_step := radius * 0.055
	var label_radius := radius * label_ratio
	while groove_radius > label_radius + groove_step * 0.5:
		draw_arc(center, groove_radius, 0.0, TAU, 48, groove_color, 1.0, true)
		groove_radius -= groove_step

	# 标签盘
	draw_circle(center, label_radius, label_color)
	draw_circle(center, label_radius * 0.82, label_color.lightened(0.10))

	# 随角度旋转的偏心标记 —— 没有它就看不出唱片在转
	var direction := Vector2(cos(_angle - PI * 0.5), sin(_angle - PI * 0.5))
	draw_line(center, center + direction * label_radius * 0.86,
		marker_color, maxf(2.0, radius * 0.018), true)
	draw_circle(center + direction * label_radius * 0.48, label_radius * 0.11,
		marker_color.darkened(0.25))

	# 中心孔
	draw_circle(center, radius * hole_ratio, hole_color)

	# 固定高光（不随旋转，像是有固定光源打在上面）
	draw_arc(center, radius * 0.97, -PI * 0.72, -PI * 0.18, 28,
		Color(1.0, 1.0, 1.0, 0.13), maxf(2.0, radius * 0.035), true)
