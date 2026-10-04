extends Control

## 内嵌演出预览
##
## 复用游戏自己的 `Stage` + `ScreenFx` + `ScriptRunner`，不重写渲染。
## 三个关键点：
##
## 1. **不加载 main.tscn**。`ScriptRunner` 是纯信号驱动的，`main.gd` 的职责
##    只是把 `stage_command` 转发给 `Stage`。这里写一份精简转发即可 ——
##    省掉整套 UI（对话框 / HUD / 存读档 / 鉴赏），预览只需要画面。
##
## 2. **尺寸靠 `size_2d_override`**。`Stage` 的坐标是硬编码的 1920×1080 设计分辨率，
##    所以 SubViewport 必须按 1920×1080 布局；把它交给 `size_2d_override`
##    （而不是 `size`），引擎就会把画面缩放到小窗里显示，且不变形。
##
## 3. **不接音频**。`audio_command` 不连接 —— 编辑器里反复预览时音乐响起很吵，
##    而且会与真实的音频状态互相干扰。

const EdTheme = preload("res://tools/editor/ed_theme.gd")
const StageScript = preload("res://scripts/stage/stage.gd")
const ScreenFxScript = preload("res://scripts/stage/screen_fx.gd")
const ScriptRunnerScript = preload("res://scripts/core/script_runner.gd")
const ScreenFxSpec = preload("res://scripts/core/screen_fx_spec.gd")
const LineIndex = preload("res://tools/editor/core/line_index.gd")
const TypingTimeline = preload("res://scripts/core/typing_timeline.gd")

const DESIGN := Vector2i(1920, 1080)

var _ed: Control

var _vp_container: SubViewportContainer
var _vp: SubViewport
var _stage: Control
var _fx: ColorRect
var _runner: Node

var _dlg_box: PanelContainer
var _dlg_name: Label
var _dlg_text: RichTextLabel
var _choice_wrap: Control
var _choice_list: VBoxContainer

var _status: Label
var _state_box: VBoxContainer
var _btn_run: Button
var _ar: AspectRatioContainer
var _chip_follow: Button

## 跟随光标：光标移到哪一行，预览就摆出「执行到那一行」的画面。
##
## GVS 的状态是累积的（`bg classroom` 之后一直有效），所以「第 N 行画面长什么样」
## 是可以直接算出来的（`ScriptDoc.line_state`）—— 不必点 ▶ 从头播一遍。
## 改一行就要重播一次的话，调演出基本没法用。
var _follow := true

var _running := false


func setup(ed: Control) -> void:
	_ed = ed
	_build()


# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------

