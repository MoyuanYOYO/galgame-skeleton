class_name LockIcon
extends Control

## 程序化绘制的锁图标
##
## 默认字体不含锁形字形（🔒 会渲染成豆腐块），所以直接画：
## 上方一个半圆环锁梁，下方一个圆角锁体，中间一个钥匙孔。
## 锁体用 StyleBoxFlat 绘制以获得真正的圆角。

var body_color: Color = Color(0.72, 0.60, 0.54)   # 暖褐灰：在奶油卡片上够显眼，不偏紫
var shackle_color: Color = Color(0.80, 0.70, 0.64)
var keyhole_color: Color = Color(0.30, 0.24, 0.20)

var _body_style: StyleBoxFlat


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_rebuild)
	_rebuild()


func _rebuild() -> void:
	var side := minf(size.x, size.y)
	_body_style = StyleBoxFlat.new()
	_body_style.bg_color = body_color
	_body_style.set_corner_radius_all(int(maxf(3.0, side * 0.09)))
	queue_redraw()


func _draw() -> void:
	var side := minf(size.x, size.y)
	if side <= 1.0 or _body_style == null:
		return

	var center_x := size.x * 0.5
	var body_w := side * 0.74
	var body_h := side * 0.50
	var body_top := size.y * 0.44

	# 锁梁：上半圆环
	var shackle_center := Vector2(center_x, body_top)
	var shackle_radius := side * 0.23
	var arc := PackedVector2Array()
	var steps := 28
	for i in steps + 1:
		var angle := PI + PI * float(i) / float(steps)
		arc.append(shackle_center + Vector2(cos(angle), sin(angle)) * shackle_radius)
	draw_polyline(arc, shackle_color, maxf(2.0, side * 0.085), true)

	# 锁体
	draw_style_box(_body_style, Rect2(center_x - body_w * 0.5, body_top, body_w, body_h))

	# 钥匙孔
	var keyhole_center := Vector2(center_x, body_top + body_h * 0.36)
	draw_circle(keyhole_center, side * 0.062, keyhole_color)
	draw_rect(Rect2(center_x - side * 0.028, keyhole_center.y,
		side * 0.056, body_h * 0.34), keyhole_color, true)
