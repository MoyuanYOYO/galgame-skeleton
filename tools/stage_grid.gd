extends Node

## 立绘坐标网格预览（需要非 headless 运行）
##
## 用法：
##   "D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/stage_grid.tscn
##
## 调立绘的 x= / y= / scale= 时，先看这张图再改剧本 —— 图上有 100px 网格、
## 坐标刻度、预设锚点线、画布底线，以及每个样本立绘的实际框（框会跟着 scale 变）。
## 跑完还会把实测坐标打到控制台，方便和剧本里写的值对账。
##
## 输出：%APPDATA%/Godot/app_userdata/Galgame Skeleton/captures/stage_grid.png

const OUT_DIR := "user://captures"
const MAIN_SCENE := "res://scenes/main.tscn"

const GRID_STEP := 100
const LABEL_STEP := 200
## 与 Stage 保持一致：立绘框 560×1000，默认脚底在 1080 + OVERHANG(50)
const CHAR_W := 560.0
const CHAR_H := 1000.0
const FEET_Y := 1130.0
## 预设锚点（框中心 X）——对应 Stage.POSITION_RATIOS 的 left / center / right
const ANCHORS := {"left": 422.0, "center": 960.0, "right": 1498.0}

## 样本：只用仓库里真有的立绘（alice / bob），免得给不存在的 id 画占位剪影
const SAMPLES := [
	{"id": "bob", "expr": "normal", "opts": {"x": 400.0, "y": FEET_Y, "scale": 0.8}},
	{"id": "alice", "expr": "smile", "opts": {"x": 1300.0, "y": 1080.0, "scale": 1.05}},
]

var _main: Node
var _stage: Stage
var _overlay: GridOverlay


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
	_stage.set_bg("classroom", "none", 0.0)
	await _wait(0.3)

	_overlay = _add_overlay()

	for s in SAMPLES:
		_stage.show_char(String(s["id"]), String(s["expr"]), "center", "none", 0.0,
			s["opts"] as Dictionary)
	await _wait(0.5)

	_overlay.set_boxes(_collect_boxes())
	_report()
	await _shot("stage_grid")
	print("[grid] 完成 —— 图在 %s/stage_grid.png" % OUT_DIR)
	get_tree().quit(0)


## 每个样本立绘的实际外框（跟着 scale 变）。
## 缩放 pivot 在脚底中心，所以底边中点固定，左右两边随 scale 收放。
func _collect_boxes() -> Array:
	var out: Array = []
	for s in SAMPLES:
		var id := String(s["id"])
		var pos := _stage.get_char_position(id)
		if pos.x < 0.0:
			continue
		var sc := _stage.get_char_scale(id)
		var center_x := pos.x + CHAR_W * 0.5
		var feet_y := pos.y + CHAR_H
		out.append({
			"rect": Rect2(center_x - CHAR_W * 0.5 * sc, feet_y - CHAR_H * sc,
				CHAR_W * sc, CHAR_H * sc),
			"label": "%s  scale=%.2f" % [id, sc],
		})
	return out


## 把样本的实测坐标打出来。剧本里写的 x/y 与这里的「中心X / 脚底Y」是同一
## 口径 —— 对不上就说明参数没被认出来。
func _report() -> void:
	print("[grid] 立绘实测（设计像素，锚点 = 框中心 X / 脚底 Y）：")
	for s in SAMPLES:
		var id := String(s["id"])
		var pos := _stage.get_char_position(id)
		if pos.x < 0.0:
			print("   %-6s 不在场上" % id)
			continue
		print("   %-6s 中心X=%.0f  脚底Y=%.0f  scale=%.2f" % [
			id, pos.x + CHAR_W * 0.5, pos.y + CHAR_H, _stage.get_char_scale(id)])