func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# --- 头部 ---
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	root.add_child(head)

	_status = EdTheme.label("未开始", EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	head.add_child(_status)
	head.add_child(EdTheme.hfill())

	_btn_run = EdTheme.chip("▶ 从此处预览")
	_btn_run.pressed.connect(func() -> void: run_from_caret())
	head.add_child(_btn_run)

	_chip_follow = EdTheme.chip("跟随光标", _follow)
	_chip_follow.toggle_mode = true
	_chip_follow.button_pressed = _follow
	_chip_follow.tooltip_text = "光标移到哪一行，预览就显示执行到那一行的画面（不用点 ▶ 从头播）"
	_chip_follow.toggled.connect(_on_follow_toggled)
	head.add_child(_chip_follow)

	var btn_stop := EdTheme.chip("■")
	btn_stop.tooltip_text = "停止预览"
	btn_stop.pressed.connect(stop)
	head.add_child(btn_stop)

	# --- 画面 ---
	#
	# ⚠️ 两条一起才成立，缺一条就是「预览太小 / 拖分隔条不变大」：
	#
	#   1. **纵向不能 EXPAND_FILL**。`AspectRatioContainer` 的 STRETCH_FIT 是
	#      「装得进就装」——容器被撑到 660 高时，16:9 的画面只占中间一条，
	#      上下各留 200px 黑边；而高度锁死（custom_minimum_size 固定）时，
	#      横向再宽也只能缩着不动（超过 330px 就白给）。
	#   2. **高度要按宽度算**（`_sync_preview_height`）。把容器的最小高度设成
	#      `宽 × 9/16`，容器本身就正好是 16:9 —— 于是画面随分隔条同步放大，
	#      多出来的纵向空间全部让给下面的状态区。
	var ar := AspectRatioContainer.new()
	_ar = ar
	ar.ratio = 16.0 / 9.0
	ar.stretch_mode = AspectRatioContainer.STRETCH_FIT
	ar.alignment_horizontal = AspectRatioContainer.ALIGNMENT_CENTER
	ar.alignment_vertical = AspectRatioContainer.ALIGNMENT_CENTER
	ar.custom_minimum_size = Vector2(0, 200)
	ar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(ar)
	ar.resized.connect(_sync_preview_height)
	resized.connect(_sync_preview_height)

	_vp_container = SubViewportContainer.new()
	_vp_container.stretch = true
	_vp_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_vp_container.gui_input.connect(_on_view_input)
	ar.add_child(_vp_container)

	_vp = SubViewport.new()
	_vp.size_2d_override = DESIGN
	_vp.size_2d_override_stretch = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	_vp_container.add_child(_vp)

	# 底色（没有背景素材时也不至于全黑一片看不出边界）
	var backdrop := ColorRect.new()
	backdrop.color = Color("#101014")
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vp.add_child(backdrop)

	_stage = StageScript.new()
	_stage.name = "Stage"
	_vp.add_child(_stage)

	_fx = ColorRect.new()
	_fx.name = "ScreenFx"
	_fx.set_script(ScreenFxScript)
	_fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx.color = Color(1, 1, 1, 0)
	_vp.add_child(_fx)

	_build_dialogue()

	# --- 选项层（在 SubViewport 里，居中）---
	_choice_wrap = Control.new()
	_choice_wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	_choice_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_choice_wrap.visible = false
	_vp.add_child(_choice_wrap)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_choice_wrap.add_child(center)

	_choice_list = VBoxContainer.new()
	_choice_list.add_theme_constant_override("separation", 18)
	center.add_child(_choice_list)

	# --- 当前行状态 ---
	#
	# 装进定高的 ScrollContainer：立绘多的时候这一块会长到十几行。
	# 它拿的是纵向剩余空间（EXPAND_FILL）—— 画面区按 16:9 精确占位之后，
	# 多出来的高度都给这里，而不是留成画面上下两片黑边。
	root.add_child(EdTheme.hline())
	var state_scroll := ScrollContainer.new()
	state_scroll.custom_minimum_size = Vector2(0, 118)
	state_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	state_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(state_scroll)

	_state_box = VBoxContainer.new()
	_state_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_state_box.add_theme_constant_override("separation", 2)
	state_scroll.add_child(_state_box)

	# --- 驱动器 ---
	_runner = ScriptRunnerScript.new()
	_runner.name = "ScriptRunner"
	add_child(_runner)
	_runner.stage_command.connect(_on_stage_command)
	_runner.say.connect(_on_say)
	_runner.choices.connect(_on_choices)
	_runner.choice_made.connect(_on_choice_made)
	_runner.script_ended.connect(_on_script_ended)
	_runner.minigame_requested.connect(_on_minigame_requested)


## 让 16:9 的画面区按「宽度」算高度，而不是在整栏里上下留一大片黑边。
##
## 右栏又窄又高（430 × 660），16:9 的画面只占 430×242，剩下 400+px 全是空白。
## 把容器的最小高度设成 `宽 × 9/16`，容器本身正好是 16:9，画面就贴着工具栏放，
## 多出来的纵向空间交给下面的状态区（它才是该被撑开的那一个）。
##
## ⚠️ 幂等很重要：`resized` 会在设置最小高度后**再次**触发，
## 但 `Control.set_custom_minimum_size` 对相同值会提前返回，所以不会来回抖。
func _sync_preview_height() -> void:
	if _ar == null:
		return
	var w := _ar.size.x
	if w <= 1.0:
		return
	# 给头部与状态区留出位置，别把状态区挤没
	var cap := maxf(150.0, size.y - 210.0)
	_ar.custom_minimum_size = Vector2(0, clampf(w * 9.0 / 16.0, 150.0, cap))


func _build_dialogue() -> void:
	_dlg_box = PanelContainer.new()
	_dlg_box.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_dlg_box.anchor_top = 1.0
	_dlg_box.offset_left = 150.0
	_dlg_box.offset_right = -150.0
	_dlg_box.offset_top = -300.0
	_dlg_box.offset_bottom = -80.0
	_dlg_box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.09, 0.12, 0.90)
	sb.corner_radius_top_left = 12
	sb.corner_radius_top_right = 12
	sb.corner_radius_bottom_left = 12
	sb.corner_radius_bottom_right = 12
	sb.content_margin_left = 34
	sb.content_margin_right = 34
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(1, 1, 1, 0.12)
	_dlg_box.add_theme_stylebox_override("panel", sb)
	_vp.add_child(_dlg_box)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	_dlg_box.add_child(vb)

	_dlg_name = Label.new()
	_dlg_name.add_theme_font_override("font", EdTheme.ui())
	_dlg_name.add_theme_font_size_override("font_size", 30)
	_dlg_name.add_theme_color_override("font_color", Color("#f0a190"))
	vb.add_child(_dlg_name)

	_dlg_text = RichTextLabel.new()
	_dlg_text.bbcode_enabled = true
	_dlg_text.scroll_active = false
	_dlg_text.fit_content = true
	_dlg_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dlg_text.add_theme_font_override("normal_font", EdTheme.ui())
	_dlg_text.add_theme_font_size_override("normal_font_size", 32)
	_dlg_text.add_theme_color_override("default_color", Color("#efe7e0"))
	# ⚠️ **必须登记自定义特效**，否则 `[bounce]` / `[blink]` / `[glitch]` 会因为
	# 「未知标签」**连方括号一起漏成正文**（用户报的「有些文本特效没有在预览窗口实现」）。
	# 登记的是和对白框 / 回看同一份实例（`TextEffects.all()`），不会各漏各的。
	# 内置的 [shake] / [wave] / [rainbow] / [fade] / [pulse] 不用管，直接可用。
	_dlg_text.custom_effects = TextEffects.all()
	vb.add_child(_dlg_text)

	_dlg_box.visible = false


