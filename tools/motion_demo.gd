extends Node

## 立绘动效演示图（窗口模式）
##
##   "D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/motion_demo.tscn
##
## 在「带缓动的位移」过程中等间隔抓 4 帧。如果位移是匀速的，四帧里立绘的
## 间距会一样；用 in_cubic 就会看到「起步慢、越走越快」——间距逐帧拉大。
## 静态图看不出动画，但帧间距能证明缓动真的生效了。

const OUT_DIR := "user://captures"
const MAIN_SCENE := "res://scenes/main.tscn"
const FRAMES := 4
const STEP_SECONDS := 0.22

var _main: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _wait(0.2)

	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(0.8)

	(_main.get("title") as TitleScreen).visible = false
	(_main.get("hud") as Control).visible = false
	var dialogue: DialogueBox = _main.get("dialogue") as DialogueBox
	dialogue.hide_box()

	var stage_node: Stage = _main.get("stage") as Stage
	stage_node.set_bg("classroom", "none", 0.0)
	stage_node.show_char("alice", "normal", "left", "none", 0.0)
	await _wait(0.3)

	# in_cubic = 起步慢、后段加速，最能体现「不是匀速平移」
	stage_node.move_char("alice", "right", 1.0, "in_cubic")

	var frames: Array[String] = []
	for i in FRAMES:
		await _wait(STEP_SECONDS)
		frames.append(await _shot("motion_%d" % i))

	_stitch(frames, "%s/motion_demo.png" % OUT_DIR)
	print("[motion] 完成")
	get_tree().quit(0)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(shot_name: String) -> String:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	# 缩到一半宽，四帧拼起来才不至于太长
	image.resize(image.get_width() / 2, image.get_height() / 2, Image.INTERPOLATE_LANCZOS)
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	image.save_png(path)
	print("[motion] %s -> %s" % [shot_name, path])
	return path


func _stitch(paths: Array[String], out_path: String) -> void:
	var images: Array[Image] = []
	for p in paths:
		var img := Image.load_from_file(p)
		if img != null:
			images.append(img)
	if images.is_empty():
		push_error("[motion] 拼接失败：没有可用帧")
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
	print("[motion] 拼接图 -> %s (%dx%d)" % [out_path, width, height])
