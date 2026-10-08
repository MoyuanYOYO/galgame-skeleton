extends Node

## 渲染截图工具（需要非 headless 运行）
##
## 用法：
##   "D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/capture.tscn
##
## 会依次驱动标题 → 对白 → 选项 → 小游戏 → 回看 → 设置 → 存档，并各存一张 PNG。
## 注意：等待一律按「真实时间」而不是「帧数」—— 关掉垂直同步后帧率可能极高，
## 按帧数等会让 Tween 只走了一点点，截到动画中间态。

const OUT_DIR := "user://captures"
const MAIN_SCENE := "res://scenes/main.tscn"

var _main: Node
## 玩家数据的现场备份 —— 这个工具会**真的把剧情推到结局**、还会解锁一堆收藏，
## 不备份的话跑一次截图就把玩家的周目记录和鉴赏进度改了
## （实测：连跑几次之后标题界面变成「第 10 周目 · 已通关 9 次」）。
## `tools/smoke.gd` 一直是这么做的，这里补上。
var _cycle_backup: Dictionary = {}
var _collection_backup: Dictionary = {}
var _config_backup: Dictionary = {}
var _auto_backup: Dictionary = {}
var _cycle_file_existed := false


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_backup_player_data()

	await _wait(0.2)
	var scene := load(MAIN_SCENE) as PackedScene
	_main = scene.instantiate()
	get_tree().root.add_child(_main)
	await _wait(0.6)
	await _shot("01_title")

	_main.call("_on_start_requested")
	await _wait(2.0)
	await _shot("02_dialogue")

	var runner: ScriptRunner = _main.get("runner") as ScriptRunner
	if runner == null:
		push_error("[capture] 没有拿到 runner")
		get_tree().quit(1)
		return

	var choice_panel: ChoicePanel = _main.get("choices") as ChoicePanel

	var guard := 400
	while not runner.is_waiting_choice() and guard > 0:
		guard -= 1
		_main.call("_on_advance_requested")
		await _wait(0.05)
	await _wait(1.2)
	await _shot("03_choice")

	# 走真实 UI 路径点击选项（直接调 runner.submit_choice 会绕过面板收起逻辑）
	choice_panel.call("_on_pressed", 0)
	await _wait(1.2)
	await _shot("04_after_choice")

	# 全屏特效。这是唯一能确认「后处理真的连 UI 一起读到了」的手段 ——
	# 截下来的图里对话框的文字也该跟着扭曲。逻辑测试看不见这个：
	# 层放错位置时特效只会糊背景，而断言照样全绿。
	_main.call("_on_stage_command",
		{"op": "screen_fx", "kind": "glitch", "strength": 1.2, "duration": 0.0})
	await _wait(0.4)
	await _shot("04b_fx_glitch")
	_main.call("_on_stage_command",
		{"op": "screen_fx", "kind": "wave", "strength": 1.2, "duration": 0.0})
	await _wait(0.4)
	await _shot("04c_fx_wave")
	_main.call("_on_stage_command",
		{"op": "screen_fx", "kind": "swirl", "strength": 0.9, "duration": 0.0})
	await _wait(0.4)
	await _shot("04d_fx_swirl")
	_main.call("_on_stage_command",
		{"op": "screen_fx", "kind": "pixelate", "strength": 0.7, "duration": 0.0})
	await _wait(0.4)
	await _shot("04e_fx_pixelate")
	_main.call("_on_stage_command",
		{"op": "screen_fx", "kind": "blur", "strength": 1.2, "duration": 0.0})
	await _wait(0.4)
	await _shot("04f_fx_blur")
	# 用 clear 关（而不是走剧本的 clear 指令）—— 后者会顺手把舞台也清空，
	# 后面的截图就没有背景了
	_main.get("screen_fx").call("clear")
	await _wait(0.2)

	# 模态面板要压住特效。这两张是一对：08b 里设置面板应当是**干净**的
	# （特效被收起），08c 关掉面板后扭曲又回来 —— 证明只是暂时不显示，
	# 而不是把特效关掉了。
	_main.call("_on_stage_command",
		{"op": "screen_fx", "kind": "wave", "strength": 1.4, "duration": 0.0})
	await _wait(0.3)
	_main.call("_open_settings")
	await _wait(0.8)
	await _shot("08b_settings_over_fx")
	_main.call("_close_modals")
	await _wait(0.5)
	await _shot("08c_fx_resumed")
	_main.get("screen_fx").call("clear")
	await _wait(0.2)

	guard = 600
	while not runner.is_waiting_minigame() and guard > 0:
		guard -= 1
		if runner.is_waiting_choice():
			choice_panel.call("_on_pressed", 0)
		else:
			_main.call("_on_advance_requested")
		await _wait(0.05)
	await _wait(1.0)
	await _shot("05_minigame")

	# 让 QTE 打一回合，抓一张有判定反馈的图
	var minigame: Node = _main.get("_minigame_node")
	if minigame != null and is_instance_valid(minigame):
		minigame.call("_judge")
		await _wait(0.2)
		await _shot("06_minigame_hit")
	runner.submit_minigame({"success": true, "score": 5, "max": 5})
	await _wait(0.5)

	# 推进到放学场景，让对白积累一些内容再抓回看
	guard = 400
	while not runner.is_waiting_choice() and guard > 0:
		guard -= 1
		if runner.is_waiting_choice():
			choice_panel.call("_on_pressed", 0)
		else:
			_main.call("_on_advance_requested")
		await _wait(0.05)
	await _wait(0.8)

	_main.call("_open_backlog")
	await _wait(0.8)
	await _shot("07_backlog")
	_main.call("_close_modals")

	_main.call("_open_settings")
	await _wait(0.8)
	await _shot("08_settings")
	_main.call("_close_modals")

	# 先真存一次档，面板里才有缩略图可看（顺带验证缩略图功能）
	_main.call("_save_to_slot", 1)
	await _wait(1.2)
	_main.call("_open_save_load", false)
	await _wait(0.8)
	await _shot("09_save")
	_main.call("_close_modals")

	# 回到标题并打开读档面板（验证标题界面也能读档）
	_main.call("_back_to_title")
	await _wait(0.6)
	await _shot("10_title")

	# 记录面板（结局 / 路线 / 已读 / 章节）
	_main.get("records").call("present")
	await _wait(0.8)
	await _shot("11_records")
	_main.get("records").call("hide_panel")
	await _wait(0.3)

	# 调试控制台（只在 debug 构建里有）
	var console = _main.get("debug_console")
	print("[capture] debug_console = %s" % str(console))
	if console != null:
		console.call("toggle")
		console.call("_execute", "help")
		await _wait(0.5)
		var panel = console.get_node_or_null("PanelContainer")
		print("[capture] console.size=%s  panel=%s  panel.size=%s  panel.pos=%s"
			% [str(console.size), str(panel),
				str(panel.size) if panel != null else "-",
				str(panel.global_position) if panel != null else "-"])
		await _wait(0.5)
		await _shot("12_console")
		console.call("toggle")
		await _wait(0.3)

	_main.call("_on_load_requested")
	await _wait(0.8)
	await _shot("11_title_load")
	_main.call("_close_modals")

	# 鉴赏界面：先解锁一部分内容，让截图能同时体现「已解锁 / 未解锁」两种状态
	CollectionManager.unlock("cg", "cg_classroom")
	CollectionManager.unlock("cg", "cg_rooftop")
	CollectionManager.unlock("cg", "cg_street")
	CollectionManager.unlock("music", "daily")
	CollectionManager.unlock("music", "sunset")
	CollectionManager.unlock("music", "theme")

	_main.call("_on_gallery_requested")
	await _wait(0.9)
	await _shot("12_gallery_cg")

	var gallery: GalleryPanel = _main.get("gallery") as GalleryPanel
	gallery.show_tab(GalleryPanel.TAB_MUSIC)
	await _wait(0.5)
	_main.call("_on_music_track_selected", "sunset")
	await _wait(1.0)
	await _shot("13_gallery_music")

	gallery.show_tab(GalleryPanel.TAB_CG)
	await _wait(0.4)
	_main.call("_on_cg_activated", "cg_rooftop")
	await _wait(0.9)
	await _shot("14_cg_viewer")

	print("[capture] 完成，输出目录: %s" % ProjectSettings.globalize_path(OUT_DIR))
	_restore_player_data()
	get_tree().quit(0)