# ---------------------------------------------------------------------------
# 运行
# ---------------------------------------------------------------------------

## 从光标所在的那一行开始播
func run_from_caret() -> void:
	if _ed == null or _ed.doc == null:
		return
	# `caret_line` 是 editor 的**属性**，不是方法 —— 写成 caret_line() 会在
	# 运行时抛 "Nonexistent function"，而且是 untyped 调用，编译期查不出来。
	var no: int = _ed.caret_line
	run_from(no)


## 从第 no 行开始播。
##
## 两步，缺一不可：
##
##   ① **先把「执行到上一行为止」的累积画面摆好。**
##      GVS 的状态是累积的（`bg classroom` 之后一直有效），从中间某行开始时，
##      前面设过的背景 / 立绘都不在——不管的话画面就是黑的
##      （用户报的「有时候无法正常显示背景」）。
##   ② **从这一行对应的指令开始跑。**
##      以前只能「从最近的标签开始」，于是点第 60 行却从第 20 行的标签重播一遍，
##      中间那些台词、演出全部又走一次。靠 `GvsParser` 给每条指令盖的 `line` 键，
##      `start_at_line()` 能精确落到那一行（落在注释 / 空行上会自动往后顺延）。
##
## 只有「这一行之后一条可执行指令都没有」（文件末尾的空白行）时才不跑，
## 并在状态里说清楚 —— **不悄悄退回按标签重播**，那正是用户抱怨的行为。
func run_from(no: int) -> void:
	var doc = _ed.doc
	_reset_scene()

	# 从**内存**编译，不是从磁盘 —— 手动保存模式下可能有未保存改动，
	# 而且行号必须与编辑器看到的一致，否则 ② 会落到别处。
	if not _runner.load_text(doc.to_text(), doc.path):
		_status.text = "剧本解析失败，看下方问题列表"
		_status.add_theme_color_override("font_color", EdTheme.ERR)
		return

	# ① 累积画面：第 no 行执行**之前**的状态 = 执行完第 no-1 行之后的状态
	_restore_stage(doc.line_state(maxi(1, no - 1)))

	# ② 精确落到那一行
	_running = true
	_status.text = "运行中 · 从第 %d 行开始" % no
	_status.add_theme_color_override("font_color", EdTheme.OK)
	if not _runner.start_at_line(no):
		_running = false
		_status.text = "第 %d 行之后没有可执行的指令" % no
		_status.add_theme_color_override("font_color", EdTheme.WARN)


