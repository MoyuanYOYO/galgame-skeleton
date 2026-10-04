extends Node

## 分支图验收
##
## 用户报的三条：
##   1. `common_pause` 被独立出来了（它只被 `call` 调用）
##   2. `jump_file` 没画出来
##   3. `ending_together` 连着 `ending_alone`，而两者毫无关系
##   4. 鼠标按住扫过节点就会跳转 —— 改成双击
##
## 根因都是「出口判定」：`call` 不算出口（→ 目标成孤儿）、
## 终结指令靠「out 为空」判断（→ 照样补了一条假 fall-through）。
##
## 跑法（要带窗口）：
##   godot --path . res://tools/editor/tests/graph_test.tscn

const EditorScene = preload("res://tools/editor/editor.tscn")
const EdTheme = preload("res://tools/editor/ed_theme.gd")
const NODE_W_EST := 232.0     ## 与 graph_panel.NODE_W 一致（估算端口位置用）

var _ed: Control
var _graph: Control
var _tmp := "user://__graph.gvs"
var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 分支图验收 ===")
	_write(_tmp, _make_text())

	_ed = EditorScene.instantiate()
	add_child(_ed)
	_ed.size = get_viewport().get_visible_rect().size
	await _wait(1.0)
	_ed._open(_tmp)
	await _wait(0.4)
	_ed.show_page("graph")
	await _wait(0.9)
	_graph = _ed._pages.get("graph")
	_ok(_graph != null, "分支图面板已创建")
	if _graph == null:
		_finish()
		return

	await _test_call_target_not_orphan()
	await _test_no_fake_fallthrough()
	await _test_jump_file()
	await _test_conditional_jumps()
	await _test_sub_annotation()
	await _test_no_exit_rows()
	await _test_node_kinds()
	await _test_label_note()
	await _test_connection_hover()
	await _test_double_click()

	_ed.queue_free()
	await _wait(0.3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp))
	_finish()


## `call sub` 的目标必须被连进来（不能是孤儿）
func _test_call_target_not_orphan() -> void:
	_sec("call 的目标不能是孤儿")
	_ok(_has_node("n_sub"), "sub 有节点")
	_ok(_has_edge("n_start", "n_sub"), "start → sub 连上了（call 也是出口）")
	_ok(not _is_orphan("n_sub"), "sub 不再是孤儿节点（不再被单独丢到最后一列）")


## 终结指令后面不该有假 fall-through
func _test_no_fake_fallthrough() -> void:
	_sec("终结指令不产生假 fall-through")

	# `after` 块以 jump_file 结尾 → 不该连到它下面的 lonely_end
	_ok(_has_node("n_after"), "after 有节点")
	_ok(_has_node("n_lonely_end"), "lonely_end 有节点")
	_ok(not _has_edge("n_after", "n_lonely_end"),
		"after 没有连到 lonely_end（jump_file 是终结，不是顺流）")

	# 以 `ending` 结尾的块同理
	_ok(_has_node("n_done"), "done 有节点")
	_ok(not _has_edge("n_done", "n_lonely_end"),
		"以 ending 结尾的 done 也没有连到 lonely_end")

	# 但 `call` 之后的块**应该**顺流（call 会返回）
	_ok(_has_edge("n_start", "n_after"), "start 的 jump 连到 after")


func _test_jump_file() -> void:
	_sec("jump_file 要画成跨文件出口")
	var ext := _external_nodes()
	_ok(ext.size() == 1, "有 1 个跨文件节点（实得 %d）" % ext.size())
	if ext.size() == 0:
		return
	var ext_name := String(ext[0])
	_ok(_has_edge("n_after", ext_name), "after → 跨文件节点 连上了")
	var node := _node(ext_name) as GraphNode
	_ok(node != null and node.title.contains("chapter1"), "跨文件节点标着目标文件名（%s）"
		% (node.title if node != null else ""))


## 节点里**不**列出口 —— 那会把节点撑高、`_fit` 只好把整张图缩得很小。
## 信息改由「悬停连线 / 点连线」承担（见下一节）。
func _test_no_exit_rows() -> void:
	_sec("节点里不列出口（避免把图挤小）")
	var done := _node("n_done") as GraphNode
	_ok(done != null, "拿得到 done 节点")
	if done == null:
		return
	_ok(done.get_child_count() == 2,
		"节点只有「摘要 + 说明」两行（实得 %d 行）" % done.get_child_count())

	# 但出口的原因 / 行号 / 条件一个都没丢 —— 只是挪到悬停里给
	var g: Control = _ed._pages.get("graph")
	var t := String(g.call("_edge_text", "n_done>n_only_a"))
	_ok(t.contains("跳转") and t.contains("第 15 行") and t.contains("if flag talked_to_alice"),
		"出口的原因 / 行号 / 条件还在（悬停时给出）：%s" % t.replace("\n", " | "))


