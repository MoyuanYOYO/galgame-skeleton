class_name SaveLoadPanel
extends Control

## 存 / 读档面板
##
## 同一个面板两种模式：保存模式写槽位，读取模式读槽位。
## 槽位摘要由 SaveManager.get_slot_info() 提供，不需要解析整个存档。
##
## 写操作都要过一道确认 —— 存档是玩家几十小时的进度，
## 误点一下就没了，这是最不该图快的地方。

signal slot_chosen(slot: int)
## 槽位有增删改动（删除 / 覆盖）时发出，让标题界面刷新「继续游戏」的可用状态
signal slots_changed()

@onready var _title_label: Label = %SaveLoadTitle
@onready var _slot_list: VBoxContainer = %SlotList
@onready var _close_button: Button = %SaveLoadClose
@onready var _panel: PanelContainer = $Panel

var _load_mode: bool = false
var _confirm_layer: CenterContainer
var _confirm_label: Label
## 确认后要执行的动作。用 Callable 存起来，而不是给每种操作写一个 if 分支。
var _confirm_action: Callable = Callable()
## 槽位号 -> 那一行的主按钮。供「是否可点」查询与自动化测试。
var _slot_buttons: Dictionary = {}


func _ready() -> void:
	visible = false
	UiTheme.apply_panel(_panel, "default")
	UiTheme.apply_label(_title_label, UiTheme.TEXT, 30)
	UiTheme.apply_button(_close_button, "default")
	_close_button.pressed.connect(hide_panel)
	_build_confirm_layer()


func present(load_mode: bool) -> void:
	_load_mode = load_mode
	I18n.set_text(_title_label, "读取存档" if load_mode else "保存存档")
	refresh()
	visible = true


func hide_panel() -> void:
	visible = false
	_hide_confirm()


func is_load_mode() -> bool:
	return _load_mode


# ---------------------------------------------------------------------------
# 确认弹层
#
# 做在面板内部、盖住槽位列表，而不是弹一个独立窗口 ——
# 独立窗口要处理暂停与焦点回传，这里只是一句话 + 两个按钮。
# ---------------------------------------------------------------------------

func _build_confirm_layer() -> void:
	_confirm_layer = CenterContainer.new()
	_confirm_layer.name = "ConfirmLayer"
	_confirm_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	# STOP：确认层显示时要吃掉点击，别让底下的槽位按钮被顺手点到
	_confirm_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	_confirm_layer.visible = false
	add_child(_confirm_layer)

	var box := PanelContainer.new()
	UiTheme.apply_panel(box, "default")
	_confirm_layer.add_child(box)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 22)
	box.add_child(column)

	_confirm_label = Label.new()
	# 这行文字永远是「运行时拼好并翻译过的」，不能再被 apply_tree 按原文查一遍
	_confirm_label.set_meta(I18n.META_SKIP, true)
	_confirm_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_confirm_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_confirm_label.custom_minimum_size = Vector2(520.0, 0.0)
	UiTheme.apply_label(_confirm_label, UiTheme.TEXT, 24)
	column.add_child(_confirm_label)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 26)
	column.add_child(row)

	var yes := Button.new()
	I18n.set_text(yes, "确定")
	UiTheme.apply_button(yes, "default")
	yes.pressed.connect(confirm_accept)
	row.add_child(yes)

	var no := Button.new()
	I18n.set_text(no, "取消")
	UiTheme.apply_button(no, "default")
	no.pressed.connect(confirm_cancel)
	row.add_child(no)


## 弹一句确认。action 在玩家点「确定」后执行。
func ask_confirm(message: String, action: Callable) -> void:
	_confirm_label.text = message
	_confirm_action = action
	_confirm_layer.visible = true


func confirm_accept() -> void:
	var action := _confirm_action
	_hide_confirm()
	if action.is_valid():
		action.call()


func confirm_cancel() -> void:
	_hide_confirm()


