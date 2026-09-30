extends Control

## 总调度
##
## 唯一知道「所有子系统」的地方。ScriptRunner 抛出信号，这里转发给
## Stage（演出）和各个 UI 面板；UI 的交互结果再回灌给 runner。
## 其它脚本彼此之间零依赖，可以单独替换。
##
## 快捷键：
##   左键 / 空格 / 回车 —— 推进对白
##   Esc —— 设置面板（再按关闭）
##   滚轮上 / B —— 回看
##   A —— 自动播放    S —— 保存    L —— 读取

const SCRIPT_ENTRY := "res://data/scripts/prologue.gvs"
const SKIP_INTERVAL_MS := 30
const AUTOSAVE_BACKLOG_TAIL := 60
## 存档缩略图尺寸（16:9，够看清画面又不占体积）
const THUMB_WIDTH := 384
const THUMB_HEIGHT := 216
## 自动存档抓缩略图的最小间隔
const THUMB_INTERVAL_MS := 15000

@onready var stage: Stage = %Stage
@onready var dialogue: DialogueBox = %DialogueBox
@onready var choices: ChoicePanel = %ChoicePanel
@onready var backlog: BacklogPanel = %BacklogPanel
@onready var settings: SettingsPanel = %SettingsPanel
@onready var save_load: SaveLoadPanel = %SaveLoadPanel
@onready var gallery: GalleryPanel = %GalleryPanel
@onready var cg_viewer: CgViewer = %CgViewer
@onready var ui_layer: CanvasLayer = $UILayer
## 记录面板（结局 / 路线 / 已读 / 章节）完全由代码搭建，所以不在 main.tscn 里
var records: RecordsPanel
## 调试控制台（仅 debug 构建）
var debug_console: DebugConsole
@onready var title: TitleScreen = %TitleScreen

## UI 层震动的 Tween（全屏震动时对话框 / HUD 一起抖）
var _ui_shake_tween: Tween
@onready var minigame_layer: CanvasLayer = %MinigameLayer
@onready var hud: HBoxContainer = %HudBar
@onready var _btn_auto: Button = %BtnAuto
@onready var _btn_skip: Button = %BtnSkip
@onready var _btn_backlog: Button = %BtnBacklog
@onready var _btn_save: Button = %BtnSave
@onready var _btn_load: Button = %BtnLoad
@onready var _btn_settings: Button = %BtnSettings
@onready var _btn_title: Button = %BtnTitle

var runner: ScriptRunner

var _backlog_entries: Array = []
var _minigame_node: Node = null
var _last_speaker: String = ""
var _last_text: String = ""
var _auto_mode: bool = false
var _skip_mode: bool = false
## 隐藏 UI（截图模式）
var _ui_hidden: bool = false
## 上次抓存档缩略图的时间。初值取负值，让第一次自动存档就抓一张 ——
## 否则开局前 15 秒的自动存档会是「有存档没截图」。
var _last_thumb_ms: int = -15000
## 刚播过、但还没被某句台词认领的语音 id
var _pending_voice: String = ""
## 当前这一句的语音 id（点名字牌重播用）
var _line_voice: String = ""
## 上次记录过章节的剧本文件，用来避免每句都扫章节表
var _last_chapter_file: String = ""
var _auto_deadline_ms: int = 0
var _skip_next_ms: int = 0

## 重播模式：播放某段剧情但不动玩家进度，结束后原样还原
var _replay_active: bool = false
var _replay_snapshot: Dictionary = {}

## 重播期间禁止写自动存档，否则会把玩家真实进度覆盖成片段里的位置
var _autosave_enabled: bool = true