func stop() -> void:
	_running = false
	_runner.stop()
	_dlg_box.visible = false
	_choice_wrap.visible = false
	_status.text = "已停止"
	_status.add_theme_color_override("font_color", EdTheme.TEXT_FAINT)
	# 停播之后把画面交还给「跟随光标」，不然会一直停在播放到的那一帧
	if _follow and _ed != null:
		show_line_state(_ed.caret_line)


func is_running() -> bool:
	return _running


func _reset_scene() -> void:
	_stage.clear()
	_fx.clear()
	_dlg_box.visible = false
	_choice_wrap.visible = false
	_clear_choices()


func advance() -> void:
	if not _running:
		return
	if _runner.is_waiting_choice() or _runner.is_waiting_minigame():
		return
	_runner.advance()


func _on_view_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if not _choice_wrap.visible:
				advance()
				accept_event()


# ---------------------------------------------------------------------------
# 指令转发（精简版 main.gd._on_stage_command）
# ---------------------------------------------------------------------------

func _on_stage_command(cmd: Dictionary) -> void:
	match String(cmd.get("op", "")):
		"bg":
			_stage.set_bg(String(cmd.get("id", "")),
				String(cmd.get("transition", "fade")), float(cmd.get("duration", 0.4)))
		"show":
			_stage.show_char(String(cmd.get("char", "")), String(cmd.get("expr", "normal")),
				String(cmd.get("at", "center")), String(cmd.get("transition", "fade")),
				float(cmd.get("duration", 0.3)), _char_opts(cmd))
		"hide":
			_stage.hide_char(String(cmd.get("char", "")),
				String(cmd.get("transition", "fade")), float(cmd.get("duration", 0.3)))
		"move":
			_stage.move_char(String(cmd.get("char", "")), String(cmd.get("at", "")),
				float(cmd.get("duration", 0.35)), String(cmd.get("ease", "out_cubic")),
				_char_opts(cmd))
		"hop":
			_stage.char_jump(String(cmd.get("char", "")), float(cmd.get("height", 40.0)),
				int(cmd.get("times", 2)), float(cmd.get("duration", 0.7)))
		"zoom":
			_stage.char_zoom(String(cmd.get("char", "")), float(cmd.get("scale", 1.0)),
				float(cmd.get("duration", 0.4)), String(cmd.get("ease", "out_back")))
		"shake":
			_stage.char_shake(String(cmd.get("char", "")), float(cmd.get("strength", 28.0)),
				int(cmd.get("times", 5)), float(cmd.get("duration", 0.45)))
		"screen_shake":
			_stage.screen_shake(float(cmd.get("strength", 36.0)),
				int(cmd.get("times", 5)), float(cmd.get("duration", 0.45)))
		"screen_flash":
			_stage.screen_flash(Color.from_string(String(cmd.get("color", "#ffffff")), Color.WHITE),
				float(cmd.get("duration", 0.25)))
		"bg_motion":
			_stage.bg_motion(float(cmd.get("scale", 1.0)),
				Vector2(float(cmd.get("x", 0.0)), float(cmd.get("y", 0.0))),
				float(cmd.get("duration", 6.0)), String(cmd.get("ease", "in_out_cubic")))
		"weather":
			_stage.set_weather(String(cmd.get("kind", "none")), float(cmd.get("intensity", 1.0)))
		"expr":
			_stage.set_expr(String(cmd.get("char", "")), String(cmd.get("expr", "normal")),
				float(cmd.get("duration", 0.18)))
		"cg":
			_stage.show_cg(String(cmd.get("id", "")), float(cmd.get("fade", 0.5)),
				String(cmd.get("transition", "fade")))
		"hide_cg":
			_stage.hide_cg(float(cmd.get("fade", 0.4)), String(cmd.get("transition", "fade")))
		"screen_fx":
			_fx.play(String(cmd.get("kind", "none")), float(cmd.get("strength", 1.0)),
				float(cmd.get("duration", 1.0)))
		"anim":
			_stage.set_char_anim(String(cmd.get("char", "")), float(cmd.get("speed", 1.0)),
				bool(cmd.get("pause", false)), bool(cmd.get("once", false)),
				int(cmd.get("frame", -1)))
		"video":
			# 编辑器预览不播视频。这里不接 VideoScreen，但必须**主动告诉调度器
			# 「播完了」** —— 带 wait=true 的视频会让它停在 WAITING_VIDEO
			# 等一个永远不会来的 finished 信号，表现为预览点不动。
			_status.text = "（视频 %s 已被预览跳过）" % String(cmd.get("id", ""))
			_runner.call_deferred("submit_video_finished")
		"hide_video":
			pass
		"clear":
			_stage.clear()
			_fx.clear()