func _add_overlay() -> GridOverlay:
	var layer := CanvasLayer.new()
	layer.name = "GridLayer"
	# 排在 UI 之上（UILayer 是 10），网格盖住一切、方便对齐
	layer.layer = 100
	add_child(layer)

	var overlay := GridOverlay.new()
	overlay.name = "GridOverlay"
	# Control 直接挂 CanvasLayer 下拿不到父级尺寸，用 TOP_LEFT + offset 定矩形
	overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
	overlay.offset_left = 0.0
	overlay.offset_top = 0.0
	overlay.offset_right = 1920.0
	overlay.offset_bottom = 1080.0
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(overlay)
	return overlay


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	image.save_png(path)
	print("[grid] 截图 -> %s (%dx%d)" % [path, image.get_width(), image.get_height()])


## 网格覆盖层。全部用 _draw 画 —— 不落任何节点，也就不会污染场景。
class GridOverlay extends Control:
	var font: Font
	var boxes: Array = []
	var legend: PackedStringArray = PackedStringArray([
		"立绘框 560×1000 · pivot 在脚底中心",
		"x = 框中心 X    y = 脚底 Y    scale = 基准缩放",
		"预设锚点 left 422 / center 960 / right 1498",
		"脚底默认 y=1130（画布底 1080 再往下 50，故不在画面里）",
		"y 调小 = 人往上站（显高、显远）",
	])

	func _ready() -> void:
		font = ThemeDB.fallback_font

	func set_boxes(list: Array) -> void:
		boxes = list
		queue_redraw()

	func _draw() -> void:
		var grid := Color(0.45, 0.85, 1.0, 0.16)
		var grid_major := Color(0.45, 0.85, 1.0, 0.30)

		# 细网格（100）与主网格（500）
		var x := 0
		while x <= 1920:
			draw_line(Vector2(x, 0), Vector2(x, 1080), grid_major if x % 500 == 0 else grid)
			x += GRID_STEP
		var y := 0
		while y <= 1080:
			draw_line(Vector2(0, y), Vector2(1920, y), grid_major if y % 500 == 0 else grid)
			y += GRID_STEP

		# 坐标刻度：横向沿顶部、纵向沿左侧
		var label_col := Color(0.78, 0.93, 1.0, 0.9)
		var n := 0
		while n <= 1920:
			draw_string(font, Vector2(n + 4.0, 22.0), str(n),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 18, label_col)
			n += LABEL_STEP
		n = LABEL_STEP
		while n <= 1080:
			draw_string(font, Vector2(6.0, n - 4.0), str(n),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 18, label_col)
			n += LABEL_STEP

		# 预设锚点线（框中心 X），虚线
		for key in ANCHORS.keys():
			var ax := float(ANCHORS[key])
			var col := Color(0.55, 1.0, 0.7, 0.8) if key == "center" \
				else Color(0.95, 0.55, 0.85, 0.7)
			var dash := 0.0
			while dash < 1080.0:
				draw_line(Vector2(ax, dash), Vector2(ax, dash + 18.0), col, 2.0)
				dash += 36.0

		# 画布底线
		draw_line(Vector2(0, 1080), Vector2(1920, 1080), Color(1, 1, 1, 0.6), 2.0)

		# 样本的缩放后外框
		for b in boxes:
			var d: Dictionary = b
			var rect: Rect2 = d["rect"]
			draw_rect(rect, Color(1.0, 0.85, 0.4, 0.75), false, 2.0)
			# 标签夹在画布内 —— 放大抬高的立绘框顶会跑到 y<0，直接写会看不见
			var label_y := clampf(rect.position.y + 24.0, 26.0, 1050.0)
			draw_string(font, Vector2(rect.position.x + 6.0, label_y),
				String(d["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 20,
				Color(1.0, 0.85, 0.4, 0.95))

		_draw_legend()

	## 图例：加一层半透明底，否则网格线会把文字割碎、读不清
	func _draw_legend() -> void:
		var pad := 10.0
		var line_h := 26.0
		var box_w := 720.0
		var box_h := line_h * float(legend.size()) + pad * 2.0
		var origin := Vector2(14.0, 34.0)
		draw_rect(Rect2(origin, Vector2(box_w, box_h)), Color(0.04, 0.05, 0.09, 0.78))
		var ly := origin.y + pad + 18.0
		for line in legend:
			draw_string(font, Vector2(origin.x + pad, ly), line,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 19, Color(0.96, 0.97, 1.0, 0.95))
			ly += line_h
