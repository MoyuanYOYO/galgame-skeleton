extends Node

## 剧本块「增删改」端到端验收
##
## 验证用户最关心的三件事在真实界面上真的能work：
##   插入行 / 删除行 / 改指令参数
## 而且改完写回剧本后，**用 GvsParser 解析出来必须是预期语义** ——
## 只比字符串还不够，因为「参数插错位置导致被解析器忽略」这种问题
## 字符串看着对、语义却是错的。
##
## 跑法（要带窗口）：
##   godot --path . res://tools/editor/tests/edit_test.tscn

const EditorScene = preload("res://tools/editor/editor.tscn")
const GvsParser = preload("res://scripts/core/gvs_parser.gd")
const LineIndex = preload("res://tools/editor/core/line_index.gd")

var _ed: Control
var _tbl: Control
var _tmp := "user://__editor_edit_test.gvs"
var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 剧本块 增删改 验收 ===")

	_write(_tmp, "label start\nbg classroom fade=0.8\nalice: 第一句。\nbob: 第二句。\n")

	_ed = EditorScene.instantiate()
	add_child(_ed)
	_ed.size = get_viewport().get_visible_rect().size
	await _wait(1.0)

	_ed._open(_tmp)
	await _wait(0.4)
	_ed.show_page("table")
	await _wait(0.5)

	_tbl = _ed._pages.get("table")
	_ok(_tbl != null, "剧本块面板已创建")
	if _tbl == null:
		_finish()
		return

	var n0: int = _ed.doc.line_count()
	_ok(n0 == 5, "初始 5 行（实得 %d）" % n0)

	# --- 1. 插入一行对白 ---
	_tbl._insert_say(2)
	await _wait(0.3)
	_ok(_ed.doc.line_count() == n0 + 1, "插入对白后行数 +1（实得 %d）" % _ed.doc.line_count())
	_ok(_ed.doc.text_at(3).contains(": 新台词"), "第 3 行是新对白（实得 %s）" % _ed.doc.text_at(3))

	# --- 2. 插入一条指令（用模板默认文本）---
	_tbl._insert_block(3, "bg")
	await _wait(0.3)
	_ok(_ed.doc.line_count() == n0 + 2, "插入指令后行数再 +1")
	var ins: String = _ed.doc.text_at(4)
	_ok(ins.begins_with("bg "), "第 4 行是 bg 指令（实得 %s）" % ins)

	# 新插入的指令必须是**语法合法**的（能解析、且 op 正确）
	var cmds := _parse_ops()
	_ok(cmds.has("bg"), "解析器认得出插入的 bg 指令")

	# --- 3. 改指令参数（kv）---
	var bg_line := -1
	for i in range(1, _ed.doc.line_count() + 1):
		if _ed.doc.text_at(i).begins_with("bg "):
			bg_line = i
			break
	_ok(bg_line > 0, "找得到 bg 指令所在行")
	_ed.doc.set_directive_param(bg_line, "fade", 1.5)
	_ok(_ed.doc.text_at(bg_line).contains("fade=1.5"),
		"kv 参数已改（实得 %s）" % _ed.doc.text_at(bg_line))
	# 语义校验：解析出来的 duration 真的变了
	var dur := _bg_duration()
	_ok(is_equal_approx(dur, 1.5), "解析器读到的 fade 是 1.5（实得 %s）" % str(dur))

	# --- 4. 删除一行 ---
	var before_del: int = _ed.doc.line_count()
	var del_text: String = _ed.doc.text_at(3)
	_tbl._do_delete(3)
	await _wait(0.3)
	_ok(_ed.doc.line_count() == before_del - 1, "删除后行数 -1")
	_ok(not _ed.doc.to_text().contains(del_text.strip_edges()),
		"被删的内容已不在文档里")

	# --- 5. 删除后其余行没被牵连 ---
	var txt: String = _ed.doc.to_text()
	_ok(txt.contains("alice: 第一句。"), "原有对白未被牵连")
	_ok(txt.contains("bob: 第二句。"), "原有对白未被牵连")
	_ok(txt.contains("label start"), "标签未被牵连")

	# --- 6. 撤销能回退 ---
	var n_before_undo: int = _ed.doc.line_count()
	_ed.doc.undo()
	await _wait(0.2)
	_ok(_ed.doc.line_count() == n_before_undo + 1, "撤销把删除的那行找回来了")

	# --- 7. 插入 together 并行组（多行骨架）---
	var n_before_tg: int = _ed.doc.line_count()
	_tbl._insert_block(_ed.doc.line_count() - 1, "together")
	await _wait(0.3)
	_ok(_ed.doc.line_count() == n_before_tg + 4,
		"插入 together 加了 4 行（实得 +%d）" % (_ed.doc.line_count() - n_before_tg))
	var tg_text: String = _ed.doc.to_text()
	_ok(tg_text.contains("together"), "骨架里有 together")
	# 骨架必须自带 `end` —— 只插一个 `together` 会把后面整段吞进块里
	_ok(tg_text.count("end") >= 1, "骨架自带 end 收尾")
	# 插入后整篇仍然语法合法（骨架里的注释行不参与解析）
	var tg_ops := _parse_ops()
	_ok(tg_ops.has("together"), "解析器认得出插入的 together 块")

	# --- 8. call 的「吃到行尾」参数（tail 字段）---
	# `rest` 只吃到最后一个位置参数，`who=alice` 是 kv 会被整段漏掉，
	# 所以这里走的是专门的 tail 通道。
	# ⚠️ `insert_raw(no, …)` 是 **1 基**的、插在「第 no 行之前」，
	# 所以追加到末尾要传 `line_count() + 1`（传 `line_count()` 会插到倒数第二行）。
	_ed.doc.insert_raw(_ed.doc.line_count() + 1,
		PackedStringArray(["call greet who=alice count=2"]))
	var call_line: int = _ed.doc.line_count()
	_ok(_ed.doc.directive_tail(_ed.doc.text_at(call_line), 1) == "who=alice count=2",
		"tail 读到标签之后的整段（实得「%s」）"
		% _ed.doc.directive_tail(_ed.doc.text_at(call_line), 1))
	_ed.doc.set_directive_tail(call_line, 1, "who=bob count=3")
	_ok(_ed.doc.text_at(call_line) == "call greet who=bob count=3",
		"tail 写回替换整段（实得「%s」）" % _ed.doc.text_at(call_line))
	# 清空 → 只剩标签，不能留下悬空的空格
	_ed.doc.set_directive_tail(call_line, 1, "")
	_ok(_ed.doc.text_at(call_line) == "call greet",
		"tail 清空后只剩标签（实得「%s」）" % _ed.doc.text_at(call_line))
	# 没有参数时 tail 读回空串（而不是报错 / 读到标签本身）
	_ok(_ed.doc.directive_tail(_ed.doc.text_at(call_line), 1) == "",
		"没有参数时 tail 读回空串")
	# 语义校验：写回的参数真的进了 call 指令
	_ed.doc.set_directive_tail(call_line, 1, "who=carol")
	var call_cmd: Dictionary = {}
	for c in (GvsParser.parse(_ed.doc.to_text(), "t.gvs")["commands"] as Array):
		if String((c as Dictionary).get("op", "")) == "call":
			call_cmd = c
	_ok(String((call_cmd.get("params", {}) as Dictionary).get("who", "")) == "carol",
		"写回的参数被解析器读到了（who=%s）"
		% str((call_cmd.get("params", {}) as Dictionary).get("who", "")))

	# --- 9. 行分类器认得出 together 块（缩进 / 折叠靠它）---
	var lx := LineIndex.parse("label start\ntogether\n    bg classroom\n    show alice\nend\nnarr 之后\n")
	_ok((lx.get("errors", []) as Array).is_empty(),
		"together 块不会让分类器报错（%s）" % str(lx.get("errors", [])))
	var lines: Array = lx.get("lines", [])
	# 行号：1 label / 2 together / 3 bg / 4 show / 5 end / 6 narr
	_ok(int((lines[1] as LineIndex.Line).depth) == 0, "together 自身在第 0 层")
	_ok(int((lines[2] as LineIndex.Line).depth) == 1, "块内 bg 在第 1 层")
	_ok(int((lines[4] as LineIndex.Line).depth) == 0, "end 与 together 同级")
	_ok(int((lines[5] as LineIndex.Line).depth) == 0, "end 之后回到第 0 层")
	_ok((lines[1] as LineIndex.Line).opens_block(), "opens_block() 认 together")
	var blocks: Array = lx.get("blocks", [])
	_ok(blocks.size() == 1 and String((blocks[0] as LineIndex.Block).kind) == "together",
		"块列表里有一条 together 块")

	_ed.queue_free()
	await _wait(0.3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp))
	_finish()


func _parse_ops() -> PackedStringArray:
	var out := PackedStringArray()
	var r := GvsParser.parse(_ed.doc.to_text(), "t.gvs")
	for c in (r["commands"] as Array):
		out.append(String((c as Dictionary).get("op", "")))
	return out


func _bg_duration() -> float:
	var r := GvsParser.parse(_ed.doc.to_text(), "t.gvs")
	for c in (r["commands"] as Array):
		var cmd: Dictionary = c
		if String(cmd.get("op", "")) == "bg":
			return float(cmd.get("duration", 0.0))
	return -1.0


func _finish() -> void:
	print("")
	if _fail == 0:
		print("=== ALL OK  %d 项 ===" % _pass)
		get_tree().quit(0)
	else:
		print("=== FAILED  %d 通过 / %d 失败 ===" % [_pass, _fail])
		get_tree().quit(1)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  OK    %s" % msg)
	else:
		_fail += 1
		print("  FAIL  %s" % msg)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