func _ready() -> void:
	runner = ScriptRunner.new()
	runner.name = "ScriptRunner"
	add_child(runner)

	runner.stage_command.connect(_on_stage_command)
	runner.audio_command.connect(_on_audio_command)
	runner.say.connect(_on_say)
	runner.choices.connect(_on_choices)
	runner.line_logged.connect(_on_line_logged)
	runner.minigame_requested.connect(_on_minigame_requested)
	runner.script_ended.connect(_on_script_ended)

	dialogue.advance_requested.connect(_on_advance_requested)
	dialogue.voice_replay_requested.connect(_on_voice_replay)
	choices.option_selected.connect(_on_option_selected)
	save_load.slot_chosen.connect(_on_slot_chosen)
	gallery.cg_activated.connect(_on_cg_activated)
	gallery.music_track_selected.connect(_on_music_track_selected)
	gallery.closed.connect(_on_gallery_closed)
	cg_viewer.replay_requested.connect(_on_cg_replay_requested)
	title.start_requested.connect(_on_start_requested)
	title.continue_requested.connect(_on_continue_requested)
	title.load_requested.connect(_on_load_requested)
	title.gallery_requested.connect(_on_gallery_requested)
	title.settings_requested.connect(_open_settings)

	_btn_auto.pressed.connect(_toggle_auto)
	_btn_skip.pressed.connect(_toggle_skip)
	_btn_backlog.pressed.connect(_open_backlog)
	_btn_save.pressed.connect(func() -> void: _open_save_load(false))
	_btn_load.pressed.connect(func() -> void: _open_save_load(true))
	_btn_settings.pressed.connect(_open_settings)
	_btn_title.pressed.connect(_back_to_title)

	records = RecordsPanel.new()
	records.name = "RecordsPanel"
	ui_layer.add_child(records)
	records.chapter_requested.connect(_on_chapter_requested)
	title.records_requested.connect(func() -> void: records.present())

	# 调试控制台只在 debug 构建里建出来 —— 导出版本不该带这个后门。
	# setup 必须在 add_child 之前调用，否则 _ready 里拿不到 main 引用。
	if OS.is_debug_build():
		debug_console = DebugConsole.new()
		debug_console.name = "DebugConsole"
		debug_console.setup(self)
		ui_layer.add_child(debug_console)

	_style_hud()
	_show_title()
	GameManager.tracking = false


# ---------------------------------------------------------------------------
# 帧循环：自动播放 / 快速跳过
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if runner == null:
		return
	# 重播期间不受自动播放 / 跳过影响
	if _replay_active:
		return
	if _skip_mode:
		var now := Time.get_ticks_msec()
		if now >= _skip_next_ms and runner.is_waiting_say():
			if _may_skip_current():
				_skip_next_ms = now + SKIP_INTERVAL_MS
				dialogue.complete_typing()
				runner.advance()
			else:
				# 撞上没看过的内容，自动停下来 —— 这是「跳过已读」的核心行为
				_set_skip_mode(false)
		return
	if _auto_mode and _auto_deadline_ms > 0 and Time.get_ticks_msec() >= _auto_deadline_ms:
		_auto_deadline_ms = 0
		if runner.is_waiting_say():
			dialogue.complete_typing()
			runner.advance()


# ---------------------------------------------------------------------------
# 输入
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if runner == null:
		return

	if _is_modal_open():
		if event.is_action_pressed("ui_cancel"):
			_close_modals()
			get_viewport().set_input_as_handled()
		return

	# 重播模式：只允许推进对白，Esc 中断回鉴赏界面
	if _replay_active:
		if event.is_action_pressed("ui_cancel"):
			_end_replay()
			get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseButton:
			var replay_click := event as InputEventMouseButton
			if replay_click.pressed and replay_click.button_index == MOUSE_BUTTON_LEFT:
				_on_advance_requested()
				get_viewport().set_input_as_handled()
				return
		if event.is_action_pressed("ui_accept"):
			_on_advance_requested()
			get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_cancel"):
		_open_settings()
		get_viewport().set_input_as_handled()
		return

	# 小游戏运行期间，输入交给小游戏处理
	if title.visible or runner.is_waiting_minigame():
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_on_advance_requested()
			get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_open_backlog()
			get_viewport().set_input_as_handled()
			return

	if event.is_action_pressed("ui_accept"):
		_on_advance_requested()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		match key.keycode:
			KEY_B:
				_open_backlog()
				get_viewport().set_input_as_handled()
			KEY_A:
				_toggle_auto()
				get_viewport().set_input_as_handled()
			KEY_S:
				_open_save_load(false)
				get_viewport().set_input_as_handled()
			KEY_L:
				_open_save_load(true)
				get_viewport().set_input_as_handled()
			KEY_H:
				_toggle_ui_hidden()
				get_viewport().set_input_as_handled()
			KEY_QUOTELEFT:
				if debug_console != null:
					debug_console.toggle()
					get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# 剧本 → 界面