## 结局 / 起点要更显眼
func _test_node_kinds() -> void:
	_sec("结局与起点的标记")
	var start := _node("n_start") as GraphNode
	_ok(start != null and start.title.begins_with("▶"), "起点带 ▶（实得 %s）"
		% (start.title if start != null else ""))
	_ok(start != null and start.get_theme_color("title_color") == EdTheme.OK, "起点用绿色")

	# 夹具里带 ending 的节点都同时是「走不到」的孤儿（前缀只放得下一个），
	# 所以「结局」标记放在说明行上 —— 它不该被别的身份挤掉。
	var ea := _node("n_only_a") as GraphNode
	_ok(ea != null and _note_of(ea).contains("★ 结局"),
		"结局节点在说明行标了「★ 结局」（实得 %s）" % ("" if ea == null else _note_of(ea)))

	# 身份与颜色的优先级直接查函数（免得为了造场景去改夹具的行号）
	var g: Control = _ed._pages.get("graph")
	_ok(String((g.call("_node_style", false, false, false, true))[0]) == "★ ",
		"结局的身份是 ★")
	_ok(String((g.call("_node_style", true, false, false, true))[0]) == "⚠ ",
		"孤儿优先于结局（走不到比结局更该提醒）")
	_ok(String((g.call("_node_style", false, false, true, false))[0]) == "▶ ",
		"起点是 ▶")
	_ok(String((g.call("_node_style", false, true, false, false))[0]) == "↩ ",
		"子过程是 ↩")
	_ok((g.call("_node_style", false, false, false, true))[1] != EdTheme.SYN_LABEL,
		"结局用与普通节点不同的颜色")


## 标签备注（`label X # 备注`）要显示在节点上，也能在剧本块里编辑
func _test_label_note() -> void:
	_sec("标签备注")
	var before := _node("n_after") as GraphNode
	_ok(before != null and _note_of(before).is_empty(), "默认没有备注")

	var no := _label_line("after")
	_ed.doc.set_raw(no, "label after  # 回到走廊")
	await _wait(0.3)
	_ed.show_page("graph")
	await _wait(0.7)
	var node := _node("n_after") as GraphNode
	_ok(node != null and _note_of(node).contains("回到走廊"),
		"节点上显示了备注（实得 %s）" % ("" if node == null else _note_of(node)))
	# 行尾注释不能影响解析：标签名还是 after
	_ok(_ed.doc.label_line("after") == no, "标签名不受备注影响（还能跳转）")

	# 剧本块的标签行要有备注输入框
	_ed.show_page("table")
	await _wait(0.8)
	var tbl: Control = _ed._pages.get("table")
	var row = (tbl.get("_row_by_no") as Dictionary).get(no, null) as Control
	_ok(row != null, "拿得到标签行控件")
	var found := false
	if row != null:
		for c in _all_line_edits(row):
			if (c as LineEdit).text == "回到走廊":
				found = true
	_ok(found, "剧本块的标签行能编辑这条备注")


