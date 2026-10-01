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

## 剧本文件位置由 ScriptPaths 统一决定（含语言子目录解析），这里不再写死
const SKIP_INTERVAL_MS := 30
const AUTOSAVE_BACKLOG_TAIL := 60
## 存档缩略图尺寸（16:9，够看清画面又不占体积）
const THUMB_WIDTH := 384
const THUMB_HEIGHT := 216
## 自动存档抓缩略图的最小间隔
const THUMB_INTERVAL_MS := 15000
## 回滚历史保留的最大节点数。够翻好几章，又不至于把内存吃满 ——
## 每份快照只有几百字节（软状态 + 画面摘要），100 份是几十 KB 量级。
const ROLLBACK_CAPACITY := 100

@onready var stage: Stage = %Stage
## 全屏特效层。在 UILayer 之上（见 main.tscn 的 FxLayer），
## 所以它连对话框一起变形 —— 这是刻意的。
@onready var screen_fx: ScreenFx = %ScreenFx
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

## 回滚历史。每显示一句对白 / 弹一次选项就存一份快照，滚轮在历史里前后移动。
var _rollback := RollbackBuffer.new(ROLLBACK_CAPACITY)
## 正在从快照还原。还原会让调度器重新执行指令、再次触发 _on_say / _on_choices，
## 这里置位把「采集快照」挡住 —— 否则每回滚一次就往历史里塞一条重复项。
var _restoring: bool = false


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
	save_load.slots_changed.connect(_on_slots_changed)
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

	# 模态面板打开时把全屏特效收起来。特效层在 UI 之上，不收的话面板会跟着
	# 一起扭曲 —— 玩家正在读的那一屏恰恰最不该糊。挂在各个面板的
	# visibility_changed 上而不是每个开关处各写一行：面板有一堆入口
	# （按钮 / 快捷键 / 标题界面 / 剧本），漏一处就是一个「面板糊了」的 bug。
	for panel in [backlog, settings, save_load, gallery, cg_viewer, title, records]:
		(panel as CanvasItem).visibility_changed.connect(_refresh_fx_suspension)

	# 调试控制台只在 debug 构建里建出来 —— 导出版本不该带这个后门。
	# setup 必须在 add_child 之前调用，否则 _ready 里拿不到 main 引用。
	if OS.is_debug_build():
		debug_console = DebugConsole.new()
		debug_console.name = "DebugConsole"
		debug_console.setup(self)
		ui_layer.add_child(debug_console)

	_style_hud()
	# 界面文案翻译要在所有界面都建好之后、显示之前做一遍。
	# 静态文案（写在 main.tscn 里的按钮 / 标签）由它统一替换，
	# 代码里拼出来的那部分在各自的生成处显式调了 I18n.t()。
	I18n.language_changed.connect(_on_language_changed)
	I18n.apply_tree(ui_layer)
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
			# 滚轮向上 = 回退一句（galgame 的通用习惯）。
			# 想换回旧行为（滚轮上打开回看）在设置里关掉「滚轮用于回滚剧情」。
			if _wheel_rollback_enabled():
				_rollback_step(-1)
			else:
				_open_backlog()
			get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			# 向下 = 撤销一次回退（前进）。翻过头了不用怕。
			if _wheel_rollback_enabled():
				_rollback_step(1)
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
		"screen_fx":
			screen_fx.play(String(cmd.get("kind", ScreenFxSpec.OFF)),
				float(cmd.get("strength", 1.0)),
				float(cmd.get("duration", ScreenFxSpec.DEFAULT_DURATION)))
		"clear":
			stage.clear()
			screen_fx.clear()