# ---------------------------------------------------------------------------

func _on_stage_command(cmd: Dictionary) -> void:
	match String(cmd.get("op", "")):
		"bg":
			stage.set_bg(String(cmd.get("id", "")),
				String(cmd.get("transition", "fade")), float(cmd.get("duration", 0.4)))
		"show":
			stage.show_char(String(cmd.get("char", "")), String(cmd.get("expr", "normal")),
				String(cmd.get("at", "center")), String(cmd.get("transition", "fade")),
				float(cmd.get("duration", 0.3)))
		"hide":
			stage.hide_char(String(cmd.get("char", "")),
				String(cmd.get("transition", "fade")), float(cmd.get("duration", 0.3)))
		"move":
			stage.move_char(String(cmd.get("char", "")), String(cmd.get("at", "center")),
				float(cmd.get("duration", 0.35)), String(cmd.get("ease", Stage.DEFAULT_EASE)))
		"hop":
			stage.char_jump(String(cmd.get("char", "")), float(cmd.get("height", 40.0)),
				int(cmd.get("times", 2)), float(cmd.get("duration", 0.7)))
		"zoom":
			stage.char_zoom(String(cmd.get("char", "")), float(cmd.get("scale", 1.0)),
				float(cmd.get("duration", 0.4)), String(cmd.get("ease", "out_back")))
		"shake":
			stage.char_shake(String(cmd.get("char", "")), float(cmd.get("strength", 12.0)),
				int(cmd.get("times", 4)), float(cmd.get("duration", 0.4)))
		"screen_shake":
			var shake_strength := float(cmd.get("strength", 36.0))
			var shake_times := int(cmd.get("times", 5))
			var shake_duration := float(cmd.get("duration", 0.45))
			stage.screen_shake(shake_strength, shake_times, shake_duration)
			# 只震舞台是不够的：背景是铺满的渐变，整体平移没有参照物，看不出在动。
			# UI 一起震（对话框、HUD 跟着抖）才真的「吓一跳」。
			_shake_ui(shake_strength, shake_times, shake_duration)
		"screen_flash":
			stage.screen_flash(Color.from_string(String(cmd.get("color", "#ffffff")), Color.WHITE),
				float(cmd.get("duration", 0.25)))
		"bg_motion":
			stage.bg_motion(float(cmd.get("scale", 1.0)),
				Vector2(float(cmd.get("x", 0.0)), float(cmd.get("y", 0.0))),
				float(cmd.get("duration", 6.0)), String(cmd.get("ease", "in_out_cubic")))
		"weather":
			stage.set_weather(String(cmd.get("kind", "none")),
				float(cmd.get("intensity", 1.0)))
		"expr":
			stage.set_expr(String(cmd.get("char", "")), String(cmd.get("expr", "normal")),
				float(cmd.get("duration", 0.18)))
		"cg":
			stage.show_cg(String(cmd.get("id", "")), float(cmd.get("fade", 0.5)),
				String(cmd.get("transition", "fade")))
		"hide_cg":
			stage.hide_cg(float(cmd.get("fade", 0.4)),
				String(cmd.get("transition", "fade")))
		"clear":
			stage.clear()