# ---------------------------------------------------------------------------
# 玩家数据备份 / 还原
# ---------------------------------------------------------------------------

func _backup_player_data() -> void:
	_cycle_backup = CycleManager.to_dict()
	_collection_backup = CollectionManager.to_dict()
	_config_backup = ConfigManager.data.duplicate(true)
	_auto_backup = SaveManager.read_slot(SaveManager.AUTO_SLOT)
	# 连「文件原本存不存在」也记下来：第一次跑不该凭空给玩家造出一个周目记录
	_cycle_file_existed = FileAccess.file_exists(CycleManager.SAVE_PATH)


func _restore_player_data() -> void:
	if _auto_backup.is_empty():
		SaveManager.delete_slot(SaveManager.AUTO_SLOT)
	else:
		SaveManager.write_slot(SaveManager.AUTO_SLOT, _auto_backup)
	CollectionManager.from_dict(_collection_backup)
	CollectionManager.save_data()
	for key in _config_backup.keys():
		ConfigManager.set_value(String(key), _config_backup[key], false)
	if _cycle_file_existed:
		CycleManager.from_dict(_cycle_backup)
		CycleManager.save_now()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CycleManager.SAVE_PATH))
	print("[capture] 玩家数据已还原")


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := image.save_png(path)
	print("[capture] %s -> %s (err=%d)" % [shot_name, path, err])
