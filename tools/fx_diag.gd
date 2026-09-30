extends Node

## 诊断：震动 / 闪烁到底有没有生效、幅度够不够

const OUT_DIR := "user://captures"
const MAIN_SCENE := "res://scenes/main.tscn"

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

	_stage = _main.get("stage") as Stage
	_stage.set_bg("classroom", "none", 0.0)
	_stage.show_char("alice", "normal", "center", "none", 0.0)
	# 让对话框显示出来 —— 全屏震动时它会跟着抖，这才看得出效果
	var dialogue: DialogueBox = _main.get("dialogue") as DialogueBox
	dialogue.show_line("诊断", "全屏震动时，这个对话框也会跟着抖。")
	dialogue.complete_typing()
	await _wait(0.4)

	var shots: Array[String] = []
	shots.append(await _shot("diag_0_idle"))

	# --- 画面震动（含 UI 层）---
	var strength := 48.0
	var times := 6
	var duration := 0.6
	print("=== screen_shake(%.0f, %d, %.1f) + UI ===" % [strength, times, duration])
	_stage.screen_shake(strength, times, duration)
	_main.call("_shake_ui", strength, times, duration)

	var ui_layer := _main.get("ui_layer") as CanvasLayer
	var peak := 0.0
	var peak_ui := 0.0
	var peak_shot := ""
	for i in 16:
		await _wait(0.04)
		var off := _stage.get_world_offset()
		var ui_off := ui_layer.offset
		if off.length() + ui_off.length() > peak + peak_ui:
			peak = off.length()
			peak_ui = ui_off.length()
			peak_shot = await _shot("diag_1_shake")
	print("  舞台峰值 = %.1f px（画布宽占比 %.2f%%）"
		% [peak, peak / 1920.0 * 100.0])
	print("  UI   峰值 = %.1f px（画布宽占比 %.2f%%）"
		% [peak_ui, peak_ui / 1920.0 * 100.0])
	if not peak_shot.is_empty():
		shots.append(peak_shot)
	await _wait(0.8)

	# --- 立绘震动 ---
	print("=== char_shake(alice, 40, 6, 0.6) ===")
	var base := _stage.get_char_position("alice")
	_stage.char_shake("alice", 40.0, 6, 0.6)
	var peak_char := 0.0
	for i in 16:
		await _wait(0.04)
		var d := (_stage.get_char_position("alice") - base).length()
		peak_char = maxf(peak_char, d)
	print("  峰值位移 = %.1f px（立绘宽占比 %.2f%%）"
		% [peak_char, peak_char / 560.0 * 100.0])
	await _shot("diag_2_char_shake")
	await _wait(0.7)

	# --- 闪光 ---
	print("=== screen_flash(#ffffff, 0.3) ===")
	_stage.screen_flash(Color.WHITE, 0.3)
	await _wait(0.03)
	print("  刚触发时 alpha = %.2f" % _stage.get_flash_alpha())
	await _shot("diag_3_flash")
	for i in 5:
		await _wait(0.08)
		print("  t=%.2f  alpha=%.2f" % [(i + 1) * 0.08, _stage.get_flash_alpha()])

	print("[diag] 完成")
	_stitch(shots, "%s/fx_diag_compare.png" % OUT_DIR)
	get_tree().quit(0)


## 把「静止」与「震动中」纵向拼起来 —— 单张静态图看不出位移，并排才行
func _stitch(paths: Array[String], out_path: String) -> void:
	var images: Array[Image] = []
	for p in paths:
		var img := Image.load_from_file(p)
		if img != null:
			images.append(img)
	if images.size() < 2:
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
	print("[diag] 对比图 -> %s (%dx%d)" % [out_path, width, height])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(shot_name: String) -> String:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.resize(image.get_width() / 2, image.get_height() / 2, Image.INTERPOLATE_LANCZOS)
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	image.save_png(path)
	print("[diag] 截图 %s" % shot_name)
	return path