## 全屏震动时同时震 UI 层。
##
## 只震舞台是不够的：背景是铺满的渐变，整体平移没有参照物，玩家看不出在动。
## 对话框 / HUD 一起抖，才真的「吓一跳」。
##
## 用 CanvasLayer.offset 而不是动子节点 —— offset 只影响渲染位置，
## 不污染各个面板自己的坐标，震完复位也没有副作用。
func _shake_ui(strength: float, times: int, duration: float) -> void:
	if _ui_shake_tween != null and _ui_shake_tween.is_valid():
		_ui_shake_tween.kill()
	ui_layer.offset = Vector2.ZERO
	if duration <= 0.0 or times <= 0:
		return

	var step := maxf(0.02, duration / float(times))
	var tw := create_tween()
	for i in times:
		var decay := 1.0 - float(i) / float(times)
		tw.tween_property(ui_layer, "offset", Vector2(
			randf_range(-strength, strength),
			randf_range(-strength, strength)) * decay, step).set_trans(Tween.TRANS_SINE)
	tw.tween_property(ui_layer, "offset", Vector2.ZERO, step).set_trans(Tween.TRANS_SINE)
	_ui_shake_tween = tw


## 玩家点了说话人名字牌 —— 重播这一句的语音。
## 没配语音的行点不动（也不会报错），所以剧本里可以只给关键台词配语音。
func _on_voice_replay() -> void:
	if _line_voice.is_empty():
		return
	AudioManager.play_voice(_line_voice)


func _on_audio_command(cmd: Dictionary) -> void:
	match String(cmd.get("op", "")):
		"bgm":
			var id := String(cmd.get("id", ""))
			if id == "stop" or id.is_empty():
				AudioManager.stop_bgm(float(cmd.get("fade", 1.0)))
			else:
				AudioManager.play_bgm(id, float(cmd.get("volume", 0.8)), float(cmd.get("fade", 1.0)))
		"se":
			AudioManager.play_se(String(cmd.get("id", "")), float(cmd.get("volume", 1.0)))
		"voice":
			# 记下来供「点名字牌重播」用。剧本里 voice 写在台词前面，
			# _on_say 会把它认领成「这一句的语音」。
			_pending_voice = String(cmd.get("id", ""))
			AudioManager.play_voice(_pending_voice, float(cmd.get("volume", 1.0)))


func _on_say(speaker: String, text: String, _expr: String) -> void:
	# 防御一：只要剧本继续往下走了，选项面板就必须收起来。
	# 否则一旦有别的路径推进了 runner（自动播放、跳过、读档、脚本驱动），
	# 残留的选项面板会一直挡在前面。
	if choices.visible:
		choices.dismiss()
	# 防御二：同理，任何残留的小游戏节点也要清掉。
	# 正常路径由 _on_minigame_finished 负责回收，这里兜住读档等旁路。
	if _minigame_node != null:
		_clear_minigame()
	_last_speaker = speaker
	_last_text = text
	ReadTracker.mark_read(text)
	dialogue.show_line(speaker, text)
	# 认领这一句的语音：剧本里 voice 写在台词前面，这里把它收进来。
	# 认领后清空 _pending_voice，下一句没写 voice 就不会误认领上一句的。
	_line_voice = _pending_voice
	_pending_voice = ""
	# 多立绘同框时，说话的人亮着、其他人压暗。旁白（speaker 为空）时全部恢复。
	stage.focus_speaker(speaker)
	_sync_visited_chapter()
	_arm_auto_deadline()
	# 每句对白都刷新自动存档。
	# 只在选项处存是不够的：那样「继续游戏」永远只能回到上一个选项，
	# 玩家在选项之后读的整段内容都会丢失。
	_autosave()


func _on_line_logged(speaker: String, text: String) -> void:
	_backlog_entries.append({"speaker": speaker, "text": text})
	if _backlog_entries.size() > BacklogPanel.MAX_ENTRIES:
		_backlog_entries.remove_at(0)


func _on_choices(options: Array) -> void:
	_auto_mode = false
	_skip_mode = false
	_refresh_toggle_buttons()
	_autosave()
	choices.present(options)


