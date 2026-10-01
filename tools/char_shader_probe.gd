extends Node

## 立绘材质语义实验
##
## 同一张真实立绘贴图，分别用「无材质 / 各种 fragment 写法」渲染，
## 逐像素量渲染色，看哪种写法会变暗。
##
##   Godot --path . res://tools/char_shader_probe.tscn

const SPRITE := "res://assets/sprites/alice/normal.png"
const RECT_SIZE := Vector2(400.0, 900.0)
const SAMPLE_BOX := Rect2i(60, 60, 280, 700)

var _layer: CanvasLayer
var _slots: Array[TextureRect] = []


func _ready() -> void:
	await _wait(0.3)
	_layer = CanvasLayer.new()
	_layer.layer = 5
	get_tree().root.add_child(_layer)

	var cases := {
		"无材质": "",
		"A: COLOR = tex": "shader_type canvas_item;\nvoid fragment(){ COLOR = texture(TEXTURE, UV); }\n",
		"B: COLOR = tex*COLOR": "shader_type canvas_item;\nvoid fragment(){ COLOR = texture(TEXTURE, UV) * COLOR; }\n",
		"C: 项目 char_expr": "FILE",
	}

	for label in cases.keys():
		var code: String = cases[label]
		var rect := TextureRect.new()
		rect.texture = load(SPRITE)
		rect.size = RECT_SIZE
		rect.position = Vector2.ZERO
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.modulate = Color(1, 1, 1, 1)
		if code == "FILE":
			var m := ShaderMaterial.new()
			m.shader = load("res://shaders/char_expr.gdshader")
			m.set_shader_parameter("has_from", false)
			m.set_shader_parameter("progress", 1.0)
			rect.material = m
		elif not code.is_empty():
			var s := Shader.new()
			s.code = code
			var m := ShaderMaterial.new()
			m.shader = s
			rect.material = m
		_layer.add_child(rect)
		await _wait(0.25)
		var mean := await _mean_in(SAMPLE_BOX)
		print("[probe] %-22s → 立绘区平均亮度 %.2f" % [label, mean])
		_layer.remove_child(rect)
		rect.queue_free()
		await _wait(0.1)

	# 顺带验证 modulate 是否仍然生效（压暗到 0.55）
	var rect2 := TextureRect.new()
	rect2.texture = load(SPRITE)
	rect2.size = RECT_SIZE
	rect2.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect2.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m2 := ShaderMaterial.new()
	m2.shader = load("res://shaders/char_expr.gdshader")
	m2.set_shader_parameter("has_from", false)
	m2.set_shader_parameter("progress", 1.0)
	rect2.material = m2
	rect2.modulate = Color(0.55, 0.55, 0.55, 1.0)
	_layer.add_child(rect2)
	await _wait(0.25)
	print("[probe] char_expr + modulate=0.55 → %.2f（应约为上一行 × 0.55）"
		% (await _mean_in(SAMPLE_BOX)))

	get_tree().quit(0)


func _mean_in(box: Rect2i) -> float:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)
	var total := 0.0
	var n := 0
	for y in range(box.position.y, box.position.y + box.size.y, 3):
		for x in range(box.position.x, box.position.x + box.size.x, 3):
			var p := Vector2i(int(x * vp.x), int(y * vp.y))
			if p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c := img.get_pixel(p.x, p.y)
			total += c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			n += 1
	return total / maxf(1.0, float(n))


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
