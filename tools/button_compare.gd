extends Node

## 按钮样式前后对比工具（窗口模式运行）
##
##   "D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/button_compare.tscn
##
## 在同一个进程里把标题界面渲染两次 —— 一次用程序化样式、一次用九宫格贴图 ——
## 然后把两张图纵向拼成一张对比图。这样不依赖「改配置 → 重启 → 再截图」的慢回路。

const OUT_DIR := "user://captures"
const MAIN_SCENE := "res://scenes/main.tscn"

var _main: Node
var _vbox: VBoxContainer


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _wait(0.2)

	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(0.8)

	# 直接停在标题界面，并确保「继续游戏 / 读取存档」可用（否则会置灰影响观感）
	var title: TitleScreen = _main.get("title") as TitleScreen
	title.set_save_available(true)
	_vbox = _main.get_node("%TitleScreen/Center/VBox") as VBoxContainer

	var preset: Dictionary = UiTheme.section("buttons").get("title", {})
	var saved := preset.duplicate(true)

	# --- 第一张：还原成「纯程序化」样式 —— 贴图和自定义文字颜色都要清掉，
	#     否则紫底上会留着金色按钮的深棕字，对比就不忠实了 ---
	preset["texture"] = ""
	preset["texture_hover"] = ""
	preset["texture_pressed"] = ""
	preset["texture_disabled"] = ""
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color"]:
		preset.erase(key)
	_reapply()
	await _wait(0.5)
	var before_path := await _shot("compare_before")

	# --- 第二张：恢复真实配置 ---
	for key in saved.keys():
		preset[key] = saved[key]
	_reapply()
	await _wait(0.5)
	var after_path := await _shot("compare_after")

	# --- 纵向拼接 ---
	_stitch(before_path, after_path, "%s/button_compare.png" % OUT_DIR)
	print("[compare] 完成")
	get_tree().quit(0)


func _reapply() -> void:
	for child in _vbox.get_children():
		if child is Button:
			UiTheme.apply_button(child as Button, "title")


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(shot_name: String) -> String:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	image.save_png(path)
	print("[compare] %s -> %s" % [shot_name, path])
	return path


func _stitch(top_path: String, bottom_path: String, out_path: String) -> void:
	var top := Image.load_from_file(top_path)
	var bottom := Image.load_from_file(bottom_path)
	if top == null or bottom == null:
		push_error("[compare] 拼接失败：读不到截图")
		return
	var gap := 8
	var width := maxi(top.get_width(), bottom.get_width())
	var height := top.get_height() + gap + bottom.get_height()
	var canvas := Image.create(width, height, false, top.get_format())
	canvas.fill(Color(0.05, 0.05, 0.08))
	canvas.blit_rect(top, Rect2i(0, 0, top.get_width(), top.get_height()), Vector2i(0, 0))
	canvas.blit_rect(bottom, Rect2i(0, 0, bottom.get_width(), bottom.get_height()),
		Vector2i(0, top.get_height() + gap))
	canvas.save_png(out_path)
	print("[compare] 拼接图 -> %s (%dx%d)" % [out_path, width, height])