func _on_option_selected(index: int) -> void:
	# 先记下「在哪个选项点选了什么」再提交 ——
	# submit_choice 会把 ip 跳到目标标签，之后再查就查不到所在标签了
	RouteTracker.record_pick(runner.get_current_file(), runner.get_current_label(), index)
	runner.submit_choice(index)


## 记录玩家走过哪些章节。只在剧本文件变化时扫一次，不是每句都扫。
func _sync_visited_chapter() -> void:
	var file := runner.get_current_file()
	if file == _last_chapter_file:
		return
	_last_chapter_file = file
	for chapter in ScriptStats.chapters():
		if String((chapter as Dictionary).get("file", "")) == file:
			RouteTracker.record_chapter(String((chapter as Dictionary).get("id", "")))


func _on_script_ended(ending_id: String, ending_title: String) -> void:
	# 重播片段跑到终点标签就会走到这里，直接收尾回鉴赏界面，
	# 不要按「结局」处理（否则会给玩家弹一个假的结局提示）
	if _replay_active:
		_end_replay()
		return

	GameManager.tracking = false
	_auto_mode = false
	_skip_mode = false
	choices.dismiss()
	_refresh_toggle_buttons()

	if not ending_id.is_empty():
		GameManager.set_flag("ending_%s" % ending_id)
		# 计入结局收藏。id 必须全局唯一 —— 两个结局用同一个 id 会互相覆盖。
		CollectionManager.unlock("endings", ending_id)
		RouteTracker.save_now()

	var message := "—— 完 ——"
	if not ending_title.is_empty():
		message = "结局：%s" % ending_title
	elif not ending_id.is_empty():
		message = "结局：%s" % ending_id
	message += "\n（点击任意位置返回标题）"
	dialogue.show_line("", message)


# ---------------------------------------------------------------------------
# 推进
# ---------------------------------------------------------------------------

func _on_advance_requested() -> void:
	if runner == null or runner.is_waiting_minigame() or choices.visible:
		return
	if runner.is_ended():
		_back_to_title()
		return
	if dialogue.complete_typing():
		return
	runner.advance()


# ---------------------------------------------------------------------------
# 小游戏
# ---------------------------------------------------------------------------

func _on_minigame_requested(id: String, params: Dictionary) -> void:
	var scene := MinigameRegistry.get_scene(id)
	if scene == null:
		push_warning("[Minigame] 无法加载 '%s'，按失败处理" % id)
		runner.submit_minigame({"success": false, "score": 0, "max": 0})
		return

	dialogue.hide_box()
	_auto_mode = false
	_skip_mode = false
	_refresh_toggle_buttons()

	_clear_minigame()
	_minigame_node = scene.instantiate()
	minigame_layer.add_child(_minigame_node)
	if _minigame_node.has_signal("minigame_finished"):
		_minigame_node.minigame_finished.connect(_on_minigame_finished)
	if _minigame_node.has_method("setup"):
		_minigame_node.setup(params)
	if _minigame_node.has_method("start"):
		_minigame_node.start()


func _on_minigame_finished(result: Dictionary) -> void:
	_clear_minigame()
	runner.submit_minigame(result)


func _clear_minigame() -> void:
	if _minigame_node != null and is_instance_valid(_minigame_node):
		_minigame_node.queue_free()
	_minigame_node = null


# ---------------------------------------------------------------------------
# 鉴赏（CG / 音乐）与剧情重播
# ---------------------------------------------------------------------------

func _on_gallery_requested() -> void:
	if _replay_active:
		return
	gallery.present(GalleryPanel.TAB_CG)


func _on_gallery_closed() -> void:
	# 鉴赏面板里试听的曲子，关掉面板后不该继续响
	if title.visible:
		AudioManager.stop_bgm(0.6)


func _on_cg_activated(cg_id: String) -> void:
	cg_viewer.present(cg_id)


