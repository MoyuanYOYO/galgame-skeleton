extends Node

## 文字特效演示图（窗口模式）
##
##   "D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/text_fx_demo.tscn
##
## 把同一句带特效的台词按时间抓 4 帧，裁到对话框区域后纵向拼成一张长图。
## 单张静态图看不出动画，多帧才能证明特效真的在动。

const OUT_DIR := "user://captures"
const MAIN_SCENE := "res://scenes/main.tscn"

const DEMO_LINE := "[bounce height=16]弹跳[/bounce]  [blink]闪烁[/blink]  [glitch strength=7]错乱[/glitch]  [rainbow]变色[/rainbow]  [wave]波浪[/wave]"

var _main: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _wait(0.2)

	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(0.8)

	# 直接驱动对话框，不跑剧本 —— 只为把这一句摆到屏幕上
	(_main.get("title") as TitleScreen).visible = false
	(_main.get("hud") as Control).visible = false

	var dialogue: DialogueBox = _main.get("dialogue") as DialogueBox
	dialogue.show_line("特效演示", DEMO_LINE)
	dialogue.complete_typing()          # 全部显示出来，只看动画
	await _wait(0.4)

	# 对话框在设计分辨率下大约 y 760~1010，窗口 1280x720 时对应 507~673
	var crop := Rect2i(60, 490, 1160, 200)
	var frames: Array[String] = []
	for i in 4:
		frames.append(await _shot_cropped("fx_frame_%d" % i, crop))
		await _wait(0.22)

	_stitch(frames, "%s/text_fx_demo.png" % OUT_DIR)
	print("[fx] 完成")
	get_tree().quit(0)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot_cropped(shot_name: String, rect: Rect2i) -> String:
	await RenderingServer.frame_post_draw
	var full := get_viewport().get_texture().get_image()
	var cropped := full.get_region(rect)
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	cropped.save_png(path)
	print("[fx] %s -> %s" % [shot_name, path])
	return path


func _stitch(paths: Array[String], out_path: String) -> void:
	var images: Array[Image] = []
	for p in paths:
		var img := Image.load_from_file(p)
		if img != null:
			images.append(img)
	if images.is_empty():
		push_error("[fx] 拼接失败：没有可用帧")
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
	print("[fx] 拼接图 -> %s (%dx%d)" % [out_path, width, height])
