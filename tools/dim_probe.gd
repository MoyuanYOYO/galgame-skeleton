extends Node

## 终极探针：每行等 0.45s（渐变走完）后核对三件事：
##   1. 名字牌 speaker 与 modulate 一致性（说话人不该被压暗）
##   2. alice 材质的 shader 参数（progress/has_from）—— 抓卡住的交叉混合
##   3. 渲染色 vs「此刻该有的压暗」—— 既抓「该亮却被压暗」，也抓「该暗却没暗」
##      （后者 = 材质丢掉了 modulate，即「换过表情后再也不变暗」）
##   Godot --path . res://tools/dim_probe.tscn

const MAIN_SCENE := "res://scenes/main.tscn"

func _ready() -> void:
	await _wait(0.3)
	var main := (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(main)
	await _wait(0.6)
	main.call("_on_start_requested")
	await _wait(1.2)

	var runner: ScriptRunner = main.get("runner") as ScriptRunner
	var stage: Stage = main.get("stage") as Stage
	var last_text := ""
	var checked := 0
	var guard := 4000
	while guard > 0:
		guard -= 1
		if runner.is_waiting_choice():
			(main.get("choices") as ChoicePanel).call("_on_pressed", 0)
			await _wait(0.4)
			last_text = ""
			continue
		if runner.is_waiting_minigame():
			runner.call("submit_minigame", {"success": true, "score": 100, "max": 100})
			await _wait(0.4)
			last_text = ""
			continue
		main.call("_on_advance_requested")
		await _wait(0.03)
		var text := String(main.get("_last_text"))
		if text == last_text or text.is_empty():
			continue
		last_text = text
		if not runner.is_waiting_say():
			continue
		await _wait(0.45)  # 等压暗/表情渐变全部走完再量
		checked += 1
		var speaker := String(main.get("_last_speaker"))
		var a: float = stage.get_char_brightness("alice")
		var issues: Array = []
		# 1. 一致性
		if speaker == "alice" and a < 0.95:
			issues.append("alice是说话人但亮度%.2f" % a)
		elif speaker == "bob" and stage.get_char_brightness("bob") < 0.95:
			issues.append("bob是说话人但亮度%.2f" % stage.get_char_brightness("bob"))
		elif speaker.is_empty():
			if stage.is_char_visible("alice") and a < 0.95:
				issues.append("旁白但alice亮度%.2f" % a)
		# 2. shader 状态（材质挂上后才有）
		var mat := _alice_material(stage)
		if mat != null:
			var prog: float = mat.get_shader_parameter("progress")
			var has_from: bool = mat.get_shader_parameter("has_from")
			if has_from and prog < 0.99:
				issues.append("交叉混合卡住 progress=%.2f has_from=%s" % [prog, has_from])
		# 3. 渲染色必须等于「此刻该有的压暗」。同时抓两类，缺一不可：
		#    · 该亮却被压暗  —— 系统变暗，或材质把顶点色叠了两遍（恒暗 ~40%）
		#    · 该暗却没暗    —— 材质把 modulate 整个丢掉
		#    第二类正是「女主换过表情后，男主说话时她不变暗」那个 bug。
		#    只查说话人那一侧（旧的写法）永远抓不到它。
		#    CG 在屏（含淡出中）时跳过 —— 那时采到的是 CG 的像素，不是立绘。
		if stage.is_char_visible("alice") and not stage.is_cg_rendering():
			var expected := 1.0
			if not speaker.is_empty() and speaker != "alice":
				expected = UiTheme.stage_value("dim_inactive", 0.55)
			var ratio := await _fidelity_ratio(stage)
			if absf(ratio - expected) > 0.12:
				issues.append("alice 渲染色 x%.2f（期望 %.2f）" % [ratio, expected])
		# 4. alice 说话的每行都存全屏图 —— x 值有 zoom/COVERED 等干扰，
		#    最终以肉眼截图为准
		if speaker == "alice":
			await _shot("alice_%d.png" % checked)
		if not issues.is_empty():
			await _shot("bad_%d.png" % checked)
			print("[probe] 第%d行 异常: %s | speaker='%s' alice=%.2f | 台词: %s"
				% [checked, "；".join(issues), speaker, a, text.left(20)])
		else:
			print("[probe] 第%d行 ok | speaker='%s' alice=%.2f | %s"
				% [checked, speaker, a, text.left(20)])
		if runner.is_ended():
			break
	print("[probe] 完成，共核对 %d 行" % checked)
	get_tree().quit(0)


func _alice_material(stage: Stage) -> ShaderMaterial:
	return stage.get_char_material("alice") as ShaderMaterial


## sprite 渲染色 vs 素材文件的总体比值（立绘不透明区的中位亮度比）。
##
## 三个容易量成假信号的地方，这里都处理了：
##   · 映射模型必须和节点上的 stretch_mode 用同一个 —— 立绘是
##     STRETCH_KEEP_ASPECT_CENTERED（等比装进 560×1000、两边留白居中），
##     不是 COVERED 的填满裁切（按 COVERED 算会把比值量成 1.3+）；
##   · 立绘可能被 zoom 放大过，采样矩形要跟着 pivot（脚底中心）一起缩放，
##     否则放大的立绘会被量成「假变亮」；
##   · 基准图取节点当前真正在用的那张（含表情差分），不要固定 normal.png ——
##     换过表情的行会因两张图内容差异量出 1.5 的假偏移。
func _fidelity_ratio(stage: Stage) -> float:
	var pos: Vector2 = stage.get_char_position("alice")
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)

	var spr: Texture2D = stage.get_char_texture("alice")
	if spr == null:
		return 1.0
	var spr_img: Image = spr.get_image()
	if spr_img == null:
		return 1.0
	spr_img.convert(Image.FORMAT_RGBA8)

	# KEEP_ASPECT_CENTERED：等比缩放到装得进框，两边留白居中
	var inner := minf(float(Stage.CHAR_WIDTH) / float(spr_img.get_width()),
		float(Stage.CHAR_HEIGHT) / float(spr_img.get_height()))
	var off := Vector2((Stage.CHAR_WIDTH - spr_img.get_width() * inner) * 0.5,
		(Stage.CHAR_HEIGHT - spr_img.get_height() * inner) * 0.5)
	# 再叠加节点缩放：pivot 在脚底中心，所以屏幕位置 = pos + pivot + (local - pivot) * s
	var s := stage.get_char_scale("alice")
	if s <= 0.0:
		s = 1.0
	var pivot := Vector2(Stage.CHAR_WIDTH * 0.5, Stage.CHAR_HEIGHT)
	var top_left := pos + pivot + (off - pivot) * s
	var draw_size := Vector2(spr_img.get_width(), spr_img.get_height()) * inner * s

	var scaled := spr_img.duplicate() as Image
	scaled.resize(maxi(1, int(draw_size.x * vp.x)), maxi(1, int(draw_size.y * vp.y)),
		Image.INTERPOLATE_BILINEAR)
	spr_img = scaled
	var shot_pos := Vector2i(int(top_left.x * vp.x), int(top_left.y * vp.y))
	var full := Rect2i(Vector2i.ZERO, img.get_size())
	var px := Rect2i(shot_pos, spr_img.get_size()).intersection(full)
	if px.size.x <= 0 or px.size.y <= 0:
		return 1.0
	var shot := img.get_region(px)

	var ratios: Array = []
	for y in range(0, mini(spr_img.get_height(), shot.get_height()), 3):
		for x in range(0, mini(spr_img.get_width(), shot.get_width()), 3):
			var src_px := spr_img.get_pixel(x, y)
			if src_px.a < 0.95:
				continue
			if src_px.get_luminance() < 0.08:
				continue  # 跳过纯黑区，避免除小数放大噪声
			ratios.append(shot.get_pixel(x, y).get_luminance() / src_px.get_luminance())
	if ratios.is_empty():
		return 1.0
	ratios.sort()
	return ratios[ratios.size() / 2]


func _shot(fname: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://" + fname)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