func _on_music_track_selected(id: String) -> void:
	AudioManager.play_bgm(id, 0.8, 0.4)


func _on_cg_replay_requested(cg_id: String) -> void:
	var item := CollectionRegistry.get_item("cg", cg_id)
	var replay: Variant = item.get("replay", {})
	if typeof(replay) != TYPE_DICTIONARY:
		return
	var plan: Dictionary = replay
	var file := String(plan.get("file", ""))
	var start_label := String(plan.get("label", ""))
	var end_label := String(plan.get("end_label", ""))
	if file.is_empty() or start_label.is_empty():
		return

	# 把玩家当前进度整份快照下来，重播结束后原样还原 ——
	# 重播片段里可能也有 set / affection / cg，不能让它污染真实进度。
	_replay_snapshot = {
		"game": GameManager.to_dict(),
		"stage": stage.get_state(),
		"backlog": _backlog_entries.duplicate(),
		"last_speaker": _last_speaker,
		"last_text": _last_text,
	}
	_replay_active = true
	_autosave_enabled = false
	_auto_mode = false
	_skip_mode = false
	_refresh_toggle_buttons()
	GameManager.tracking = false

	cg_viewer.hide_panel()
	gallery.hide_panel()
	title.visible = false
	hud.visible = false
	choices.dismiss()
	dialogue.hide_box()

	if not runner.start_replay(file, start_label, end_label):
		push_warning("[Replay] 无法重播 CG %s" % cg_id)
		_end_replay()


func _end_replay() -> void:
	if not _replay_active and _replay_snapshot.is_empty():
		return

	var return_cg := cg_viewer.get_current_id()

	_replay_active = false
	_autosave_enabled = true
	runner.stop()
	choices.dismiss()
	dialogue.hide_box()

	# 还原快照
	GameManager.from_dict(_replay_snapshot.get("game", {}))
	stage.restore_state(_replay_snapshot.get("stage", {}))
	_backlog_entries = []
	for entry in _replay_snapshot.get("backlog", []):
		if typeof(entry) == TYPE_DICTIONARY:
			_backlog_entries.append(entry)
	_last_speaker = String(_replay_snapshot.get("last_speaker", ""))
	_last_text = String(_replay_snapshot.get("last_text", ""))
	_replay_snapshot = {}

	hud.visible = false
	title.visible = true
	title.set_save_available(SaveManager.newest_slot() >= 0)

	# 回到 CG 详情页，玩家可以再播一次或直接关闭
	gallery.present(GalleryPanel.TAB_CG)
	if not return_cg.is_empty():
		cg_viewer.present(return_cg)


# ---------------------------------------------------------------------------
# 标题 / 流程
# ---------------------------------------------------------------------------

func _show_title() -> void:
	# 震动可能被中途打断，这里兜底把 UI 偏移复位
	if _ui_shake_tween != null and _ui_shake_tween.is_valid():
		_ui_shake_tween.kill()
	_ui_shake_tween = null
	ui_layer.offset = Vector2.ZERO

	title.set_save_available(SaveManager.newest_slot() >= 0)
	title.visible = true
	hud.visible = false
	dialogue.hide_box()
	choices.dismiss()
	_close_modals()


func _back_to_title() -> void:
	runner.stop()
	_auto_mode = false
	_skip_mode = false
	_replay_active = false
	_replay_snapshot = {}
	_autosave_enabled = true
	GameManager.tracking = false
	_clear_minigame()
	_refresh_toggle_buttons()
	_show_title()


func _on_start_requested(file: String = "", label: String = "") -> void:
	GameManager.reset_run()
	stage.clear()
	_backlog_entries.clear()
	_last_speaker = ""
	_last_text = ""
	_replay_active = false
	_replay_snapshot = {}
	_autosave_enabled = true
	_start_script(label, file)


## 章节选择：从指定剧本文件的指定标签开始
func _on_chapter_requested(file: String, label: String) -> void:
	records.hide_panel()
	_on_start_requested(file, label)