## 悬停连线要显示「原因 / 条件 / 行号」
func _test_connection_hover() -> void:
	_sec("悬停连线显示原因 / 条件 / 行号")
	# 上一节在剧本块页收尾 —— 先回到分支图，否则「单击不跳」会误判
	_ed.show_page("graph")
	await _wait(0.7)
	var g: Control = _ed._pages.get("graph")
	_ok(g != null and g.get("_tip") != null, "有悬停提示浮层")
	_ok(g != null and not (g.get("_tip") as Control).visible, "默认不显示")

	# 查表：每条连线都能对应回它的出口
	var pairs: Dictionary = g.get("_edge_by_pair")
	var conns: Array = (g.get("_graph") as GraphEdit).get_connection_list()
	_ok(pairs.size() == conns.size() and conns.size() > 0,
		"每条连线都能查回它的出口（连线 %d 条 / 查表 %d 条）" % [conns.size(), pairs.size()])
	var t1 := String(g.call("_edge_text", "n_start>n_sub"))
	_ok(t1.contains("调用"), "start → sub 标了「调用」（实得 %s）" % t1.replace("\n", " | "))
	_ok(t1.contains("第 3 行"), "带行号（实得 %s）" % t1.replace("\n", " | "))
	var t2 := String(g.call("_edge_text", "n_done>n_only_a"))
	_ok(t2.contains("跳转") and t2.contains("if flag talked_to_alice"),
		"条件跳转的连线标了条件（实得 %s）" % t2.replace("\n", " | "))

	# 命中测试：沿「源节点右端口 → 目标节点左端口」扫一遍，总该命中
	var ge: GraphEdit = g.get("_graph")
	var a := _node("n_start") as GraphNode
	var b := _node("n_sub") as GraphNode
	var hits := 0
	var got := ""
	var pa := Vector2.ZERO
	var pb := Vector2.ZERO
	if a != null and b != null and ge != null:
		var z: float = ge.zoom
		var sc: Vector2 = ge.scroll_offset
		pa = a.position_offset * z - sc + Vector2(NODE_W_EST * z, 20.0 * z)
		pb = b.position_offset * z - sc + Vector2(0.0, 20.0 * z)
		for i in range(1, 20):
			g.call("_update_hover", pa.lerp(pb, float(i) / 20.0))
			if (g.get("_tip") as Control).visible:
				hits += 1
				got = (g.get("_tip_label") as Label).text
	_ok(hits > 0, "鼠标扫到连线上会弹提示（命中 %d / 19 个采样点）" % hits)
	_ok(got.contains("start") and got.contains("sub"),
		"提示里写了源和目标（实得 %s）" % got.replace("\n", " | "))
	g.call("_clear_hover")
	_ok(not (g.get("_tip") as Control).visible, "移开之后提示收起")

	# **点连线跳过去**：到剧本块定位到那条边的来源行（start → sub 的 `call sub` 在第 3 行）
	if hits > 0:
		var mid := Vector2.ZERO
		var found := false
		for i in range(1, 20):
			var q: Vector2 = pa.lerp(pb, float(i) / 20.0)
			g.call("_update_hover", q)
			if (g.get("_tip") as Control).visible:
				mid = q
				found = true
				break
		g.call("_clear_hover")
		if found:
			# 单击**不**跳（会和 GraphEdit 自己的鼠标处理打架）
			_send_click(g, mid, false)
			await _wait(0.4)
			_ok(_ed._current_page == "graph", "单击连线不跳（实得 %s）" % _ed._current_page)

			# 双击才跳 —— 而且必须**松开之后**才跳（按下就跳会让 GraphEdit
			# 收不到松开、切回来还挂着一条橡皮筋）
			_send_press(g, mid, true)
			await _wait(0.3)
			_ok(_ed._current_page == "graph", "只按下（还没松开）时不跳（实得 %s）"
				% _ed._current_page)
			_send_release(g, mid)
			await _wait(0.9)
			_ok(_ed._current_page == "table",
				"双击并松开之后跳到剧本块（实得 %s）" % _ed._current_page)
			var tbl2: Control = _ed._pages.get("table")
			_ok(tbl2 != null and int(tbl2.get("_current_no")) == 3,
				"定位到那条边的来源行（实得 %s，期望 3）" % str(tbl2.get("_current_no")))
			_ed.show_page("graph")
			await _wait(0.6)