## 全屏特效是否该被模态面板压住。
##
## 「全屏」意味着它盖在对话框和按钮上，而玩家要读的字也在那儿 ——
## 所以只要有面板在显示，就把特效层收起来。收起不动强度：
## 面板关掉后特效原样接着演，「一直扭曲」这类长镜头不会被打断。
func _refresh_fx_suspension() -> void:
	screen_fx.set_suspended(
		backlog.visible or settings.visible or save_load.visible
		or gallery.visible or cg_viewer.visible or title.visible or records.visible)


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
			var voice_id := String(cmd.get("id", ""))
			# 同一句里连写多条 voice 时，_pending_voice 还是上一条 —— 说明它们
			# 属于同一句，排队依次播完；已经跨过一句（_pending_voice 被认领掉了）
			# 就直接打断，别让上一条语音拖到这句台词上。
			var chained := not _pending_voice.is_empty()
			_pending_voice = voice_id
			AudioManager.play_voice(voice_id, float(cmd.get("volume", 1.0)), chained)


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
	# 顺序要紧：先问「这句以前看过没有」，再去标记已读 ——
	# 反过来的话「已读变暗」会把每一句都当成已读，包括第一次看到的那句。
	var was_read := ReadTracker.is_read(text)
	ReadTracker.mark_read(text)
	dialogue.show_line(speaker, text, was_read)
	# 认领这一句的语音：剧本里 voice 写在台词前面，这里把它收进来。
	# 认领后清空 _pending_voice，下一句没写 voice 就不会误认领上一句的。
	_line_voice = _pending_voice
	_pending_voice = ""
	# 多立绘同框时，说话的人亮着、其他人压暗。旁白（speaker 为空）时全部恢复。
	stage.focus_speaker(speaker)
	_sync_visited_chapter()
	_arm_auto_deadline()
	# 记一份回滚快照。此刻 runner 正停在「等这句推进」上，
	# get_state() 返回的 ip 正好指向这条 say 本身，回滚才能重新显示它。
	if _may_record_history():
		_rollback.push(_make_snapshot("say"))
	# 每句对白都刷新自动存档。
	# 只在选项处存是不够的：那样「继续游戏」永远只能回到上一个选项，
	# 玩家在选项之后读的整段内容都会丢失。
	_autosave()


func _on_line_logged(speaker: String, text: String) -> void:
	# 回滚还原时调度器会重放这条 say，但它的回看记录本来就还在
	# （快照里存了长度、并按此截断过），再记一次会多出一条重复对白。
	if _restoring:
		return
	_backlog_entries.append({"speaker": speaker, "text": text})
	if _backlog_entries.size() > BacklogPanel.MAX_ENTRIES:
		_backlog_entries.remove_at(0)


func _on_choices(options: Array) -> void:
	_stop_auto_features()
	# 选项也要留一份快照 —— 否则玩家选完就没法回退到「选项摊在面前」的状态
	# 重新选。此处 runner 停在等选项上，ip 指向 choice 指令，还原会自动重弹选项。
	if _may_record_history():
		_rollback.push(_make_snapshot("choice"))
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
	_stop_auto_features()
	choices.dismiss()

	if not ending_id.is_empty():
		GameManager.set_flag("ending_%s" % ending_id)
		# 计入结局收藏。id 必须全局唯一 —— 两个结局用同一个 id 会互相覆盖。
		CollectionManager.unlock("endings", ending_id)
		RouteTracker.save_now()

	var message := I18n.t("—— 完 ——")
	if not ending_title.is_empty():
		message = I18n.t("结局：{title}", {"title": ending_title})
	elif not ending_id.is_empty():
		message = I18n.t("结局：{title}", {"title": ending_id})
	message += "\n" + I18n.t("（点击任意位置返回标题）")
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
# 回滚（滚轮前后翻历史）
# ---------------------------------------------------------------------------

## 此刻是否该记一份回滚快照。
##
## 两种情况要挡住：
##   · _restoring —— 还原过程中 runner 会重放指令，不挡就会记下重复项；
##   · _replay_active —— CG 重播放的是一段「不属于玩家进度」的插叙，
##     混进历史后玩家回退会退到一段他其实没走到的剧情里。
func _may_record_history() -> bool:
	return not _restoring and not _replay_active and runner != null


func _wheel_rollback_enabled() -> bool:
	return bool(ConfigManager.get_value("rollback_wheel", true))


## 采集一份「当前这一句」的完整快照。
##
## 三类状态缺一不可：调度器位置（file / ip / call_stack）、软状态
## （旗标 / 好感度 / 变量）、画面（背景 / 立绘 / CG / 天气）。
## 回看记录只存长度 —— 整份存进去太占地方，还原时把尾巴截掉即可。
func _make_snapshot(kind: String) -> Dictionary:
	return {
		"kind": kind,
		"runner": runner.get_state(),
		"game": GameManager.to_dict(),
		"stage": stage.get_state(),
		# 此刻正显示的那一句（选项快照里它就是「选项背后那句对白」）
		"speaker": _last_speaker,
		"text": _last_text,
		"voice": _line_voice,
		# 含这一句的长度；回滚时截回这个数，这一句恰好还在
		"backlog_size": _backlog_entries.size(),
		# 全屏特效单独带一份。它不在 stage.get_state() 里 —— 那是存档也要用的
		# 形状，而特效是瞬时状态、不该跟着存档走（读档不该进来就糊着）。
		# 但它必须进**回滚**快照：否则往回翻一句，一个十行前设的持续特效
		# 就被抹掉了，玩家会以为是自己看错了。
		"fx": {"kind": screen_fx.get_kind(), "strength": screen_fx.get_strength()},
	}