func _on_continue_requested() -> void:
	var slot := SaveManager.newest_slot()
	if slot >= 0:
		_load_slot(slot)


## 标题界面的「读取存档」：打开存档面板让玩家自己挑槽位。
## 面板关闭时标题仍在，读档成功则 _load_slot 会把标题收起来。
func _on_load_requested() -> void:
	_open_save_load(true)


func _start_script(label: String = "", file: String = "") -> void:
	var target := file if not file.is_empty() else SCRIPT_ENTRY
	if not runner.load_script(target):
		title.visible = false
		hud.visible = true
		dialogue.show_line("", "剧本加载失败，请查看控制台输出。\n（点击任意位置返回标题）")
		return
	title.visible = false
	hud.visible = true
	_close_modals()
	choices.dismiss()
	GameManager.tracking = true
	runner.start(label)


# ---------------------------------------------------------------------------
# 存读档
# ---------------------------------------------------------------------------

func _open_save_load(load_mode: bool) -> void:
	save_load.present(load_mode)


func _on_slot_chosen(slot: int) -> void:
	if save_load.is_load_mode():
		save_load.hide_panel()
		_load_slot(slot)
	else:
		await _save_to_slot(slot)


## 写存档。缩略图必须在写之前抓，而且要把存档面板藏起来 ——
## 否则拍进去的是面板自己。
func _save_to_slot(slot: int) -> void:
	await _capture_thumbnail(slot)
	SaveManager.write_slot(slot, _build_payload())
	save_load.refresh()


## 抓当前画面作为存档缩略图。
##
## 存档面板盖在画面上，直接抓图会把它自己也拍进去，所以先藏起来、等两帧再抓
## （只等一帧可能那帧已经把面板画进去了）。一帧的隐藏人眼察觉不到。
func _capture_thumbnail(slot: int) -> void:
	if not is_inside_tree():
		return
	var panel_was_visible := save_load.visible
	save_load.visible = false
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image != null:
		image.resize(THUMB_WIDTH, THUMB_HEIGHT, Image.INTERPOLATE_LANCZOS)
		SaveManager.write_thumbnail(slot, image)
	save_load.visible = panel_was_visible


func _build_payload() -> Dictionary:
	var tail_start := maxi(0, _backlog_entries.size() - AUTOSAVE_BACKLOG_TAIL)
	return {
		"chapter_title": GameManager.chapter_title,
		"preview": _last_text,
		"speaker": _last_speaker,
		"play_time": GameManager.play_time,
		"game": GameManager.to_dict(),
		"runner": runner.get_state(),
		"stage": stage.get_state(),
		"backlog": _backlog_entries.slice(tail_start),
	}


func _load_slot(slot: int) -> void:
	var data := SaveManager.read_slot(slot)
	if data.is_empty():
		return

	_auto_mode = false
	_skip_mode = false
	_refresh_toggle_buttons()

	GameManager.from_dict(data.get("game", {}))
	stage.restore_state(data.get("stage", {}))
	_backlog_entries = []
	for entry in data.get("backlog", []):
		if typeof(entry) == TYPE_DICTIONARY:
			_backlog_entries.append(entry)
	_last_speaker = String(data.get("speaker", ""))
	_last_text = String(data.get("preview", ""))

	title.visible = false
	hud.visible = true
	_close_modals()
	choices.dismiss()

	if not runner.restore_state(data.get("runner", {})):
		dialogue.show_line("", "读档失败：剧本文件缺失或已损坏。\n（点击任意位置返回标题）")
		return

	# 若恢复到的是「选项 / 小游戏」等待态，runner 不会重新发出 say，
	# 对话框就会空着，玩家只看到孤零零的选项而不知道上下文。
	# 这里把存档时那句对白补回去。
	if not runner.is_waiting_say() and not _last_text.is_empty():
		dialogue.show_line(_last_speaker, _last_text)

	GameManager.tracking = true


