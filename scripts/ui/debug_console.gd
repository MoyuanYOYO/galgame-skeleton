class_name DebugConsole
extends Control

## 调试控制台
##
## 按 `~` 开关（只在 debug 构建里启用）。命令直接作用于运行中的状态 ——
## 写剧本时不用「改剧本 → 重启 → 从头点到那一句」。
##
## 自己拿着 main 节点的引用而不是走信号，是因为它本来就是个调试工具，
## 多点耦合换实现简单是划算的。

const PANEL_HEIGHT := 420.0
const MAX_OUTPUT_LINES := 200

var _main: Node
var _panel: PanelContainer
var _output: RichTextLabel
var _input: LineEdit
var _history: PackedStringArray = []
var _history_cursor: int = -1


func setup(main_node: Node) -> void:
	_main = main_node


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Control 直接挂在 CanvasLayer 下时，锚点拿不到视口尺寸 ——
	# 实测 set_anchors_preset(PRESET_FULL_RECT) 之后 size 仍是 (0,0)，
	# 于是「底部面板」被算到了屏幕外，什么都看不见。显式设尺寸，并跟着视口变化。
	_fit_to_viewport()
	if not get_viewport().size_changed.is_connected(_fit_to_viewport):
		get_viewport().size_changed.connect(_fit_to_viewport)

	# 面板直接铺在底部，不套中间容器
	_panel = PanelContainer.new()
	_panel.name = "ConsolePanel"
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_panel.offset_top = -PANEL_HEIGHT
	_panel.offset_bottom = 0.0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	UiTheme.apply_panel(_panel, "default")
	add_child(_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	_panel.add_child(column)

	_output = RichTextLabel.new()
	_output.bbcode_enabled = true
	_output.scroll_following = true
	_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_output.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiTheme.apply_rich_text(_output, UiTheme.TEXT, 18, "dialogue")
	column.add_child(_output)

	_input = LineEdit.new()
	_input.placeholder_text = "输入命令，help 查看全部"
	_input.custom_minimum_size = Vector2(0.0, 40.0)
	_input.add_theme_color_override("font_color", UiTheme.TEXT)
	_input.add_theme_font_size_override("font_size", 18)
	_input.text_submitted.connect(_on_submitted)
	column.add_child(_input)

	_print_line("[color=#888780]调试控制台。输入 help 看命令。`~` 关闭。[/color]")


func toggle() -> void:
	visible = not visible
	if visible:
		_fit_to_viewport()
		_input.grab_focus()
		_input.clear()


## 把自己撑满视口。CanvasLayer 不是 Control，锚点指望不上。
##
## 注意：FULL_RECT 锚点的左右（上下）是非等值的，这时 size 会被 offset 反推，
## 直接赋 size 会被引擎警告并覆盖。所以要设 offset 而不是 size。
func _fit_to_viewport() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var rect := vp.get_visible_rect().size
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 0.0
	offset_top = 0.0
	offset_right = rect.x
	offset_bottom = rect.y


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	# 上下翻历史
	if key.keycode == KEY_UP and not _history.is_empty():
		_history_cursor = maxi(0, _history_cursor - 1) if _history_cursor >= 0 \
			else _history.size() - 1
		_input.text = _history[_history_cursor]
		_input.caret_column = _input.text.length()
		accept_event()
	elif key.keycode == KEY_DOWN:
		if _history_cursor >= 0 and _history_cursor < _history.size() - 1:
			_history_cursor += 1
			_input.text = _history[_history_cursor]
		else:
			_history_cursor = -1
			_input.text = ""
		accept_event()


# ---------------------------------------------------------------------------
# 命令
# ---------------------------------------------------------------------------

func _on_submitted(line: String) -> void:
	var text := line.strip_edges()
	_input.clear()
	if text.is_empty():
		return
	_history.append(text)
	_history_cursor = -1
	_print_line("[color=#7F77DD]> %s[/color]" % text)
	_execute(text)


func _execute(text: String) -> void:
	var parts := text.split(" ", false)
	if parts.is_empty():
		return
	var cmd := String(parts[0]).to_lower()
	var args := parts.slice(1)

	match cmd:
		"help":
			_print_help()
		"jump":
			_cmd_jump(args)
		"goto":
			_cmd_goto(args)
		"flag":
			_cmd_flag(args)
		"var":
			_cmd_var(args)
		"aff", "affection":
			_cmd_affection(args)
		"unlock":
			_cmd_unlock(args)
		"ending":
			_cmd_ending(args)
		"state":
			_cmd_state()
		"audit":
			_cmd_audit()
		"assets":
			_cmd_assets()
		"reload":
			_cmd_reload()
		"read":
			_cmd_read(args)
		"clear":
			_output.clear()
		_:
			_print_line("[color=#E24B4A]未知命令：%s（help 看列表）[/color]" % cmd)


func _print_help() -> void:
	var rows := [
		["jump <标签>", "跳到当前剧本的某个标签"],
		["goto <文件> <标签>", "换一个剧本文件并跳转"],
		["flag <名字> [值]", "查看 / 设置旗标"],
		["var <名字> [值]", "查看 / 设置变量"],
		["aff <角色> [值]", "查看 / 设置好感度"],
		["unlock <类型> <id>", "解锁收藏（cg / music / endings）"],
		["unlock all", "解锁全部收藏"],
		["ending <id>", "直接触发某个结局"],
		["state", "打印当前运行状态"],
		["audit", "跑一遍剧本静态校验"],
		["assets", "列出缺哪些素材"],
		["reload", "热重载当前剧本（从当前标签重开）"],
		["read clear", "清空已读记录"],
		["clear", "清屏"],
	]
	for row in rows:
		_print_line("  [color=#5DCAA5]%-22s[/color][color=#888780]%s[/color]"
			% [String(row[0]), String(row[1])])


func _cmd_jump(args: PackedStringArray) -> void:
	if args.is_empty():
		_print_line("[color=#E24B4A]用法：jump <标签>[/color]")
		return
	var runner: ScriptRunner = _main.get("runner") as ScriptRunner
	var label := String(args[0])
	if not runner.has_label(label):
		_print_line("[color=#E24B4A]标签不存在：%s[/color]" % label)
		return
	runner.jump_to_label(label)
	_print_line("[color=#5DCAA5]已跳到 %s[/color]" % label)


func _cmd_goto(args: PackedStringArray) -> void:
	if args.size() < 2:
		_print_line("[color=#E24B4A]用法：goto <文件> <标签>[/color]")
		return
	var runner: ScriptRunner = _main.get("runner") as ScriptRunner
	var file := String(args[0])
	if not file.begins_with("res://"):
		file = "res://data/scripts/" + file
	if not runner.load_script(file):
		_print_line("[color=#E24B4A]加载失败：%s[/color]" % file)
		return
	runner.start(String(args[1]))
	_print_line("[color=#5DCAA5]已切到 %s 的 %s[/color]" % [file.get_file(), args[1]])


func _cmd_flag(args: PackedStringArray) -> void:
	if args.is_empty():
		_print_line("[color=#E24B4A]用法：flag <名字> [值][/color]")
		return
	var name := String(args[0])
	if args.size() == 1:
		_print_line("flag %s = %s" % [name, str(GameManager.get_flag(name))])
		return
	var value := String(args[1]).to_lower() not in ["0", "false", "off"]
	GameManager.set_flag(name, value)
	_print_line("[color=#5DCAA5]flag %s := %s[/color]" % [name, str(value)])


func _cmd_var(args: PackedStringArray) -> void:
	if args.is_empty():
		_print_line("[color=#E24B4A]用法：var <名字> [值][/color]")
		return
	var name := String(args[0])
	if args.size() == 1:
		_print_line("var %s = %s" % [name, str(GameManager.get_var(name, "<未定义>"))])
		return
	var raw := String(args[1])
	var value: Variant = raw.to_float() if raw.is_valid_float() else raw
	GameManager.set_var(name, value)
	_print_line("[color=#5DCAA5]var %s := %s[/color]" % [name, str(value)])


func _cmd_affection(args: PackedStringArray) -> void:
	if args.is_empty():
		_print_line("[color=#E24B4A]用法：aff <角色> [值][/color]")
		return
	var who := String(args[0])
	if args.size() == 1:
		_print_line("affection %s = %.1f" % [who, GameManager.get_affection(who)])
		return
	GameManager.set_affection(who, String(args[1]).to_float())
	_print_line("[color=#5DCAA5]affection %s := %.1f[/color]"
		% [who, GameManager.get_affection(who)])


func _cmd_unlock(args: PackedStringArray) -> void:
	if args.is_empty():
		_print_line("[color=#E24B4A]用法：unlock <类型> <id> 或 unlock all[/color]")
		return
	if String(args[0]).to_lower() == "all":
		var total := 0
		for type in CollectionRegistry.types():
			total += CollectionManager.unlock_many(type, CollectionRegistry.get_ids(type))
		_print_line("[color=#5DCAA5]解锁了 %d 项收藏[/color]" % total)
		return
	if args.size() < 2:
		_print_line("[color=#E24B4A]用法：unlock <类型> <id>[/color]")
		return
	var type := String(args[0])
	var id := String(args[1])
	if not CollectionRegistry.has_item(type, id):
		_print_line("[color=#E24B4A]注册表里没有 %s / %s[/color]" % [type, id])
		return
	CollectionManager.unlock(type, id)
	_print_line("[color=#5DCAA5]已解锁 %s / %s[/color]" % [type, id])


func _cmd_ending(args: PackedStringArray) -> void:
	if args.is_empty():
		_print_line("[color=#E24B4A]用法：ending <id>[/color]")
		return
	var id := String(args[0])
	var item := CollectionRegistry.get_item("endings", id)
	if item.is_empty():
		_print_line("[color=#E24B4A]endings.json 里没有 %s[/color]" % id)
		return
	CollectionManager.unlock("endings", id)
	_main.call("_on_script_ended", id, String(item.get("title", "")))
	_print_line("[color=#5DCAA5]已触发结局 %s[/color]" % id)


func _cmd_state() -> void:
	var runner: ScriptRunner = _main.get("runner") as ScriptRunner
	_print_line("文件　　%s" % runner.get_current_file().get_file())
	_print_line("标签　　%s" % runner.get_current_label())
	_print_line("章节　　%s" % GameManager.chapter_title)
	_print_line("游玩　　%s" % SaveManager.format_play_time(GameManager.play_time))
	var affs := GameManager.get_all_affections()
	if affs.is_empty():
		_print_line("好感度　（空）")
	else:
		for who in affs.keys():
			_print_line("好感度　%s = %.1f" % [who, float(affs[who])])
	_print_line("已读　　%d 句" % ReadTracker.read_count())
	_print_line("选项　　%d 个已记录" % RouteTracker.pick_count())


func _cmd_audit() -> void:
	var result := ScriptAudit.audit()
	var errors: Array = result["errors"]
	var warnings: Array = result["warnings"]
	_print_line("扫了 %d 个文件、%d 条指令" % [result["files"], result["commands"]])
	for e in errors:
		_print_line("[color=#E24B4A][错误] %s[/color]" % String(e))
	for w in warnings:
		_print_line("[color=#EF9F27][提醒] %s[/color]" % String(w))
	if errors.is_empty() and warnings.is_empty():
		_print_line("[color=#5DCAA5]没有问题[/color]")


func _cmd_assets() -> void:
	var missing := ScriptAudit.missing_assets()
	if missing.is_empty():
		_print_line("[color=#5DCAA5]剧本用到的素材全都有真实文件[/color]")
		return
	for kind in missing.keys():
		var list: Array = missing[kind]
		_print_line("[color=#EF9F27]%s 缺 %d 个：[/color]%s"
			% [kind, list.size(), ", ".join(list)])


## 热重载：重新解析当前剧本，从当前标签重开。
## 会丢掉「标签内部的进度」，但不用退出游戏重来一遍。
func _cmd_reload() -> void:
	var runner: ScriptRunner = _main.get("runner") as ScriptRunner
	var file := runner.get_current_file()
	if file.is_empty():
		_print_line("[color=#E24B4A]当前没有加载剧本[/color]")
		return
	var label := runner.get_current_label()
	ScriptStats.clear_cache()
	if not runner.load_script(file):
		_print_line("[color=#E24B4A]重载失败（剧本有解析错误？跑 audit 看看）[/color]")
		return
	runner.start(label)
	_print_line("[color=#5DCAA5]已重载 %s，从标签 %s 重新开始[/color]"
		% [file.get_file(), label if not label.is_empty() else "开头"])


func _cmd_read(args: PackedStringArray) -> void:
	if args.is_empty():
		_print_line("已读 %d 句 / 全部 %d 句"
			% [ReadTracker.read_count(), ScriptStats.total_lines()])
		return
	if String(args[0]).to_lower() == "clear":
		ReadTracker.clear()
		_print_line("[color=#5DCAA5]已清空已读记录[/color]")


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

func _print_line(text: String) -> void:
	_output.append_text(text + "\n")
	# 长时间不关会把输出堆爆，裁掉最旧的
	if _output.get_line_count() > MAX_OUTPUT_LINES:
		var lines := _output.text.split("\n")
		var keep := lines.slice(maxi(0, lines.size() - MAX_OUTPUT_LINES))
		_output.text = "\n".join(keep)