## 只在指令真的带了这三个参数时才放进字典 —— Stage 靠「键在不在」
## 区分「覆盖」与「不覆盖」，塞默认值会把预设定位搞乱
func _char_opts(cmd: Dictionary) -> Dictionary:
	var opts := {}
	for key in ["x", "y", "scale"]:
		if cmd.has(key):
			opts[key] = cmd[key]
	return opts


# ---------------------------------------------------------------------------
# 对白与选项
# ---------------------------------------------------------------------------

func _on_say(speaker: String, text: String, _expr: String) -> void:
	_status.text = "点击画面继续"
	_status.add_theme_color_override("font_color", EdTheme.TEXT_FAINT)
	_dlg_box.visible = true
	_dlg_name.text = speaker
	_dlg_name.visible = not speaker.is_empty()
	# 剥掉节奏标记（`[wait=0.7]` / `[speed=3]`）—— 那些是给打字机用的，
	# 预览里没有打字机，留着会原样显示成方括号。文字特效（`[bounce]` 等）保留，
	# 由 `_dlg_text.custom_effects` 渲染成真效果。
	_dlg_text.text = TypingTimeline.strip(text)


## 编辑器里不跑小游戏 —— 直接按「成功」提交，让剧情继续往下走。
##
## **不处理的话调度器会停在 WAITING_MINIGAME 永远等下去**，表现为预览
## 「点不动了」，而且不报任何错、界面也没有提示 —— 用户只会觉得卡死。
func _on_minigame_requested(id: String, _params: Dictionary) -> void:
	_status.text = "小游戏 %s 已被预览跳过" % id
	_status.add_theme_color_override("font_color", EdTheme.WARN)
	# 用 call_deferred：不要在信号回调里同步改调度器状态，
	# 那是从它自己的 _step() 里发出来的，同步改会重入
	_runner.call_deferred("submit_minigame", {"success": true, "score": 0, "max": 0})


func _on_choices(options: Array) -> void:
	_status.text = "等待选择…"
	_status.add_theme_color_override("font_color", EdTheme.WARN)
	_clear_choices()
	_choice_wrap.visible = true
	for i in options.size():
		var opt: Dictionary = options[i]
		var b := Button.new()
		b.text = String(opt.get("text", ""))
		b.custom_minimum_size = Vector2(760, 72)
		b.add_theme_font_override("font", EdTheme.ui())
		b.add_theme_font_size_override("font_size", 30)
		b.add_theme_color_override("font_color", Color("#efe7e0"))
		b.add_theme_color_override("font_hover_color", Color.WHITE)
		b.add_theme_stylebox_override("normal", _choice_box(Color(0.10, 0.09, 0.12, 0.90)))
		b.add_theme_stylebox_override("hover", _choice_box(Color("#e0836c")))
		b.add_theme_stylebox_override("pressed", _choice_box(Color("#c96a55")))
		var idx := i
		b.pressed.connect(func() -> void: _runner.submit_choice(idx))
		_choice_list.add_child(b)