func _autosave() -> void:
	# 重播期间禁止写自动存档，否则会把玩家真实进度覆盖成片段里的位置
	if not _autosave_enabled:
		return
	if runner == null or runner.get_current_file().is_empty():
		return
	SaveManager.write_slot(SaveManager.AUTO_SLOT, _build_payload())
	# 已读记录顺带落盘 —— 不必每句话都写一次文件
	ReadTracker.save_now()
	# 自动存档的缩略图要节流：抓图是 GPU→CPU 回读，每句都抓会明显掉帧
	var now := Time.get_ticks_msec()
	if now - _last_thumb_ms >= THUMB_INTERVAL_MS:
		_last_thumb_ms = now
		# 稍等一下再抓：刚进新场景时背景还在淡入，立刻抓会是一片黑。
		# 先更新时间戳再 await，这样连点快进时不会堆起一堆并发的抓图。
		await get_tree().create_timer(0.6).timeout
		await _capture_thumbnail(SaveManager.AUTO_SLOT)


# ---------------------------------------------------------------------------
# 面板与按钮
# ---------------------------------------------------------------------------

func _open_backlog() -> void:
	if _backlog_entries.is_empty():
		return
	backlog.present(_backlog_entries)


func _open_settings() -> void:
	settings.present()


func _is_modal_open() -> bool:
	return settings.visible or save_load.visible or backlog.visible \
		or gallery.visible or cg_viewer.visible or records.visible \
		or (debug_console != null and debug_console.visible)


func _close_modals() -> void:
	settings.hide_panel()
	save_load.hide_panel()
	backlog.hide_panel()
	if records != null:
		records.hide_panel()
	# Esc 是「退一层」：先关 CG 详情回到鉴赏网格，再关鉴赏面板
	if cg_viewer.visible:
		cg_viewer.hide_panel()
		return
	gallery.hide_panel()


func _toggle_auto() -> void:
	_auto_mode = not _auto_mode
	if _auto_mode:
		_skip_mode = false
		_arm_auto_deadline()
	_refresh_toggle_buttons()


func _toggle_skip() -> void:
	_set_skip_mode(not _skip_mode)


func _set_skip_mode(on: bool) -> void:
	if _skip_mode == on:
		return
	_skip_mode = on
	if _skip_mode:
		_auto_mode = false
		_skip_next_ms = 0
	_refresh_toggle_buttons()


## 跳过键是否该继续快进这一句。
##
## 默认「只跳已读」—— 遇到没看过的台词就停下，这是 galgame 的标配行为
## （否则玩家会误跳过新剧情）。玩家可在设置里打开「跳过未读」改成一路到底。
func _may_skip_current() -> bool:
	if bool(ConfigManager.get_value("skip_unread", false)):
		return true
	return ReadTracker.is_read(dialogue.get_full_text())


## 隐藏 / 显示全部 UI（截图或纯欣赏画面用）
func _toggle_ui_hidden() -> void:
	_ui_hidden = not _ui_hidden
	ui_layer.visible = not _ui_hidden


func _arm_auto_deadline() -> void:
	if not _auto_mode or not runner.is_waiting_say():
		_auto_deadline_ms = 0
		return
	var speed := maxf(1.0, float(ConfigManager.get_value("text_speed", 45.0)))
	var typing_ms := 0
	if dialogue.is_typing():
		typing_ms = int(float(_last_text.length()) / speed * 1000.0)
	var hold_ms := int(float(ConfigManager.get_value("auto_delay", 1.6)) * 1000.0)
	_auto_deadline_ms = Time.get_ticks_msec() + typing_ms + hold_ms


func _refresh_toggle_buttons() -> void:
	_btn_auto.text = "自动（开）" if _auto_mode else "自动"
	_btn_skip.text = "跳过（开）" if _skip_mode else "跳过"


func _style_hud() -> void:
	for child in hud.get_children():
		var btn := child as Button
		if btn == null:
			continue
		btn.focus_mode = Control.FOCUS_NONE
		UiTheme.apply_button(btn, "hud")
