extends Node

## 预览端到端 —— 从 start 一路跑到结束，看会不会卡在某个等待态
##
## 跑法（要带窗口）：
##   godot --path . res://tools/editor/tests/preview_test.tscn

const EditorScene = preload("res://tools/editor/editor.tscn")

var _ed: Control
var _pv: Control
var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 预览端到端（跑到剧本结束）===")

	_ed = EditorScene.instantiate()
	add_child(_ed)
	_ed.size = get_viewport().get_visible_rect().size
	await _wait(1.0)

	_pv = _ed._preview_panel
	_ok(_pv != null, "预览面板已创建")
	if _pv == null:
		_finish()
		return

	_ed.goto_source(15)          # label start
	await _wait(0.3)
	_pv.run_from(15)
	await _wait(0.4)
	_ok(_pv.is_running(), "预览已启动")

	# 一路推进，直到结束或卡住。
	# 注意不能用「状态不变」判断卡住 —— 每句台词都是 WAITING_SAY，
	# 状态本来就不会变。要看的是**推进句数**有没有增长。
	var runner = _pv._runner
	# GDScript 的 lambda **按值捕获**局部变量 —— 直接写 `say_count += 1` 只会改
	# 闭包内部的副本，外面看到的永远是 0。所以用数组（引用类型）当计数器。
	var counter := [0]
	runner.line_logged.connect(func(_s: String, _t: String) -> void: counter[0] += 1)
	var say_count := 0

	var last_count := -1
	var stuck_for := 0
	var stuck_at := ""
	for i in 300:                # 最多 60 秒
		await _wait(0.2)
		if not _pv.is_running():
			break
		say_count = int(counter[0])
		if say_count == last_count:
			stuck_for += 1
		else:
			stuck_for = 0
			last_count = say_count
		if stuck_for >= 15:      # 3 秒没推进一句
			stuck_at = runner.get_state_name()
			break
		if runner.is_waiting_minigame():
			# 编辑器应当自动跳过小游戏；等一会儿若仍卡着就是没修好
			await _wait(0.6)
			if runner.is_waiting_minigame():
				stuck_at = "waiting_minigame"
				print("  小游戏仍然卡住（自动跳过没生效）")
				break
			continue
		if runner.is_waiting_choice():
			# 截一张图看选项按钮长什么样，再自动选第一项继续
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://captures"))
			img.save_png("user://captures/preview_choice.png")
			print("  已截图选项状态 → user://captures/preview_choice.png")
			runner.submit_choice(0)
			await _wait(0.3)
			continue
		if runner.is_waiting_click() or runner.is_waiting_say():
			_pv.advance()

	print("  推进了 %d 句" % say_count)
	print("  最终状态：%s，running=%s" % [runner.get_state_name(), str(_pv.is_running())])

	if not stuck_at.is_empty():
		print("  卡在：%s" % stuck_at)
	_ok(stuck_at.is_empty(), "预览不会卡在某个等待态（卡在 %s）" % stuck_at)
	_ok(not _pv.is_running(), "预览最终跑到了结束")

	_finish()


func _finish() -> void:
	print("")
	if _fail == 0:
		print("=== ALL OK  %d 项 ===" % _pass)
		get_tree().quit(0)
	else:
		print("=== FAILED  %d 通过 / %d 失败 ===" % [_pass, _fail])
		get_tree().quit(1)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  OK    %s" % msg)
	else:
		_fail += 1
		print("  FAIL  %s" % msg)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