func _send_press(g: Control, p: Vector2, dbl: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.double_click = dbl
	ev.position = p
	ev.global_position = p
	g.call("_on_graph_gui", ev)


func _send_release(g: Control, p: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	ev.position = p
	ev.global_position = p
	g.call("_on_graph_gui", ev)


func _send_click(g: Control, p: Vector2, dbl: bool) -> void:
	_send_press(g, p, dbl)
	_send_release(g, p)


func _all_line_edits(node: Node) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is LineEdit:
			out.append(c)
		out.append_array(_all_line_edits(c))
	return out


## 单击不跳、双击才跳
func _test_double_click() -> void:
	_sec("双击才跳转（单击不跳）")
	_ed.show_page("graph")
	await _wait(0.7)
	var node := _node("n_after") as GraphNode
	_ok(node != null, "拿得到 after 节点")
	if node == null:
		return

	# 单击（普通按下）
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.double_click = false
	node.gui_input.emit(press)
	await _wait(0.3)
	_ok(_ed._current_page == "graph", "单击不跳转（还在分支图页，实得 %s）" % _ed._current_page)

	# 双击
	var dbl := InputEventMouseButton.new()
	dbl.button_index = MOUSE_BUTTON_LEFT
	dbl.pressed = true
	dbl.double_click = true
	node.gui_input.emit(dbl)
	await _wait(0.4)
	_ok(_ed._current_page == "script", "双击跳到源码页（实得 %s）" % _ed._current_page)
	# 注意用 doc.label_line 而不是本地扫描：标签行尾可能带了备注
	_ok(_ed.caret_line == _ed.doc.label_line("after"),
		"光标落在 after 那一行（实得 %d，期望 %d）"
		% [_ed.caret_line, _ed.doc.label_line("after")])


## `if / elif / else` 里各有一次 jump —— **三条都要连上**。
##
## 老代码遇到第一个 `jump` 就 `break`，只画得出第一条；后两条没有任何入边，
## 被当成孤儿标签丢到最后一列（用户看到的就是「ending_normal / ending_bad
## 被独立出来了」）。
func _test_conditional_jumps() -> void:
	_sec("if / elif / else 里的跳转都要连上")
	_ok(_has_edge("n_done", "n_only_a"), "if 分支的 jump 连上了")
	_ok(_has_edge("n_done", "n_only_b"), "elif 分支的 jump 也连上了（老代码在这里断掉）")
	_ok(_has_edge("n_done", "n_only_c"), "else 分支的 jump 也连上了")
	_ok(not _is_orphan("n_only_a") and not _is_orphan("n_only_b")
		and not _is_orphan("n_only_c"), "三个分支目标都不是孤儿")
	# 条件跳转不终结：`end` 之后还有 `ending normal`，所以 done 不该顺流到 lonely_end
	_ok(not _has_edge("n_done", "n_lonely_end"), "条件跳转之后没有假顺流")


## 子过程（块里有 return）要有标注 —— 这是「call 会不会回来」的答案。
## 刻意不画返回边（call 可重入，返回边会变成交叉线），改在节点上写清关系。
func _test_sub_annotation() -> void:
	_sec("子过程标注（call / return 关系）")
	var sub := _node("n_sub") as GraphNode
	_ok(sub != null, "拿得到 sub 节点")
	if sub == null:
		return
	_ok(sub.title.begins_with("↩"), "子过程标题带 ↩ 记号（实得 %s）" % sub.title)
	var note := _note_of(sub)
	_ok(note.contains("子过程"), "标注里写了「子过程」（实得 %s）" % note)
	_ok(note.contains("被 1 处调用") and note.contains("start"),
		"标注里写了被谁调用（实得 %s）" % note)

	var start_node := _node("n_start") as GraphNode
	_ok(start_node != null and _note_of(start_node).contains("call sub"),
		"调用方标注了「→ call sub」（实得 %s）"
		% (_note_of(start_node) if start_node != null else ""))


## 节点第二行（说明行）的文字
func _note_of(node: GraphNode) -> String:
	if node == null or node.get_child_count() < 2:
		return ""
	return (node.get_child(1) as Label).text


# ---------------------------------------------------------------------------
# 数据
# ---------------------------------------------------------------------------

func _make_text() -> String:
	return "\n".join(PackedStringArray([
		"label start",
		"alice: 开头。",
		"call sub",
		"alice: 从子过程回来了。",
		"jump after",
		"label sub",
		"alice: 子过程里。",
		"return",
		"label after",
		"alice: 到了 after。",
		"jump_file res://data/scripts/chapter1.gvs chapter1_start",
		"label done",
		"alice: 收尾。",
		"if flag talked_to_alice",
		"    jump only_a",
		"elif flag other",
		"    jump only_b",
		"else",
		"    jump only_c",
		"end",
		"ending normal \"结束了\"",
		"label only_a",
		"ending a \"A\"",
		"label only_b",
		"ending b \"B\"",
		"label only_c",
		"ending c \"C\"",
		"label lonely_end",
		"alice: 没人能走到这里。",
		"ending bad \"另一个结局\"",
	])) + "\n"


# ---------------------------------------------------------------------------
# 图查询
# ---------------------------------------------------------------------------

func _node(name: String) -> GraphNode:
	for c in (_graph.get("_graph") as GraphEdit).get_children():
		if c is GraphNode and c.name == name:
			return c
	return null


func _has_node(name: String) -> bool:
	return _node(name) != null


func _connections() -> Array:
	return (_graph.get("_graph") as GraphEdit).get_connection_list()


func _has_edge(from_name: String, to_name: String) -> bool:
	for c in _connections():
		var d: Dictionary = c
		if String(d.get("from_node", "")) == from_name \
				and String(d.get("to_node", "")) == to_name:
			return true
	return false


## 有没有任何入边
func _has_incoming(name: String) -> bool:
	for c in _connections():
		if String((c as Dictionary).get("to_node", "")) == name:
			return true
	return false


## 孤儿 = 被放到了「最后一列」且没有入边
func _is_orphan(name: String) -> bool:
	return not _has_incoming(name)


func _external_nodes() -> Array:
	var out: Array = []
	for c in (_graph.get("_graph") as GraphEdit).get_children():
		if c is GraphNode and String(c.name).begins_with("x_"):
			out.append(String(c.name))
	return out


func _label_line(label: String) -> int:
	for i in range(1, _ed.doc.line_count() + 1):
		if _ed.doc.text_at(i).strip_edges() == "label %s" % label:
			return i
	return -1


# ---------------------------------------------------------------------------

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


func _sec(t: String) -> void:
	print("\n-- %s --" % t)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
