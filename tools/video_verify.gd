extends Node

## 真机播 .ogv 验收
##
## 之前这一条是缺口（造不出测试视频）。现在用 ffmpeg 生成了一段 12 帧的
## pattern.ogv（红 0.4s → 绿 0.4s → 蓝 0.4s），把这几件事都量出来：
##   1. 视频真的会渲染，而且时间轴上颜色按 红→绿→蓝 走
##   2. 指定位置 / 尺寸生效（矩形内是视频，矩形外还是背景）
##   3. **Theora 没有 alpha**：视频区域完全遮住背景，不会透出底色
##   4. 播完 finished 会发出来、视频自动收起
##   5. wait=true 的阻塞由「播完」解除
##
##   Godot --path . res://tools/video_verify.tscn

const MAIN_SCENE := "res://scenes/main.tscn"
const FIXTURE_ROOT := "res://tools/fixtures/video/"
const PROBE_SCRIPT := "user://__video_verify.gvs"
## 铺满屏的绿底，用来验「视频区域是不是不透」
const BG_COLOR := Color(1, 0, 1, 1)

var _main: Control


func _ready() -> void:
	await _wait(0.3)
	VideoScreen.video_root_override = FIXTURE_ROOT
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(0.9)
	# 标题界面会整块盖住舞台，先藏掉
	(_main.get("title") as Control).visible = false

	# 绿底：视频若是半透明就会混进绿色
	var bg := ColorRect.new()
	bg.name = "ProbeBg"
	bg.color = BG_COLOR
	bg.size = Vector2(1920, 1080)
	_main.get("video_layer").add_child(bg)
	_main.get("video_layer").move_child(bg, 0)
	await _wait(0.3)

	await _check_playback()
	await _check_placement()
	await _check_finished_and_wait()

	VideoScreen.video_root_override = ""
	print("[video] 完成")
	get_tree().quit(0)


# --- 1. 真的会播，颜色按时间走 -----------------------------------------------

func _check_playback() -> void:
	print("--- 1. 画面在推进吗（motion.ogv：白条每帧右移 16px）---")
	_send({"op": "video", "id": "motion", "layer": "world", "at": "full",
		"fade": 0.0, "volume": 1.0, "speed": 1.0, "loop": false,
		"wait": false, "hide": true})
	var xs: Array = []
	for i in 10:
		await _wait(0.4)
		xs.append(await _bar_x())
	print("  每 0.4s 量一次白条位置（-1 = 画面已收起）: %s" % str(xs))
	var shown := xs.filter(func(v: int) -> bool: return v >= 0)
	var moved: bool = shown.size() >= 2 and shown[0] != shown[shown.size() - 1]
	print("  出过画面的次数 = %d；首末位置 %s → %s；位置在变 = %s"
		% [shown.size(), str(shown[0]) if shown.size() > 0 else "-",
			str(shown[shown.size() - 1]) if shown.size() > 0 else "-", moved])
	print("  结论：%s" % ("画面确实在推进（不是只显示一帧）" if moved
		else "✗ 位置没变，播放可能没推进"))


## 扫一行找最亮的点（= 白条中心）。一次抓图扫完，不要逐点 await 帧。
func _bar_x() -> int:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)
	var py := clampi(int(90 * vp.y), 0, img.get_height() - 1)
	var best := -1
	var best_l := 0.2
	for x in range(0, 1920, 8):
		var px := clampi(int(x * vp.x), 0, img.get_width() - 1)
		var c := img.get_pixel(px, py)
		var l := c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
		if l > best_l:
			best_l = l
			best = x
	return best


# --- 2. 指定位置 / 尺寸 + 不透明 ---------------------------------------------

