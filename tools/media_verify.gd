extends Node

## 视频 / 动态立绘的端到端验收（在真实 main.tscn 里跑）
##
## 三件事，都是「光看单元测试不算数」的集成风险：
##   1. video 指令真的改到 VideoLayer 的 layer（world/ui/top）
##   2. `video xxx wait=true` 撞上缺失素材时**不能把游戏卡死**
##      —— 播不出来又没人放行，调度器会永远停在等待态（黑屏不出字）
##   3. 帧序列立绘在真实 Stage 里：帧会自己走、alpha 正确混色、
##      表情交叉混合仍然能跑完
##
##   Godot --path . res://tools/media_verify.tscn

const MAIN_SCENE := "res://scenes/main.tscn"
const FIXTURE_ROOT := "res://tools/fixtures/sprites/"
const PROBE_SCRIPT := "user://__media_verify.gvs"

## 立绘 rect = (680,130) 560×1000；素材 64×64 等比放进 560×1000 →
## 画成 560×560 居中（上下各留 220），所以绘制区是 (680,350)-(1240,910)。
## 贴图左半不透明、右半 alpha=96。
const PT_OPAQUE := Vector2i(800, 400)
const PT_ALPHA := Vector2i(1150, 400)

var _main: Control


func _ready() -> void:
	await _wait(0.3)
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(0.9)
	# 标题界面启动时是可见的，它的底板会整块盖住舞台 —— 不藏掉的话
	# 下面量到的全是标题底图（踩过一次：把底图当成「立绘没渲染」）。
	(_main.get("title") as Control).visible = false
	await _wait(0.3)

	await _check_video_layer()
	await _check_video_no_deadlock()
	await _check_animated_char()

	print("[media] 完成")
	get_tree().quit(0)


# --- 1. 图层映射 -------------------------------------------------------------

func _check_video_layer() -> void:
	print("--- 1. video 指令的图层映射 ---")
	var layer := _main.get("video_layer") as CanvasLayer
	for item in [["world", 0], ["ui", 15], ["top", 40]]:
		_main.call("_on_stage_command", {
			"op": "video", "id": "不存在的过场", "layer": item[0],
			"at": "full", "fade": 0.0, "volume": 1.0, "speed": 1.0,
			"loop": false, "wait": false, "hide": true,
		})
		print("  layer=%-6s → CanvasLayer.layer = %d（期望 %d）%s"
			% [item[0], layer.layer, item[1], "" if layer.layer == item[1] else "  ✗"])


# --- 2. 缺失素材 + wait 不能卡死 ---------------------------------------------

func _check_video_no_deadlock() -> void:
	print("--- 2. video wait=true 撞上缺失素材 ---")
	var runner: ScriptRunner = _main.get("runner") as ScriptRunner

	var f := FileAccess.open(PROBE_SCRIPT, FileAccess.WRITE)
	f.store_string("label start\nvideo 不存在的过场 wait=true\nnarr 视频之后这一句\n"
		+ "ending smoke_media \"视频\"\n")
	f.close()

	_main.call("_show_title")
	runner.load_script(PROBE_SCRIPT)
	runner.start()
	await _wait(0.3)
	print("  start 后状态 = %s（若卡在 waiting_video 就是死锁）" % runner.get_state_name())
	await _wait(0.3)
	print("  0.3s 后状态 = %s，当前台词 = 「%s」"
		% [runner.get_state_name(), String(_main.get("_last_text"))])
	print("  结论：%s" % ("素材缺失时已自动放行，不会卡死"
		if not runner.is_waiting_video() else "✗ 仍然卡在等待态"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE_SCRIPT))


# --- 3. 帧序列立绘在真实 Stage 里 --------------------------------------------

func _check_animated_char() -> void:
	print("--- 3. 帧序列动态立绘（真实 Stage 渲染）---")
	# 上一步的 _show_title() 又把标题界面打开了，这里再藏一次
	(_main.get("title") as Control).visible = false
	PlaceholderAssets.sprite_root_override = FIXTURE_ROOT
	var stage: Stage = _main.get("stage") as Stage
	stage.clear()
	stage.set_bg("classroom", "none", 0.0)
	stage.show_char("alice", "breathe", "center", "none", 0.0)
	await _wait(0.4)

	var anim := stage.get_char_anim("alice")
	print("  立绘贴图 = %s" % ("AnimatedTexture（帧数 %d）" % anim.frames
		if anim != null else "不是动画 ✗"))
	if anim == null:
		PlaceholderAssets.sprite_root_override = ""
		return

	# 帧会不会自己走
	var seen := {}
	for i in 12:
		await _wait(0.06)
		await RenderingServer.frame_post_draw
		seen[_name(await _px(PT_OPAQUE))] = true
	print("  0.5s 内不透明区出现过的颜色: %s（期望出现 红/绿/蓝 三种）" % str(seen.keys()))

	# alpha 有没有生效：右半是 alpha=96，必须和背景混色，不是纯帧色
	anim.pause = true
	anim.current_frame = 0
	await _wait(0.2)
	var op := await _px(PT_OPAQUE)
	var tr := await _px(PT_ALPHA)
	print("  定格第0帧(红): 不透明区=%s（应≈纯红）  alpha区=%s（应≈红混背景，不是纯红）"
		% [_c(op), _c(tr)])

	# 表情交叉混合还能不能跑（from_tex 现在是 AnimatedTexture）
	# 注意：材质要**在 set_expr 之后**再取 —— 之前没挂过材质时它是 null。
	stage.set_expr("alice", "normal", 0.25)
	await _wait(0.05)
	var mid := stage.is_expr_transitioning("alice")
	var mat := stage.get_char_material("alice") as ShaderMaterial
	var from_tex_was_anim := mat != null \
		and mat.get_shader_parameter("from_tex") is AnimatedTexture
	await _wait(0.5)
	var done := stage.is_expr_transitioning("alice")
	print("  表情交叉混合: 进行中=%s 已结束=%s  from_tex 曾是动画贴图=%s"
		% [mid, not done, from_tex_was_anim])
	print("  结论：%s" % ("动态立绘 + 表情过渡都正常"
		if seen.size() >= 2 and not done else "✗ 有异常，见上"))

	# 存一张图，采样点对不上时直接看（探针的坐标是「算出来的」，最容易错）
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://media_anim.png")

	PlaceholderAssets.sprite_root_override = ""
	stage.clear()


# ---------------------------------------------------------------------------

func _px(pos: Vector2i) -> Color:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)
	var p := Vector2i(int(pos.x * vp.x), int(pos.y * vp.y))
	return img.get_pixel(clampi(p.x, 0, img.get_width() - 1),
		clampi(p.y, 0, img.get_height() - 1))


func _name(c: Color) -> String:
	if c.r > 0.5 and c.g < 0.5 and c.b < 0.5:
		return "红"
	if c.g > 0.5 and c.r < 0.5 and c.b < 0.5:
		return "绿"
	if c.b > 0.5 and c.r < 0.5 and c.g < 0.5:
		return "蓝"
	return "其它"


func _c(c: Color) -> String:
	return "(%.2f,%.2f,%.2f)" % [c.r, c.g, c.b]


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
