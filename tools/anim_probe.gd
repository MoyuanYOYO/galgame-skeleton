extends Node

## 动图 / 序列帧能力实测
##
## 1. Godot 能不能直接加载 GIF / APNG / 动画 WebP？（预期：只认第一帧）
## 2. AnimatedTexture（纯 Texture2D 资源）+ 带 alpha 的序列帧，能不能真的动起来、
##    alpha 保不保得住？（渲染两帧逐像素量）
##
##   Godot --path . res://tools/anim_probe.tscn

const DIR := "res://tools/fixtures/anim/"
const FRAME_W := 128
const FRAME_H := 128
## 采样点：左半应完全不透明，右半应半透明
const SAMPLE_OPAQUE := Vector2i(30, 60)
const SAMPLE_TRANS := Vector2i(96, 60)
const SAMPLE_OUTSIDE := Vector2i(300, 300)

var _layer: CanvasLayer


func _ready() -> void:
	await _wait(0.3)
	_layer = CanvasLayer.new()
	_layer.layer = 5
	get_tree().root.add_child(_layer)

	await _test_animated_files()
	await _test_animated_texture()

	get_tree().quit(0)


# --- 1. 动图文件格式 ---------------------------------------------------------

func _test_animated_files() -> void:
	print("--- 动图文件格式（能否直接当动画用）---")
	for fname_v in ["anim.gif", "anim.png", "anim.webp"]:
		var fname := String(fname_v)
		var path: String = DIR + fname
		if not FileAccess.file_exists(path):
			print("  %-12s 文件缺失" % fname)
			continue
		var raw := FileAccess.get_file_as_bytes(path)
		# Godot 4 里这些解码函数是**实例方法**（返回 Error），不是静态函数
		var img := Image.new()
		var decode := "无对应解码器"
		if fname.ends_with(".png"):
			decode = "OK" if img.load_png_from_buffer(raw) == OK else "失败"
		elif fname.ends_with(".webp"):
			decode = "OK" if img.load_webp_from_buffer(raw) == OK else "失败"
		var via_loader := ResourceLoader.load(path) as Texture2D
		print("  %-12s 静态解码=%s  经 ResourceLoader=%s  尺寸=%s"
			% [fname, decode,
				"成功" if via_loader != null else "失败",
				str(via_loader.get_size()) if via_loader != null else "-"])
	print("  结论：GIF/APNG/动画WebP 都只能拿到第一帧（Godot 没有动图解码器）。")
	print("        GIF 更是完全没有解码器；APNG/动画WebP 只是「第一帧能读」。\n")


# --- 2. AnimatedTexture + alpha ---------------------------------------------

func _test_animated_texture() -> void:
	print("--- AnimatedTexture（纯 Texture2D 资源，可直接塞进现有 TextureRect）---")
	var tex := AnimatedTexture.new()
	tex.frames = 3
	tex.speed_scale = 1.0
	for i in 3:
		tex.set_frame_texture(i, load(DIR + "seq_%d.png" % i))
		tex.set_frame_duration(i, 1.0)

	var rect := TextureRect.new()
	rect.texture = tex
	rect.size = Vector2(FRAME_W, FRAME_H)
	rect.position = Vector2(0, 0)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(rect)

	# 背景铺绿，半透明区应该能透出绿
	var bg := ColorRect.new()
	bg.color = Color(0, 1, 0, 1)
	bg.size = Vector2(1920, 1080)
	_layer.add_child(bg)
	_layer.move_child(bg, 0)

	await _wait(0.4)
	for i in 3:
		tex.current_frame = i
		await _wait(0.15)
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)
		var op := _px(img, SAMPLE_OPAQUE, vp)
		var tr := _px(img, SAMPLE_TRANS, vp)
		var out := _px(img, SAMPLE_OUTSIDE, vp)
		print("  帧%d  左半(不透明)=%s  右半(alpha96)=%s  画面外=%s"
			% [i, _fmt(op), _fmt(tr), _fmt(out)])
	print("  期望：三帧颜色依次红/绿/蓝；右半混入背景绿（alpha 生效）；画面外纯绿")
	print("  注意 AnimatedTexture.MAX_FRAMES = %d\n" % AnimatedTexture.MAX_FRAMES)


func _px(img: Image, pos: Vector2i, vp: Vector2) -> Color:
	var p := Vector2i(int(pos.x * vp.x), int(pos.y * vp.y))
	p.x = clampi(p.x, 0, img.get_width() - 1)
	p.y = clampi(p.y, 0, img.get_height() - 1)
	return img.get_pixel(p.x, p.y)


func _fmt(c: Color) -> String:
	return "(%.2f,%.2f,%.2f,%.2f)" % [c.r, c.g, c.b, c.a]


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
