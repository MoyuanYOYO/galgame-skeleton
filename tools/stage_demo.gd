extends Node

## 演出效果演示图（窗口模式）
##
##   "D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/stage_demo.tscn
##
## 抓四种转场的「进行到一半」的帧 + 一张多立绘压暗的帧，纵向拼成一张图。
## 转场是瞬时的，单张截图看不出动画，但抓中间帧能看出各自的图案差异。

const OUT_DIR := "user://captures"
const MAIN_SCENE := "res://scenes/main.tscn"
const TRANSITIONS := ["dissolve", "wipe", "blinds", "circle"]

var _main: Node
var _stage: Stage


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _wait(0.2)

	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(0.8)

	(_main.get("title") as TitleScreen).visible = false
	(_main.get("hud") as Control).visible = false
	(_main.get("dialogue") as DialogueBox).hide_box()

	_stage = _main.get("stage") as Stage
	var shots: Array[String] = []

	# --- 四种转场，各抓中间帧 ---
	for name in TRANSITIONS:
		_stage.set_bg("classroom", "none", 0.0)
		await _wait(0.25)
		_stage.set_bg("rooftop", name, 1.4)
		await _wait(0.62)
		shots.append(await _shot("tr_" + name))
		print("[stage] 抓取转场 %s" % name)
		await _wait(0.9)

	# --- 多立绘压暗 ---
	_stage.set_bg("classroom", "none", 0.0)
	_stage.show_char("alice", "smile", "left", "none", 0.0)
	_stage.show_char("bob", "normal", "right", "none", 0.0)
	await _wait(0.3)
	_stage.focus_speaker("alice")
	await _wait(0.5)
	shots.append(await _shot("tr_focus"))
	print("[stage] 抓取多立绘压暗")

	# --- 天气 ---
	for kind in ["snow", "rain", "sakura"]:
		_stage.hide_char("bob", "none", 0.0)
		_stage.show_char("alice", "normal", "center", "none", 0.0)
		_stage.set_weather(kind, 1.0)
		await _wait(1.4)          # 让粒子铺满屏
		shots.append(await _shot("weather_" + kind))
		print("[stage] 抓取天气 %s" % kind)
	_stage.set_weather("none")

	# --- 表情过渡（抓交叉混合的中间帧）---
	_stage.show_char("alice", "normal", "center", "none", 0.0)
	await _wait(0.3)
	_stage.set_expr("alice", "angry", 1.4)
	await _wait(0.7)
	shots.append(await _shot("expr_blend"))
	print("[stage] 抓取表情过渡中间帧")
	await _wait(1.0)

	_stitch(shots, "%s/stage_demo.png" % OUT_DIR)
	print("[stage] 完成")
	get_tree().quit(0)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(shot_name: String) -> String:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.resize(image.get_width() / 3, image.get_height() / 3, Image.INTERPOLATE_LANCZOS)
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	image.save_png(path)
	return path


func _stitch(paths: Array[String], out_path: String) -> void:
	var images: Array[Image] = []
	for p in paths:
		var img := Image.load_from_file(p)
		if img != null:
			images.append(img)
	if images.is_empty():
		push_error("[stage] 拼接失败：没有可用帧")
		return

	var gap := 6
	var width := images[0].get_width()
	var height := 0
	for img in images:
		height += img.get_height() + gap
	height -= gap

	var canvas := Image.create(width, height, false, images[0].get_format())
	canvas.fill(Color(0.05, 0.05, 0.08))
	var y := 0
	for img in images:
		canvas.blit_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i(0, y))
		y += img.get_height() + gap
	canvas.save_png(out_path)
	print("[stage] 拼接图 -> %s (%dx%d)" % [out_path, width, height])
