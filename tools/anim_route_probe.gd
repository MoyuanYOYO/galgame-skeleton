extends Node

## 两条动画路线并排渲染对比（干净环境，不共用图层）
##   左：TextureRect + AnimatedTexture
##   右：AnimatedSprite2D + SpriteFrames
## 都在绿底上，用同一套带 alpha 的序列帧，看颜色推进与 alpha 混色。
##
##   Godot --path . res://tools/anim_route_probe.tscn

const DIR := "res://tools/fixtures/anim/"
const LEFT_PT := Vector2i(30, 60)      # 左：不透明区
const LEFT_TR := Vector2i(96, 60)      # 左：alpha 区
const RIGHT_PT := Vector2i(264, 64)    # 右：Sprite2D 中心
const RIGHT_TR := Vector2i(296, 64)


func _ready() -> void:
	await _wait(0.3)

	var bg := ColorRect.new()
	bg.color = Color(0, 1, 0, 1)
	bg.size = Vector2(1920, 1080)
	add_child(bg)

	# --- 左：AnimatedTexture ---
	var tex := AnimatedTexture.new()
	tex.frames = 3
	tex.speed_scale = 1.0
	for i in 3:
		tex.set_frame_texture(i, load(DIR + "seq_%d.png" % i))
		tex.set_frame_duration(i, 0.25)
	var rect := TextureRect.new()
	rect.texture = tex
	rect.size = Vector2(128, 128)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rect)

	# --- 右：AnimatedSprite2D（放在 Node2D 容器里，坐标独立于 Control 树）---
	var sf := SpriteFrames.new()
	sf.set_animation_speed("default", 4.0)
	for i in 3:
		sf.add_frame("default", load(DIR + "seq_%d.png" % i))
	var holder := Node2D.new()
	holder.position = Vector2(264, 64)
	add_child(holder)
	var sp := AnimatedSprite2D.new()
	sp.sprite_frames = sf
	sp.play()
	holder.add_child(sp)

	await _wait(0.3)
	print("--- 两条路线并排（绿底，序列帧带 alpha）---")
	for i in 10:
		await _wait(0.12)
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)
		print("  %d  AnimatedTexture: 不透明=%s alpha=%s | AnimatedSprite2D: 中心=%s alpha区=%s"
			% [i, _n(_px(img, LEFT_PT, vp)), _n(_px(img, LEFT_TR, vp)),
				_n(_px(img, RIGHT_PT, vp)), _n(_px(img, RIGHT_TR, vp))])
	get_tree().quit(0)


func _px(img: Image, pos: Vector2i, vp: Vector2) -> Color:
	var p := Vector2i(int(pos.x * vp.x), int(pos.y * vp.y))
	p.x = clampi(p.x, 0, img.get_width() - 1)
	p.y = clampi(p.y, 0, img.get_height() - 1)
	return img.get_pixel(p.x, p.y)


func _n(c: Color) -> String:
	return "(%.2f,%.2f,%.2f)" % [c.r, c.g, c.b]


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
