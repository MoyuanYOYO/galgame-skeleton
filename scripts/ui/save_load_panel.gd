class_name SaveLoadPanel
extends Control

## 存 / 读档面板
##
## 同一个面板两种模式：保存模式写槽位，读取模式读槽位。
## 槽位摘要由 SaveManager.get_slot_info() 提供，不需要解析整个存档。

signal slot_chosen(slot: int)

@onready var _title_label: Label = %SaveLoadTitle
@onready var _slot_list: VBoxContainer = %SlotList
@onready var _close_button: Button = %SaveLoadClose
@onready var _panel: PanelContainer = $Panel

var _load_mode: bool = false


func _ready() -> void:
	visible = false
	UiTheme.apply_panel(_panel, "default")
	UiTheme.apply_label(_title_label, UiTheme.TEXT, 30)
	UiTheme.apply_button(_close_button, "default")
	_close_button.pressed.connect(hide_panel)


func present(load_mode: bool) -> void:
	_load_mode = load_mode
	_title_label.text = "读取存档" if load_mode else "保存存档"
	refresh()
	visible = true


func hide_panel() -> void:
	visible = false


func is_load_mode() -> bool:
	return _load_mode


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


func refresh() -> void:
	for child in _slot_list.get_children():
		_slot_list.remove_child(child)
		child.queue_free()

	for info in SaveManager.list_slots():
		var slot := int(info["slot"])
		var empty := bool(info["empty"])

		var btn := Button.new()
		# 文字交给子节点排（Button 自身的 text 多行对齐不可控），
		# 所以按钮只作为「整行可点」的容器 + 背景
		btn.text = ""
		btn.disabled = _load_mode and empty
		btn.focus_mode = Control.FOCUS_ALL
		UiTheme.apply_button(btn, "small")
		btn.custom_minimum_size = Vector2(ROW_WIDTH, ROW_HEIGHT)

		var thumb := SaveManager.get_thumbnail(slot)
		if thumb != null:
			btn.add_child(_make_thumb(thumb))
		btn.add_child(_make_text_block(slot, info))

		btn.pressed.connect(_on_slot_pressed.bind(slot))
		_slot_list.add_child(btn)


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
	primary.text = String(lines[0])
	primary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiTheme.apply_label(primary, UiTheme.TEXT, 20)
	box.add_child(primary)

	var secondary := Label.new()
	secondary.text = String(lines[1])
	secondary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiTheme.apply_label(secondary, UiTheme.TEXT_DIM, 19)
	box.add_child(secondary)
	return box


func _on_slot_pressed(slot: int) -> void:
	slot_chosen.emit(slot)


## 返回 [第一行, 第二行] —— 拆成两行是为了让字号和颜色能分别控制
static func _slot_lines(slot: int, info: Dictionary) -> PackedStringArray:
	var slot_name := "自动存档" if slot == SaveManager.AUTO_SLOT else "存档 %d" % slot
	if bool(info["empty"]):
		return PackedStringArray([slot_name, "—— 空 ——"])

	var chapter := String(info["chapter_title"])
	if chapter.is_empty():
		chapter = "未命名章节"

	var preview := String(info["preview"])
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
