extends Node

## 两个「画面变暗」问题的端到端验收
##
##   1. 模态面板外的压暗程度：对比开面板前后同一像素的亮度
##   2. 转场中途：每个像素都该「约等于旧图」或「约等于新图」，
##      绝不该比两者都暗（那就是 * COLOR 重复叠加 modulate 的症状）
##
## 刻意**不启动剧本** —— 立绘和对话框会盖住画面、污染采样。
##
##   Godot --path . res://tools/fix_verify.tscn

const MAIN_SCENE := "res://scenes/main.tscn"
const BG_OLD := "res://assets/bg/classroom.png"
const BG_NEW := "res://assets/bg/rooftop.png"
## 设置面板占 460..-460 × 170..-170，这些点都在面板之外
const OUTSIDE_PTS: Array[Vector2i] = [
	Vector2i(70, 70), Vector2i(1850, 70), Vector2i(70, 1010),
	Vector2i(1850, 1010), Vector2i(960, 50),
]

var _main: Control


func _ready() -> void:
	await _wait(0.3)
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(1.0)

	# 标题界面启动时是可见的，它的底板会整块盖住舞台 —— 不藏掉的话
	# 下面两个检查量到的全是标题底板（表现为四种转场量出同一组数）。
	(_main.get("title") as Control).visible = false
	await _wait(0.3)

	await _check_panel_scrim()
	await _check_transitions()

	print("[verify] 完成")
	get_tree().quit(0)


# --- 1. 面板压暗 -------------------------------------------------------------

func _check_panel_scrim() -> void:
	var stage: Stage = _main.get("stage") as Stage
	stage.set_bg("classroom", "none", 0.0)
	await _wait(0.4)

	var before := await _sample(OUTSIDE_PTS)
	_main.call("_open_settings")
	await _wait(0.5)
	var after := await _sample(OUTSIDE_PTS)
	await _save("v_settings_open.png")
	_main.call("_close_modals")
	await _wait(0.4)

	print("[verify] 设置面板外：%.3f → %.3f（保留 %.0f%%）"
		% [_avg(before), _avg(after), _avg(after) / maxf(_avg(before), 0.001) * 100.0])


# --- 2. 转场 ----------------------------------------------------------------

func _check_transitions() -> void:
	var stage: Stage = _main.get("stage") as Stage
	var old_img := (load(BG_OLD) as Texture2D).get_image()
	var new_img := (load(BG_NEW) as Texture2D).get_image()
	old_img.convert(Image.FORMAT_RGBA8)
	new_img.convert(Image.FORMAT_RGBA8)

	for t in ["dissolve", "wipe", "blinds", "circle"]:
		stage.set_bg("classroom", "none", 0.0)
		await _wait(0.35)
		stage.set_bg("rooftop", t, 2.4)
		await _wait(1.0)
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)
		var acc := 0.0
		var worst := 1.0
		var n := 0
		for y in range(60, 1010, 40):
			for x in range(60, 1870, 40):
				var got := _lum(img, x, y, vp)
				var lo := _lum(old_img, x, y, vp)
				var ln := _lum(new_img, x, y, vp)
				# 取「更像哪张原图」，用它当基准
				var ref := lo if absf(got - lo) < absf(got - ln) else ln
				if ref < 0.12:
					continue
				var r := got / ref
				acc += r
				worst = minf(worst, r)
				n += 1
		print("[verify] 转场 %-9s 渲染/原图 = %.3f  最暗 %.3f（应≈1.00，n=%d）"
			% [t, acc / maxf(1.0, float(n)), worst, n])
		await _save("v_trans_%s.png" % t)
		await _wait(0.1)


# --- 工具 -------------------------------------------------------------------

func _sample(pts: Array[Vector2i]) -> Array:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)
	var out: Array = []
	for p in pts:
		out.append(_lum(img, p.x, p.y, vp))
	return out


func _lum(img: Image, x: float, y: float, vp: Vector2) -> float:
	var p := Vector2i(int(x * vp.x), int(y * vp.y))
	p.x = clampi(p.x, 0, img.get_width() - 1)
	p.y = clampi(p.y, 0, img.get_height() - 1)
	var c := img.get_pixel(p.x, p.y)
	return c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722


func _avg(arr: Array) -> float:
	var s := 0.0
	for v in arr:
		s += float(v)
	return s / maxf(1.0, float(arr.size()))


func _save(fname: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://" + fname)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
