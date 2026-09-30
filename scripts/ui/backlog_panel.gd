class_name BacklogPanel
extends Control

## 回看面板
##
## 展示历史对白。条目用 RichTextLabel + BBCode 上色，
## 打开后自动滚到底部（最新一条）。

const MAX_ENTRIES := 300

@onready var _scroll: ScrollContainer = %BacklogScroll
@onready var _entries: VBoxContainer = %Entries
@onready var _close_button: Button = %BacklogClose
@onready var _panel: PanelContainer = $Panel


func _ready() -> void:
	visible = false
	UiTheme.apply_panel(_panel, "default")
	UiTheme.apply_button(_close_button, "default")
	_close_button.pressed.connect(hide_panel)


func present(entries: Array) -> void:
	_clear()
	var tail: Array = entries
	if tail.size() > MAX_ENTRIES:
		tail = tail.slice(tail.size() - MAX_ENTRIES)

	# 三个自定义特效都是无状态的（只有一个 bbcode 名字），
	# 所以整页共用一个实例就够，不必每行都 new 一遍。
	var effects: Array[RichTextEffect] = [
		BounceEffect.new(), GlitchEffect.new(), BlinkEffect.new(),
	]

	for e in tail:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var data: Dictionary = e
		var speaker := String(data.get("speaker", ""))
		# 台词存的是「原始文本」（含节奏标记），显示前要剥掉 ——
		# 否则 [wait=0.7] / [speed=2.5] 会原样显示在回看里。
		var text := TypingTimeline.strip(String(data.get("text", "")))
		var label := RichTextLabel.new()
		label.bbcode_enabled = true
		label.fit_content = true
		label.scroll_active = false
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 不给它注册特效的话，[bounce] 这类标记会因为「未知标签」漏成文本
		label.custom_effects = effects
		if speaker.is_empty():
			label.text = "[color=#a9a3d0]%s[/color]" % text
		else:
			label.text = "[color=#f1c774]%s[/color]  %s" % [speaker, text]
		UiTheme.apply_rich_text(label, UiTheme.TEXT, 22)
		_entries.add_child(label)

	visible = true
	# 等两帧让容器完成布局，max_value 才是正确的
	await get_tree().process_frame
	await get_tree().process_frame
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func hide_panel() -> void:
	visible = false


func _clear() -> void:
	for child in _entries.get_children():
		_entries.remove_child(child)
		child.queue_free()