static func _choice_box(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(1, 1, 1, 0.16)
	return sb


func _clear_choices() -> void:
	for c in _choice_list.get_children():
		c.queue_free()


func _on_choice_made(_index: int, _text: String) -> void:
	_choice_wrap.visible = false
	_clear_choices()
	_status.text = "运行中"
	_status.add_theme_color_override("font_color", EdTheme.OK)


func _on_script_ended(ending_id: String, title: String) -> void:
	_running = false
	_choice_wrap.visible = false
	_dlg_box.visible = false
	_status.text = "已到结局：%s" % (title if not title.is_empty() else ending_id)
	_status.add_theme_color_override("font_color", EdTheme.ACCENT)


# ---------------------------------------------------------------------------
# 状态显示
# ---------------------------------------------------------------------------

## 由主控在光标移动时调用
func show_line_state(no: int) -> void:
	for c in _state_box.get_children():
		c.queue_free()
	if _ed == null or _ed.doc == null:
		return

	var st: Dictionary = _ed.doc.line_state(no)
	if st.is_empty():
		return

	# 跟随光标：把这一行的累积状态直接摆到画面上。
	# 正在播放时不抢 —— 那是调度器在驱动 Stage，跟着光标改会把播放搅乱。
	if _follow and not _running:
		_apply_follow(st, no)

	_state_box.add_child(EdTheme.label("第 %d 行状态" % no, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))

	var bg := String(st.get("bg", ""))
	if not bg.is_empty():
		_state_box.add_child(_state_row("背景", bg))
	var bgm := String(st.get("bgm", ""))
	if not bgm.is_empty():
		_state_box.add_child(_state_row("音乐", bgm))
	var weather := String(st.get("weather", ""))
	if not weather.is_empty() and weather != "none":
		_state_box.add_child(_state_row("天气", weather))
	var cg := String(st.get("cg", ""))
	if not cg.is_empty():
		_state_box.add_child(_state_row("CG", cg))

	var chars: Array = st.get("chars", [])
	if chars.is_empty():
		_state_box.add_child(EdTheme.label("立绘　（无）", EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))
	else:
		for c in chars:
			var ch: Dictionary = c
			var pos := String(ch.get("at", "center"))
			if ch.has("x") or ch.has("y"):
				pos = "x=%s y=%s" % [_fmt(ch.get("x", 0)), _fmt(ch.get("y", 0))]
			_state_box.add_child(_state_row(String(ch.get("id", "")),
				"%s · %s" % [String(ch.get("expr", "normal")), pos]))


static func _fmt(v: Variant) -> String:
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return "%d" % int(round(float(v)))
	return String(v)


# ---------------------------------------------------------------------------
# 跟随光标
# ---------------------------------------------------------------------------

func _on_follow_toggled(on: bool) -> void:
	_follow = on
	EdTheme.style_chip(_chip_follow, on)
	if on and _ed != null:
		show_line_state(_ed.caret_line)


## 把一份「累积舞台状态」摆到 Stage 上（不跑脚本）。
##
## 直接复用 `Stage.restore_state` —— 它本来就是给读档用的「一次性摆好画面」，
## 语义完全一致（转场一律 "none"、时长为 0，不做动画）。
## 唯一要转换的是字段名：`line_state` 用 `id`，`restore_state` 用 `char`。
func _restore_stage(st: Dictionary) -> void:
	var chars: Array = []
	for c in st.get("chars", []):
		var ch: Dictionary = c
		var item := {
			"char": String(ch.get("id", "")),
			"expr": String(ch.get("expr", "normal")),
			"at": String(ch.get("at", "center")),
		}
		for k in ["x", "y", "scale"]:
			if ch.has(k):
				item[k] = ch[k]
		chars.append(item)

	_stage.restore_state({
		"bg": String(st.get("bg", "")),
		"cg": String(st.get("cg", "")),
		"chars": chars,
		"weather": String(st.get("weather", "")),
	})
	_fx.clear()


## 跟随光标：摆好画面，并把光标那一行的对白也显示出来。
func _apply_follow(st: Dictionary, no: int) -> void:
	_restore_stage(st)

	# 光标那一行本身是对白的话，把对话框也摆出来 —— 否则「跟随」只跟了一半
	var line := _ed.doc.line_at(no) as LineIndex.Line
	if line != null and line.is_say():
		_dlg_name.text = line.speaker
		_dlg_name.visible = not line.speaker.is_empty()
		_dlg_text.text = TypingTimeline.strip(line.text)
		_dlg_box.visible = true
	else:
		_dlg_box.visible = false
	_choice_wrap.visible = false

	_status.text = "跟随光标 · 第 %d 行" % no
	_status.add_theme_color_override("font_color", EdTheme.TEXT_FAINT)


func _state_row(key: String, value: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var k := EdTheme.label(key, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	k.custom_minimum_size = Vector2(46, 0)
	row.add_child(k)
	var v := EdTheme.label(value, EdTheme.FS_SMALL, EdTheme.TEXT_DIM)
	v.clip_text = true
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(v)
	return row
