class_name ChoicePanel
extends Control

## 选项面板
##
## 选项按钮完全由代码生成 —— 剧本里写几条分支就出现几个按钮，
## 不需要在编辑器里预置任何东西。

signal option_selected(index: int)

@onready var _list: VBoxContainer = %ChoiceList

var _buttons: Array[Button] = []


func _ready() -> void:
	visible = false


func present(options: Array) -> void:
	_clear()
	var first: Button = null
	for i in options.size():
		var data: Dictionary = options[i] if typeof(options[i]) == TYPE_DICTIONARY else {}
		var btn := Button.new()
		btn.text = String(data.get("text", ""))
		btn.focus_mode = Control.FOCUS_ALL
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		UiTheme.apply_button(btn, "choice")
		btn.pressed.connect(_on_pressed.bind(i))
		_list.add_child(btn)
		_buttons.append(btn)
		if first == null:
			first = btn
	visible = true
	if first != null:
		first.grab_focus()


func dismiss() -> void:
	visible = false
	_clear()


func _clear() -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_buttons.clear()


func _on_pressed(index: int) -> void:
	dismiss()
	option_selected.emit(index)
