extends Node

## 风险验证：AnimatedTexture 能不能当 shader 的 sampler2D 输入？
##
## 立绘的「表情交叉混合」（char_expr.gdshader）会把上一张贴图塞进 `from_tex`
## 采样器。如果立绘换成 AnimatedTexture，这条路必须还能走 —— 否则一挂动画，
## 表情过渡就整段失效（而且逻辑测试全绿，看不出来）。
##
## 三种情况都要量：
##   A. 节点 texture 是 AnimatedTexture（直接采样 TEXTURE）
##   B. from_tex 是 AnimatedTexture（采样器输入）
##   C. 两者都是 AnimatedTexture，progress=0.5（交叉混合中点）
##
##   Godot --path . res://tools/anim_sampler_probe.tscn

const DIR := "res://tools/fixtures/anim/"
## seq_0 红 / seq_1 绿 / seq_2 蓝；取不透明区判色
const SAMPLE := Vector2i(30, 60)

var _layer: CanvasLayer


func _ready() -> void:
	await _wait(0.3)
	_layer = CanvasLayer.new()
	_layer.layer = 5
	get_tree().root.add_child(_layer)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 1)
	bg.size = Vector2(1920, 1080)
	_layer.add_child(bg)

	# 固定在第 0 帧（红）的动画贴图，用来当 from_tex
	var red_anim := _anim(0)
	# 固定在第 2 帧（蓝）的动画贴图，用来当主贴图
	var blue_anim := _anim(2)

	var shader := load("res://shaders/char_expr.gdshader") as Shader

	# A. 主贴图 = 动画，无交叉混合
	var mat_a := ShaderMaterial.new()
	mat_a.shader = shader
	mat_a.set_shader_parameter("has_from", false)
	mat_a.set_shader_parameter("progress", 1.0)
	await _run("A 主贴图=AnimatedTexture(第2帧,蓝)", blue_anim, mat_a)

	# B. 主贴图 = 静态红，from_tex = 动画(第2帧,蓝)，progress=1 → 应看到蓝
	var mat_b := ShaderMaterial.new()
	mat_b.shader = shader
	mat_b.set_shader_parameter("has_from", true)
	mat_b.set_shader_parameter("progress", 1.0)
	mat_b.set_shader_parameter("from_tex", blue_anim)
	await _run("B from_tex=动画(蓝), progress=1", load(DIR + "seq_0.png"), mat_b)

	# C. 主贴图 = 动画(蓝)，from_tex = 动画(红)，progress=0 → 应看到红
	var mat_c := ShaderMaterial.new()
	mat_c.shader = shader
	mat_c.set_shader_parameter("has_from", true)
	mat_c.set_shader_parameter("progress", 0.0)
	mat_c.set_shader_parameter("from_tex", red_anim)
	await _run("C from_tex=动画(红), progress=0", blue_anim, mat_c)

	# D. 交叉混合中点：主=蓝(动画)，from=红(动画)，progress=0.5 → 应约 (0.5,0,0.5)
	var mat_d := ShaderMaterial.new()
	mat_d.shader = shader
	mat_d.set_shader_parameter("has_from", true)
	mat_d.set_shader_parameter("progress", 0.5)
	mat_d.set_shader_parameter("from_tex", red_anim)
	await _run("D 交叉混合中点 progress=0.5", blue_anim, mat_d)

	get_tree().quit(0)


func _anim(frame: int) -> AnimatedTexture:
	var t := AnimatedTexture.new()
	t.frames = 3
	t.speed_scale = 1.0
	for i in 3:
		t.set_frame_texture(i, load(DIR + "seq_%d.png" % i))
		t.set_frame_duration(i, 10.0)   # 很长，保证不会自己跑掉
	t.current_frame = frame
	t.pause = true                      # 钉死在这一帧，避免测量期间漂移
	return t


func _run(label: String, tex: Texture2D, mat: ShaderMaterial) -> void:
	var rect := TextureRect.new()
	rect.texture = tex
	rect.size = Vector2(128, 128)
	rect.position = Vector2.ZERO
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = mat
	_layer.add_child(rect)
	await _wait(0.3)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)
	var p := Vector2i(int(SAMPLE.x * vp.x), int(SAMPLE.y * vp.y))
	var c := img.get_pixel(clampi(p.x, 0, img.get_width() - 1),
		clampi(p.y, 0, img.get_height() - 1))
	print("  %-34s 渲染 = (%.2f, %.2f, %.2f)" % [label, c.r, c.g, c.b])
	_layer.remove_child(rect)
	rect.queue_free()
	await _wait(0.1)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
