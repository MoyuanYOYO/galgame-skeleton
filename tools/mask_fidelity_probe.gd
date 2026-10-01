extends Node

## 转场遮罩保真度验证（纯净版）
##
## 旧层 = classroom，新层 = rooftop + 项目 transition.gdshader。
## 把 progress 固定在 0 / 0.5 / 1，逐像素和两张素材原图比：
## 每个像素都应该「约等于旧图」或「约等于新图」，绝不该比两者都暗。
##
##   Godot --path . res://tools/mask_fidelity_probe.tscn

const BG_OLD := "res://assets/bg/classroom.png"
const BG_NEW := "res://assets/bg/rooftop.png"

var _layer: CanvasLayer


func _ready() -> void:
	await _wait(0.3)
	_layer = CanvasLayer.new()
	_layer.layer = 5
	get_tree().root.add_child(_layer)

	var old_rect := _bg_rect(BG_OLD)
	_layer.add_child(old_rect)

	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/transition.gdshader")
	var new_rect := _bg_rect(BG_NEW)
	new_rect.material = mat
	_layer.add_child(new_rect)
	await _wait(0.3)

	var old_img := (load(BG_OLD) as Texture2D).get_image()
	var new_img := (load(BG_NEW) as Texture2D).get_image()
	old_img.convert(Image.FORMAT_RGBA8)
	new_img.convert(Image.FORMAT_RGBA8)

	for progress in [0.0, 0.5, 1.0]:
		for mode in [0, 1, 2, 3]:
			mat.set_shader_parameter("mode", mode)
			mat.set_shader_parameter("progress", progress)
			mat.set_shader_parameter("softness", 0.06)
			await _wait(0.25)
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)

			var worst := 1.0
			var acc := 0.0
			var n := 0
			for y in range(60, 1000, 60):
				for x in range(60, 1860, 60):
					var got := _lum(img, x, y, vp)
					var lo := _lum(old_img, x, y, vp)
					var ln := _lum(new_img, x, y, vp)
					# 取「更像哪张原图」，用那个当基准
					var ref := lo if absf(got - lo) < absf(got - ln) else ln
					if ref < 0.1:
						continue
					var r := got / ref
					acc += r
					n += 1
					worst = minf(worst, r)
			print("[probe] mode=%d progress=%.1f  平均 渲染/原图 = %.3f  最暗 %.3f  (n=%d)"
				% [mode, progress, acc / maxf(1.0, float(n)), worst, n])

	await _self_check()
	get_tree().quit(0)


## 自检：把「乘一遍进来的 COLOR」那个写法放回来，探针必须能量出变暗。
## 量不出的话这个探针就是摆设。
func _self_check() -> void:
	var s := Shader.new()
	s.code = "shader_type canvas_item;\nuniform float progress = 0.5;\nuniform int mode = 1;\nuniform float softness = 0.06;\nvoid fragment(){\n\tvec4 t = texture(TEXTURE, UV);\n\tfloat mask = smoothstep(UV.x - softness, UV.x + softness, progress);\n\tCOLOR = vec4(t.rgb, t.a * mask) * COLOR;\n}\n"
	var mat := ShaderMaterial.new()
	mat.shader = s
	var r := _bg_rect(BG_NEW)
	r.material = mat
	_layer.add_child(r)
	await _wait(0.3)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var new_img := (load(BG_NEW) as Texture2D).get_image()
	new_img.convert(Image.FORMAT_RGBA8)
	var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)
	var acc := 0.0
	var n := 0
	for y in range(60, 1000, 60):
		for x in range(60, 900, 60):     # 只取已显现的左半
			var ln := _lum(new_img, x, y, vp)
			if ln < 0.1:
				continue
			acc += _lum(img, x, y, vp) / ln
			n += 1
	print("[probe] 自检：含 * COLOR 的坏写法 平均 渲染/原图 = %.3f（应明显 < 1）"
		% (acc / maxf(1.0, float(n))))


func _bg_rect(path: String) -> TextureRect:
	var r := TextureRect.new()
	r.texture = load(path)
	r.size = Vector2(1920, 1080)
	r.position = Vector2.ZERO
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _lum(img: Image, x: float, y: float, vp: Vector2) -> float:
	var p := Vector2i(int(x * vp.x), int(y * vp.y))
	p.x = clampi(p.x, 0, img.get_width() - 1)
	p.y = clampi(p.y, 0, img.get_height() - 1)
	var c := img.get_pixel(p.x, p.y)
	return c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