func is_confirm_visible() -> bool:
	return _confirm_layer != null and _confirm_layer.visible


func get_confirm_text() -> String:
	return "" if _confirm_label == null else _confirm_label.text


func _hide_confirm() -> void:
	_confirm_action = Callable()
	if _confirm_layer != null:
		_confirm_layer.visible = false


# ---------------------------------------------------------------------------
# 槽位列表
# ---------------------------------------------------------------------------

## 槽位行：左侧缩略图 + 右侧文字，整行都是同一个按钮。
##
## 缩略图做成按钮的**子节点**并设 mouse_filter = IGNORE ——
## 这样点图片也能触发按钮，而且 hover / pressed 的高亮是整行一起亮。
## 用内容左边距（而不是空格填充）给图片让位，文字才不会跟图重叠。
const THUMB_W := 160.0
const THUMB_H := 90.0
const THUMB_MARGIN := 14.0
const ROW_HEIGHT := 104.0
const ROW_WIDTH := 880.0
const DELETE_W := 96.0


func refresh() -> void:
	_hide_confirm()
	_slot_buttons.clear()
	for child in _slot_list.get_children():
		_slot_list.remove_child(child)
		child.queue_free()

	for info in SaveManager.list_slots():
		_slot_list.add_child(_make_slot_row(info))


## 供自动化测试 / 调试：某一行的主按钮现在能不能点
func is_slot_enabled(slot: int) -> bool:
	var btn := _slot_buttons.get(slot) as Button
	return btn != null and not btn.disabled


## 一行 = [整行可点的槽位按钮] + [删除按钮]。
##
## 删除按钮**排在按钮外面**，而不是塞进按钮里当子节点 ——
## 按钮套按钮时内层点击很容易被外层吞掉，分开排最省心。
func _make_slot_row(info: Dictionary) -> HBoxContainer:
	var slot := int(info["slot"])
	var empty := bool(info["empty"])

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var btn := Button.new()
	# 文字交给子节点排（Button 自身的 text 多行对齐不可控），
	# 所以按钮只作为「整行可点」的容器 + 背景
	btn.text = ""
	# 读取模式下空槽不可点；保存模式下**自动存档槽不可点** ——
	# 它归系统管，手动写进去也会被下一句的自动存档冲掉，写它只会骗自己。
	btn.disabled = empty if _load_mode else (slot == SaveManager.AUTO_SLOT)
	btn.focus_mode = Control.FOCUS_ALL
	UiTheme.apply_button(btn, "small")
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(ROW_WIDTH, ROW_HEIGHT)

	var thumb := SaveManager.get_thumbnail(slot)
	if thumb != null:
		btn.add_child(_make_thumb(thumb))
	btn.add_child(_make_text_block(slot, info))

	btn.pressed.connect(_on_slot_pressed.bind(slot))
	_slot_buttons[slot] = btn
	row.add_child(btn)

	var del := Button.new()
	I18n.set_text(del, "删除")
	del.disabled = empty
	del.custom_minimum_size = Vector2(DELETE_W, ROW_HEIGHT)
	UiTheme.apply_button(del, "small")
	del.pressed.connect(_on_delete_pressed.bind(slot))
	row.add_child(del)
	return row


## 缩略图贴在左侧居中。用锚点而不是绝对坐标 ——
## 按钮的真实尺寸要等容器布局完才定，绝对坐标会错位。
static func _make_thumb(texture: Texture2D) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	rect.offset_left = THUMB_MARGIN
	rect.offset_right = THUMB_MARGIN + THUMB_W
	rect.offset_top = -THUMB_H * 0.5
	rect.offset_bottom = THUMB_H * 0.5
	return rect