## 沿历史前 / 后移动一格。direction < 0 回退、> 0 前进。
## 返回是否真的动了 —— 撞到缓冲区两端就什么都不做。
func _rollback_step(direction: int) -> bool:
	if runner == null or title.visible or _replay_active:
		return false
	# 小游戏进行中翻历史会把小游戏节点和进度指针弄乱，直接拒绝
	if runner.is_waiting_minigame():
		return false
	var snapshot: Dictionary = _rollback.back() if direction < 0 else _rollback.forward()
	if snapshot.is_empty():
		return false
	_apply_snapshot(snapshot)
	return true


## 把一份快照还原成「这一句正在显示」的样子。
##
## 走的是和读档完全相同的路径：restore_state() 让调度器重新执行那条指令，
## 对白 / 选项于是自己重新出现 —— 这里不用再去区分快照是 say 还是 choice。
func _apply_snapshot(snapshot: Dictionary) -> void:
	_stop_auto_features()

	GameManager.from_dict(snapshot.get("game", {}))
	stage.restore_state(snapshot.get("stage", {}))
	# 特效直接落到快照那一刻的状态，不做淡入 —— 回滚是「回到那一刻」，
	# 那一刻它本来就是完全体，再播一遍过渡反而是错的。
	var fx: Dictionary = snapshot.get("fx", {})
	screen_fx.restore_fx(String(fx.get("kind", ScreenFxSpec.OFF)),
		float(fx.get("strength", 0.0)))

	# 回看记录截回那一句。快照存的是「含这一句」的长度，所以这一句保留、
	# 它之后的全部丢掉。
	var keep := int(snapshot.get("backlog_size", 0))
	while _backlog_entries.size() > keep:
		_backlog_entries.pop_back()

	_last_speaker = String(snapshot.get("speaker", ""))
	_last_text = String(snapshot.get("text", ""))
	_line_voice = String(snapshot.get("voice", ""))
	_pending_voice = ""

	# 挡住这次还原引发的重放，别把快照重复记进去
	_restoring = true
	var ok := runner.restore_state(snapshot.get("runner", {}))
	_restoring = false

	if not ok:
		# 剧本被删 / 改坏 —— 与其让指针悬在一个不存在的剧本上，不如退回标题
		push_warning("[Rollback] 还原失败，返回标题")
		_rollback.clear()
		_back_to_title()
		return

	# restore_state() 只有撞上 say 才会重新弹对白；停在选项上时这里补回
	# 那句上下文，玩家才看得懂自己在选什么。
	if not runner.is_waiting_say() and not _last_text.is_empty():
		dialogue.show_line(_last_speaker, _last_text)
	# 还原到对白时，把可能残留的选项面板收起来 ——
	# 从「选项格」退回「对白格」时它不会自己消失，会一直挡在前面。
	if not runner.is_waiting_choice():
		choices.dismiss()
	# 回滚是「重看已经发生过的东西」，再走一遍打字机只会让人干等 —— 直接给全。
	dialogue.complete_typing()


## 调试控制台 / 测试用：清空回滚历史。
func clear_rollback_history() -> void:
	_rollback.clear()


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
	_stop_auto_features()

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
	# 重播是插叙，不是玩家进度的一部分 —— 历史清掉，免得混进正片
	_rollback.clear()
	_stop_auto_features()
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
	_restore_session(
		_replay_snapshot.get("game", {}),
		_replay_snapshot.get("stage", {}),
		_replay_snapshot.get("backlog", []),
		String(_replay_snapshot.get("last_speaker", "")),
		String(_replay_snapshot.get("last_text", "")))
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
	# 回到标题也是一次「跳到别处」。不清的话，一个 duration<=0 的持续特效
	# 会一直糊在标题界面上，看起来像游戏坏了。
	screen_fx.clear()


func _back_to_title() -> void:
	runner.stop()
	_stop_auto_features()
	_replay_active = false
	_replay_snapshot = {}
	_autosave_enabled = true
	# 语音 / 排队中的语音都要断掉，否则回到标题后还在念上一句
	AudioManager.stop_voice()
	_rollback.clear()
	GameManager.tracking = false
	_clear_minigame()
	_show_title()