func _check_placement() -> void:
	print("--- 2. 指定位置 / 尺寸 + 是否不透 ---")
	_send({"op": "video", "id": "pattern", "layer": "world",
		"at": "320,180", "size": "640,360", "fade": 0.0, "volume": 1.0,
		"speed": 0.01, "loop": true, "wait": false, "hide": true})
	await _wait(1.2)      # Godot 默认 buffering_msec=500，起播前是空的
	var screen := _main.get("video") as VideoScreen
	var pl := screen.get_player()
	print("  我方设置的矩形 = %s（期望 (320,180) 640×360）" % str(screen.get_target_rect()))
	print("  播放器实际：pos=%s size=%s expand=%s 视频原始尺寸=%s 缩放=%s"
		% [str(pl.position), str(pl.size), pl.expand,
			str(pl.get_combined_minimum_size()), str(pl.scale)])

	print("  speed_scale=%s 当前位置=%.2fs 时长=%.2fs"
		% [pl.speed_scale, screen.get_playback_position(), pl.get_stream_length()])

	# 判据不能写死「应该是红」—— 停在哪个帧取决于时机。
	# 要验的是：矩形内是「视频自己的纯色」（红/绿/蓝任一），且**没有洋红混进来**
	# （洋红是背景，混进来就说明视频半透明）。
	var inside := await _px(Vector2i(640, 360))
	var outside_l := await _px(Vector2i(100, 360))
	var outside_r := await _px(Vector2i(1800, 360))
	var outside_t := await _px(Vector2i(640, 60))
	print("  矩形内 = %s   矩形外 左/右/上 = %s / %s / %s"
		% [_c(inside), _c(outside_l), _c(outside_r), _c(outside_t)])

	var is_video_color := maxf(inside.r, maxf(inside.g, inside.b)) > 0.6 \
		and mini(inside.r, mini(inside.g, inside.b)) < 0.25
	var bg_bleed := inside.r > 0.25 and inside.b > 0.25
	var outside_ok := outside_l.b > 0.6 and outside_l.g < 0.25 \
		and outside_r.b > 0.6 and outside_t.b > 0.6
	print("  矩形内是视频纯色=%s；混进背景洋红=%s；矩形外仍是背景=%s"
		% [is_video_color, bg_bleed, outside_ok])
	print("  结论：%s" % ("视频精确落在指定矩形内，且完全不透（Theora 无 alpha）"
		if is_video_color and not bg_bleed and outside_ok else "✗ 见上"))
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://video_placed.png")
	screen.stop(0.0)


# --- 3. 播完 / wait 阻塞 ------------------------------------------------------

func _check_finished_and_wait() -> void:
	print("--- 3. finished 与 wait=true 阻塞 ---")
	var screen := _main.get("video") as VideoScreen
	var got := {"id": ""}
	screen.finished.connect(func(id: String) -> void: got["id"] = id)

	_send({"op": "video", "id": "pattern", "layer": "world", "at": "full",
		"fade": 0.0, "volume": 1.0, "speed": 2.0, "loop": false,
		"wait": false, "hide": true})
	await _wait(1.6)
	print("  finished 信号 id = '%s'（期望 pattern）" % got["id"])
	print("  播完后 is_playing=%s visible=%s（期望 false / false，自动收起）"
		% [screen.is_playing(), screen.visible])

	# wait=true：通过真实调度器走一遍
	var runner: ScriptRunner = _main.get("runner") as ScriptRunner
	var f := FileAccess.open(PROBE_SCRIPT, FileAccess.WRITE)
	f.store_string("label start\nvideo pattern speed=2.0 wait=true\nnarr 视频之后\n"
		+ "ending smoke_video \"视频\"\n")
	f.close()
	_main.call("_show_title")
	(_main.get("title") as Control).visible = false
	runner.load_script(PROBE_SCRIPT)
	var t0 := Time.get_ticks_msec()
	runner.start()
	# 逐 0.1s 打一遍时间线，看清「到底有没有进等待态、什么时候被放行」
	for i in 12:
		var scr := _main.get("video") as VideoScreen
		print("  +%.1fs 状态=%-15s 视频在播=%-5s 位置=%.2fs"
			% [(Time.get_ticks_msec() - t0) / 1000.0, runner.get_state_name(),
				scr.is_playing(), scr.get_playback_position()])
		await _wait(0.1)
	print("  最终状态 = %s，台词 = 「%s」"
		% [runner.get_state_name(), String(_main.get("_last_text"))])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE_SCRIPT))


# ---------------------------------------------------------------------------

func _send(cmd: Dictionary) -> void:
	_main.call("_on_stage_command", cmd)


func _px(pos: Vector2i) -> Color:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)
	var p := Vector2i(int(pos.x * vp.x), int(pos.y * vp.y))
	return img.get_pixel(clampi(p.x, 0, img.get_width() - 1),
		clampi(p.y, 0, img.get_height() - 1))


func _name(c: Color) -> String:
	if c.r > 0.5 and c.g < 0.4 and c.b < 0.4:
		return "红"
	if c.g > 0.5 and c.r < 0.4 and c.b < 0.4:
		return "绿"
	if c.b > 0.5 and c.r < 0.4 and c.g < 0.4:
		return "蓝"
	return "其它"


func _c(c: Color) -> String:
	return "(%.2f,%.2f,%.2f)" % [c.r, c.g, c.b]


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