## 右侧两行文字：第一行是槽位/章节/时间，第二行是台词摘要
static func _make_text_block(slot: int, info: Dictionary) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 4)
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = THUMB_W + THUMB_MARGIN * 2.0
	box.offset_right = -THUMB_MARGIN
	box.offset_top = 0.0
	box.offset_bottom = 0.0

	var lines := _slot_lines(slot, info)
	var primary := Label.new()
	# 这两行是「槽位名 + 台词预览」的混合体，已经各自翻译过了，
	# 不能再被 apply_tree 按原文翻一遍（否则切语言时会卡在旧译文上）
	primary.set_meta(I18n.META_SKIP, true)
	primary.text = String(lines[0])
	primary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiTheme.apply_label(primary, UiTheme.TEXT, 20)
	box.add_child(primary)

	var secondary := Label.new()
	secondary.set_meta(I18n.META_SKIP, true)
	secondary.text = String(lines[1])
	secondary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiTheme.apply_label(secondary, UiTheme.TEXT_DIM, 19)
	box.add_child(secondary)
	return box


# ---------------------------------------------------------------------------
# 交互
# ---------------------------------------------------------------------------

func _on_slot_pressed(slot: int) -> void:
	# 保存模式下点已占用的槽位 = 覆盖存档，先问一句
	if not _load_mode and SaveManager.slot_exists(slot):
		ask_confirm(I18n.t("覆盖存档 {slot}？原有进度将被替换，且无法恢复。",
			{"slot": _slot_name(slot)}),
			func() -> void: slot_chosen.emit(slot))
		return
	slot_chosen.emit(slot)


func _on_delete_pressed(slot: int) -> void:
	if not SaveManager.slot_exists(slot):
		return
	ask_confirm(I18n.t("删除存档 {slot}？此操作不可撤销。", {"slot": _slot_name(slot)}),
		func() -> void:
			SaveManager.delete_slot(slot)
			refresh()
			slots_changed.emit())


## 槽位显示名。自动存档槽（0）不叫「存档 0」。
static func _slot_name(slot: int) -> String:
	if slot == SaveManager.AUTO_SLOT:
		return I18n.t("自动存档")
	return I18n.t("存档 {n}", {"n": slot})


## 返回 [第一行, 第二行] —— 拆成两行是为了让字号和颜色能分别控制
static func _slot_lines(slot: int, info: Dictionary) -> PackedStringArray:
	# 槽位名 / 空槽提示是界面文案，走 I18n；章节名与台词预览是内容，不翻
	var slot_name := _slot_name(slot)
	if bool(info["empty"]):
		return PackedStringArray([slot_name, I18n.t("—— 空 ——")])

	var chapter := String(info["chapter_title"])
	if chapter.is_empty():
		chapter = I18n.t("未命名章节")

	# 预览是一行静态文字，而且控件是普通 Label（不解析 BBCode）——
	# 节奏标记和特效标记都会原样漏出来，所以这里比回看面板剥得更狠：
	# 用 _plain_preview() 把所有 [xxx] 标签一律丢掉。
	var preview := _plain_preview(String(info["preview"]))
	if preview.length() > 30:
		preview = preview.substr(0, 30) + "…"
	var speaker := String(info["speaker"])
	if not speaker.is_empty():
		preview = "%s：%s" % [speaker, preview]

	return PackedStringArray([
		"%s      %s   |   %s   |   %s" % [
			slot_name,
			chapter,
			String(info["saved_at"]),
			SaveManager.format_play_time(float(info["play_time"])),
		],
		preview,
	])


## 把文本里的 [xxx] 标记全部去掉。
##
## 存档预览是普通 Label，不解析 BBCode —— 不剥的话，玩家会在存档列表里
## 看到 `alice: 明天，[speed=2.5]要不要一起走？[/speed]` 这种东西。
## 回看面板能保留特效标记（那边是 RichTextLabel），这里不行。
static func _plain_preview(text: String) -> String:
	var out := ""
	var index := 0
	while index < text.length():
		if text[index] == "[":
			var close := text.find("]", index)
			if close > index:
				index = close + 1
				continue
		out += text[index]
		index += 1
	return out