func _on_start_requested(file: String = "", label: String = "") -> void:
	GameManager.reset_run()
	stage.clear()
	screen_fx.clear()
	_backlog_entries.clear()
	_rollback.clear()
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
	var target := file if not file.is_empty() else ScriptPaths.entry()
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


## 存档被删掉 / 覆盖后，标题界面的「继续游戏」「读取存档」要跟着变灰或变亮。
## 这两个按钮的状态原本只在回标题时算一次，删档后就对不上了。
func _on_slots_changed() -> void:
	title.set_save_available(SaveManager.newest_slot() >= 0)


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


## 从一份会话数据恢复「软状态 + 画面 + 回看记录 + 最后一句」。
##
## 读档（数据来自存档文件）与重播结束（数据来自内存快照）做的是同一件事，
## 只是来源不同 —— 之前两边各抄了一遍，改一处漏一处就会出现
## 「读档能恢复、重播结束却丢了回看记录」这种只在一半路径上出现的问题。
func _restore_session(game: Dictionary, stage_state: Dictionary, backlog: Array,
		speaker: String, text: String) -> void:
	GameManager.from_dict(game)
	stage.restore_state(stage_state)
	# 全屏特效是瞬时状态，不跟着存档走 —— 读档进来时屏幕上不该还糊着
	# 存档那一刻的错乱。重播结束同理：插叙放完回正片，别把特效留在屏幕上。
	screen_fx.clear()
	_backlog_entries = _sanitize_backlog(backlog)
	_last_speaker = speaker
	_last_text = text


## 回看记录可能来自 JSON（读档）或内存快照，统一过一遍「是不是字典」的筛选。
## 混进非字典元素不会立刻报错，但会在回看面板里变成一条空白行。
static func _sanitize_backlog(raw: Array) -> Array:
	var out: Array = []
	for entry in raw:
		if typeof(entry) == TYPE_DICTIONARY:
			out.append(entry)
	return out


func _load_slot(slot: int) -> void:
	var data := SaveManager.read_slot(slot)
	if data.is_empty():
		return

	_stop_auto_features()
	# 读档是一次「跳到别处」——旧的回滚历史全部作废，留着会让滚轮翻到
	# 读档之前的进度之外
	_rollback.clear()

	_restore_session(
		data.get("game", {}),
		data.get("stage", {}),
		data.get("backlog", []),
		String(data.get("speaker", "")),
		String(data.get("preview", "")))

	title.visible = false
	hud.visible = true
	_close_modals()
	choices.dismiss()

	# 用 _restoring 包住还原：调度器会重放该指令，不挡的话它会往刚恢复的
	# 回看记录里再塞一条重复对白，也会往刚清空的回滚历史里塞一格。
	_restoring = true
	var restored := runner.restore_state(data.get("runner", {}))
	_restoring = false
	if not restored:
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


## 切换语言：静态文案靠节点上记的原文重新查表，动态面板重建一次，
## 让「存档 3」「已读 12 / 89 句」这类代码拼出来的文字也跟着换。
func _on_language_changed(_lang: String) -> void:
	I18n.apply_tree(ui_layer)
	settings.rebuild()
	if save_load != null and save_load.visible:
		save_load.refresh()
	if records != null and records.visible:
		records.present()
	_refresh_toggle_buttons()


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


## 关掉自动播放与快速跳过，并刷新 HUD 上那两个开关按钮的文字。
##
## 有七八处地方需要「停下来」：遇到选项、进小游戏、读档、回滚、回标题、进出重播……
## 每处手抄这三行，漏一次就会出现「按钮显示开着、其实早就停了」这种对不上的状态。
func _stop_auto_features() -> void:
	_auto_mode = false
	_skip_mode = false
	_refresh_toggle_buttons()


func _refresh_toggle_buttons() -> void:
	# 「开」不再写进文字（旧的「自动（开）」后缀），改用变色反馈：
	# 激活时按钮呈按下锁定态（pressed 贴图 + 深色字）。
	# 文案恒为「自动」/「跳过」，仍走 set_text 记下 i18n key。
	I18n.set_text(_btn_auto, "自动")
	I18n.set_text(_btn_skip, "跳过")
	UiTheme.apply_toggled_look(_btn_auto, "hud", _auto_mode)
	UiTheme.apply_toggled_look(_btn_skip, "hud", _skip_mode)


func _style_hud() -> void:
	for child in hud.get_children():
		var btn := child as Button
		if btn == null:
			continue
		btn.focus_mode = Control.FOCUS_NONE
		UiTheme.apply_button(btn, "hud")
