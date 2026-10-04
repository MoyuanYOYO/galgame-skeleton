extends Node

## 多周目界面验收（文字断言 + 可选截图）
##
## 用法：
##   # 只跑文字断言（headless 也能跑，适合 CI）
##   "D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --headless --path . res://tools/cycle_demo.tscn
##   # 顺便出两张图（需要窗口）
##   "D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/cycle_demo.tscn
##
## 它把 CycleManager 拨到「第 2 周目 + 通关 3 次 + 有继承数据」，然后检查
## 标题界面与记录面板**有没有把周目信息显示出来**，最后原样还原。
##
## 和 smoke 第 30 节的分工：那一节验的是数据（推进时机 / 取值时机 / 条件求值），
## 这一支验的是**玩家真的看得见** —— 逻辑全对但界面没接线的 bug 只有它抓得到。

const OUT_DIR := "user://captures"
const MAIN_SCENE := "res://scenes/main.tscn"

var _main: Node
var _failed := 0
var _checks := 0

## 收集真实剧本台词用（lambda 对局部变量按值捕获，收不到）
var _say_texts: Array = []

## 二周目独白 —— 和 data/scripts/prologue.gvs 里那句必须一致。
## 故意写死在这里：剧本那边改了而这里没改，就是「NG+ 内容被改坏了」的信号。
const NG_PLUS_LINE := "（——又是四月。这一次，我大概知道该说什么了。）"


func _collect_text(_speaker: String, text: String, _expr: String) -> void:
	_say_texts.append(text)


func _ready() -> void:
	var backup := CycleManager.to_dict()
	var existed := FileAccess.file_exists(CycleManager.SAVE_PATH)
	# 端到端那一段会走真实入口开一局，于是会写自动存档 —— 一并备份还原，
	# 否则跑一次验收就把玩家「继续游戏」的位置顶掉了。
	var auto_backup := SaveManager.read_slot(SaveManager.AUTO_SLOT)

	# 造现场：通关 3 次（3 个不同结局）、带着 alice 的好感度进第 2 周目
	CycleManager.reset_all()
	CycleManager.record_ending("prologue_alone")
	CycleManager.record_ending("bad")
	GameManager.reset_run()
	GameManager.set_affection("alice", 61)
	CycleManager.clear_carry_marks()
	CycleManager.mark_carry("affection", "alice")
	CycleManager.record_ending("true_end")
	CycleManager.begin_new_run(true)

	_ok(CycleManager.get_cycle() == 2, "现场：当前是第 2 周目")
	_ok(CycleManager.total_clears() == 3, "现场：一共通关 3 次")
	_ok(CycleManager.distinct_clears() == 3, "现场：解锁 3 个不同结局")
	_ok(CycleManager.has_inherited(), "现场：带着上一周目的继承数据")

	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _wait(0.2)
	var scene := load(MAIN_SCENE) as PackedScene
	_main = scene.instantiate()
	get_tree().root.add_child(_main)
	await _wait(0.6)

	# --- 标题界面 ---
	var title := _main.get("title") as TitleScreen
	var cycle_label := title.get_node_or_null("Center/VBox/CycleLabel") as Label
	_ok(cycle_label != null, "标题界面建出了周目提示标签")
	if cycle_label == null:
		_restore(backup, existed, auto_backup)
		get_tree().quit(1)
		return
	_ok(cycle_label.visible, "二周目时周目提示可见")
	_ok(cycle_label.text.contains("第 2 周目") and cycle_label.text.contains("3"),
		"周目提示文案正确（%s）" % cycle_label.text)
	print("[cycle] 标题提示：%s" % cycle_label.text)
	await _shot("cycle_01_title")

	# 一周目且没通关过 → 整行隐藏，不提前剧透「这游戏要玩好几遍」
	title.set_cycle_info(1, 0)
	_ok(not cycle_label.visible, "一周目且没通关过时周目提示隐藏")
	title.set_cycle_info(2, 3)
	_ok(cycle_label.visible, "拨回二周目后提示重新出现")

	# --- 记录面板 ---
	_main.get("records").call("present")
	await _wait(0.4)
	var records: Node = _main.get("records")
	var body := records.get("_body") as VBoxContainer
	var section_texts: Array = []
	if body != null and body.get_child_count() > 1:
		section_texts = _collect_labels(body.get_child(1))
	_ok(not section_texts.is_empty(), "记录面板有「多周目」板块（%d 行）" % section_texts.size())
	var joined := "\n".join(section_texts)
	_ok(joined.contains("第 2 周目"), "板块显示当前周目")
	_ok(joined.contains("3 次"), "板块显示通关次数")
	_ok(joined.contains("春日的答案"), "板块列出通关过的结局标题（不是裸 id）")
	_ok(joined.contains("alice"), "板块列出下一周目继承的内容")
	print("[cycle] 记录面板「多周目」板块：\n%s" % joined)
	await _shot("cycle_02_records")

	# --- 调试台 ---
	var console = _main.get("debug_console")
	if console != null:
		console.toggle()
		console.call("_execute", "cycle")
		console.call("_execute", "cycle 4")
		_ok(CycleManager.get_cycle() == 4, "调试台 cycle 4 能拨周目")
		console.call("_execute", "cycle reset")
		_ok(CycleManager.get_cycle() == 1, "调试台 cycle reset 能清空周目记录")
		console.toggle()

	# --- 真实剧本端到端：二周目跑序章开头，应当看到 NG+ 独白 ---
	# 这一条同时验了三件事：条件能解析、调度器会求值、**剧本里那句放在会被走到的地方**。
	# 作者把它误写进某个 cg_xxx 重播片段里、或写在 ending 之后，这里都会红。
	CycleManager.force_cycle(2)
	var lines_ng := await _run_prologue_head()
	_ok(lines_ng.has(NG_PLUS_LINE), "二周目跑真实剧本能看到 NG+ 独白")
	CycleManager.force_cycle(1)
	var lines_first := await _run_prologue_head()
	_ok(not lines_first.has(NG_PLUS_LINE), "一周目看不到那段独白")
	print("[cycle] 二周目序章开头：%s" % str(lines_ng))

	_restore(backup, existed, auto_backup)

	print("[cycle] 结束（%d / %d）" % [_checks - _failed, _checks])
	get_tree().quit(1 if _failed > 0 else 0)

## 从真实入口开一局序章，收到前几句就停。走 `_on_start_requested` 而不是直接
## `runner.start()` —— 那样才真的经过「reset_run + begin_new_run + 载入剧本」这条链。
func _run_prologue_head() -> Array:
	var runner: ScriptRunner = _main.get("runner") as ScriptRunner
	_say_texts.clear()
	if not runner.say.is_connected(_collect_text):
		runner.say.connect(_collect_text)
	_main.call("_on_start_requested")
	var guard := 60
	while _say_texts.size() < 3 and guard > 0:
		guard -= 1
		if runner.is_waiting_say():
			runner.advance()
		elif runner.is_waiting_choice():
			break
		else:
			await get_tree().process_frame
	return _say_texts.duplicate()


func _restore(backup: Dictionary, existed: bool, auto_backup: Dictionary) -> void:
	if existed:
		CycleManager.from_dict(backup)
		CycleManager.save_now()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CycleManager.SAVE_PATH))
	if auto_backup.is_empty():
		SaveManager.delete_slot(SaveManager.AUTO_SLOT)
	else:
		SaveManager.write_slot(SaveManager.AUTO_SLOT, auto_backup)


func _ok(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("   OK   %s" % label)
	else:
		_failed += 1
		printerr("   FAIL %s" % label)


static func _collect_labels(root: Node) -> Array:
	var out: Array = []
	for child in root.get_children():
		if child is Label:
			out.append((child as Label).text)
		out.append_array(_collect_labels(child))
	return out


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## 出图。headless 下视口是假的（拿到 1×1 空图），直接跳过 ——
## 这样同一支工具既能当 CI 断言跑，也能在窗口模式下出图。
func _shot(shot_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := image.save_png(path)
	print("[cycle] %s -> %s (err=%d)" % [shot_name, path, err])
