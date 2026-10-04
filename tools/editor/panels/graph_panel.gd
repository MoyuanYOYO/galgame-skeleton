extends Control

## 分支结构图
##
## 用 Godot 内建的 `GraphEdit` + `GraphNode` 渲染 —— 节点拖拽、缩放平移、
## 连线绘制、框选、小地图全是内建的，不需要自己写图编辑器。
##
## **只读**：点击节点跳到源码对应行去改，不在图上直接编辑结构。
## 理由（见设计讨论）：拖拽改结构要「图 ↔ 文本」双向映射，
## 而其中「拖动节点改变物理顺序」会静默改掉 fall-through 语义 ——
## 那类错误不报错、只让剧情走错，是最不该引入的风险。
## 图的价值在**看清结构**（死路 / 孤儿标签 / 汇聚 / 结局分布），
## 改结构回到源码去做更安全。
##
## 建图数据 100% 现成：`GvsParser.parse()` 已给出 labels 与 commands，
## 这里只需把它们翻译成「出口」关系并做一次分层布局。

const EdTheme = preload("res://tools/editor/ed_theme.gd")
const LineIndex = preload("res://tools/editor/core/line_index.gd")

const NODE_W := 232.0
const ENDING_COLOR := Color("#d9709e")   ## 结局节点的标题色

## 出口类型 → 中文（写在节点上，替代「连线上写字」）
const KIND_LABELS := {
	"jump": "跳转", "goto": "跳转", "call": "调用",
	"choice": "选项", "fall": "顺流", "jump_file": "跨文件",
}
const COL_GAP := 300.0     ## 列间距
const ROW_GAP := 120.0     ## 行间距

var _ed: Control
var _graph: GraphEdit
var _stat: Label
var _hint: Label
var _layout: Dictionary = {}      ## 标签名 → {layer, order}
## 连线悬停提示（自己画：`GraphEdit` 的连线没有 tooltip，也没有 hover 信号）
var _tip: PanelContainer
var _tip_label: Label
var _hover: Dictionary = {}       ## {key, hit}
## 「双击连线」的待办：按下时记下目标行，**松开时才跳**。
## 见 `_on_graph_gui` 里的说明。
var _pending_jump := 0
## 「连线 → 出口数据」的查表（键 = 源节点名 → 目标节点名）
var _edge_by_pair: Dictionary = {}
const READABLE_ZOOM := 0.55   ## 初始缩放的下限：再小字就看不清了
const HOVER_DIST := 14.0          ## 鼠标离连线多近算「悬停在连线上」


func setup(ed: Control) -> void:
	_ed = ed
	_build()


func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_PANEL, 0, 10, 6, EdTheme.BORDER, 1))
	root.add_child(bar)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	bar.add_child(h)

	_stat = EdTheme.label("", EdTheme.FS_SMALL, EdTheme.TEXT_DIM)
	h.add_child(_stat)
	h.add_child(EdTheme.hfill())

	_hint = EdTheme.label(
		"双击节点跳到剧本块 · 悬停连线看原因 / 双击连线跳过去 · 拖拽可移动 · 滚轮缩放 · 中键平移"
		+ "　｜　图是只读的：拖端口不会连线，改结构请回剧本块或源码",
		EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	h.add_child(_hint)

	var btn_fit := EdTheme.chip("适应窗口")
	btn_fit.pressed.connect(_fit)
	h.add_child(btn_fit)

	_graph = GraphEdit.new()
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph.show_grid = true
	_graph.show_zoom_label = true
	_graph.minimap_enabled = true
	_graph.right_disconnects = false
	_graph.add_theme_color_override("grid_major", Color(1, 1, 1, 0.045))
	_graph.add_theme_color_override("grid_minor", Color(1, 1, 1, 0.018))
	_graph.add_theme_color_override("activity", EdTheme.ACCENT)
	_graph.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG, 0, 0, 0, EdTheme.BORDER, 1))
	# 注意**不要**接 `node_selected` —— 它在鼠标按下时就发，
	# 会让「拖动节点 / 扫过节点」变成跳转。跳转走各节点的 gui_input 双击。
	# 悬停连线出提示：`GraphEdit` 没有 hover 信号，用鼠标移动 + 命中测试自己做。
	_graph.gui_input.connect(_on_graph_gui)
	_graph.mouse_exited.connect(_clear_hover)
	root.add_child(_graph)

	# 悬停提示（自己画的浮层，跟着鼠标走）
	_tip = PanelContainer.new()
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip.visible = false
	_tip.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_ELEV, 4, 8, 5, EdTheme.BORDER_HI, 1))
	_tip_label = EdTheme.label("", EdTheme.FS_SMALL, EdTheme.TEXT)
	_tip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip.add_child(_tip_label)
	add_child(_tip)


func on_shown() -> void:
	rebuild()


# ---------------------------------------------------------------------------
# 建图
# ---------------------------------------------------------------------------

func rebuild() -> void:
	if _ed == null or _ed.doc == null or _graph == null:
		return
	_clear_hover()
	_pending_jump = 0
	_edge_by_pair.clear()
	for c in _graph.get_children():
		if c is GraphNode:
			_graph.remove_child(c)
			c.queue_free()
	# 连线要单独清（GraphEdit 的连线不是子节点）
	_graph.clear_connections()

	var doc = _ed.doc
	var lines: Array = doc.lines

	# 1. 收集标签
	var labels: Array = []      # [{name, no}]
	for l in lines:
		var line := l as LineIndex.Line
		if line.kind == LineIndex.Line.LABEL:
			labels.append({"name": line.label, "no": line.no})
	if labels.is_empty():
		_stat.text = "这个剧本没有任何 label，画不出结构"
		return

	# 2. 算每个标签的出口
	var edges: Dictionary = {}          # 标签名 → [{to, kind}]
	var name_set: Dictionary = {}
	for entry in labels:
		name_set[String((entry as Dictionary)["name"])] = true

	for k in labels.size():
		var name := String((labels[k] as Dictionary)["name"])
		var from_no := int((labels[k] as Dictionary)["no"])
		var to_no := int((labels[k + 1] as Dictionary)["no"]) - 1 if k + 1 < labels.size() \
			else lines.size()
		edges[name] = _exits(lines, from_no, to_no, k + 1 < labels.size(),
			String((labels[k + 1] as Dictionary)["name"]) if k + 1 < labels.size() else "",
			doc.path)

	# 2.5 跨文件目标（`jump_file` 指向别的剧本）也要有节点，
	# 否则那条边会凭空消失 —— 「跳出去了」这件事在图上就看不到了。
	var externals: Dictionary = {}      # 显示名 → {file, label}
	for nm in edges.keys():
		for e in (edges[nm] as Array):
			var e2: Dictionary = e
			if not e2.has("file"):
				continue
			externals[String(e2["to"])] = {
				"file": String(e2["file"]),
				"label": String(e2["to"]).split(" ▸ ")[1] if String(e2["to"]).contains(" ▸ ") else "",
			}

	# 2.6 子过程（块里有 `return`）与调用者 —— 用来标注 call / return 这层关系。
	#
	# **刻意不画「return 连回调用点」的边**：`call` 是可重入的，
	# 一个子过程常被多处调用（`common_pause` 就被两处 call），
	# 返回边会变成一堆交叉线，把「整体结构」这张图搅乱。
	# 改用标注：子过程节点上写清「被哪几处调用」，调用方节点上写清「call 了谁」。
	var subs := _sub_labels(lines, labels)
	var ends := _ending_labels(lines, labels)
	var notes: Dictionary = doc.label_notes()
	var callers: Dictionary = {}      # 目标标签 → [调用者标签]
	for nm0 in edges.keys():
		for e0 in (edges[nm0] as Array):
			var e3: Dictionary = e0
			if String(e3.get("kind", "")) == "call":
				var t0 := String(e3["to"])
				if not callers.has(t0):
					callers[t0] = []
				(callers[t0] as Array).append(String(nm0))

	# 3. 分层布局（BFS 深度 = 列号）
	_layout = {}
	var start_name: String = "start" if name_set.has("start") else String((labels[0] as Dictionary)["name"])
	_assign_layers(start_name, edges)
	# 不可达的标签（孤儿）单独放到最后一列
	var orphans: Array = []
	for entry in labels:
		var nm := String((entry as Dictionary)["name"])
		if not _layout.has(nm):
			orphans.append(nm)
	for nm in externals.keys():
		if not _layout.has(String(nm)):
			_layout[String(nm)] = {"layer": _max_layer() + 1, "order": 0}
	for nm in orphans:
		_layout[nm] = {"layer": _max_layer() + 1, "order": 0}

	# 4. 建节点
	var order_in_layer: Dictionary = {}
	var node_by_name: Dictionary = {}
	var outgoing: Dictionary = {}

	for entry in labels:
		var nm := String((entry as Dictionary)["name"])
		var no := int((entry as Dictionary)["no"])
		var info: Dictionary = _layout[nm]
		var layer := int(info["layer"])
		var order := int(order_in_layer.get(layer, 0))
		order_in_layer[layer] = order + 1

		var exits: Array = edges.get(nm, [])
		var node := _make_node(nm, no, exits, orphans.has(nm), lines,
			subs.has(nm), callers.get(nm, []), nm == start_name, ends.has(nm),
			String(notes.get(nm, "")))
		node.position_offset = Vector2(layer * COL_GAP, order * ROW_GAP)
		_graph.add_child(node)
		node_by_name[nm] = node
		outgoing[nm] = exits

	for nm in externals.keys():
		var key := String(nm)
		var ext: Dictionary = externals[key]
		var info2: Dictionary = _layout[key]
		var layer2 := int(info2["layer"])
		var order2 := int(order_in_layer.get(layer2, 0))
		order_in_layer[layer2] = order2 + 1
		var node2 := _make_external_node(key, String(ext["file"]))
		node2.position_offset = Vector2(layer2 * COL_GAP, order2 * ROW_GAP)
		_graph.add_child(node2)
		node_by_name[key] = node2

	# 5. 连线（在节点都进树之后）
	for nm in outgoing.keys():
		var from_node: GraphNode = node_by_name.get(nm)
		if from_node == null:
			continue
		for e in (outgoing[nm] as Array):
			var target := String((e as Dictionary)["to"])
			var to_node: GraphNode = node_by_name.get(target)
			if to_node == null:
				continue
			_graph.connect_node(from_node.name, 0, to_node.name, 0)
			# 记下「这条连线对应哪条出口」—— 悬停时要拿它的原因 / 条件 / 行号
			_edge_by_pair["%s>%s" % [from_node.name, to_node.name]] = e

	var cross := externals.size()
	_stat.text = "%d 个标签 · %d 条连线 · %d 个孤儿标签%s%s" % [
		labels.size(), _count_edges(outgoing), orphans.size(),
		("（%s）" % ", ".join(orphans.slice(0, 4))) if orphans.size() > 0 else "",
		" · %d 个跨文件出口" % cross if cross > 0 else ""]

	await get_tree().process_frame
	_fit(READABLE_ZOOM)


func _count_edges(outgoing: Dictionary) -> int:
	var n := 0
	for k in outgoing.keys():
		n += (outgoing[k] as Array).size()
	return n


## 一个标签块内，执行流会走到哪儿去。
##
## 规则与 GVS 的语义一一对应：
##   `jump` / `goto`    → 跳到目标；**块首层级（depth == 0）**时是唯一出口、后面是死代码
##   `jump_file`        → 跨文件的出口
##   `ending` / `return` → 终结点，无出口
##   `call`             → **有出口**：被调用的标签确实是从这里进去的。
##                        以前把它当成「会回来的、不算出口」，于是
##                        `call common_pause` 的目标在图上成了孤立节点。
##                        它同时也**会返回**，所以继续往下扫、也允许 fall-through。
##   `choice`           → 每个选项一个出口；选项本身就是出口，不再 fall-through
##   都没遇到           → fall-through 到下一个标签
##
## ⚠️ **两件事必须显式判断，不能靠「out 为空」**：
##
## 1. **终结**要记进 `terminated`。老代码对 `ending` / `return` 直接 `return out`
##    （out 是空的），于是紧接着的 fall-through 补丁照样生效 ——
##    实测把 `ending_normal` 连到了 `ending_bad`、
##    把以 `jump_file` 结尾的 `ending_together` 连到了 `ending_alone`。两条都是假边。
##
## 2. **`if` / `choice` 里的跳转是「条件跳转」**，不能终结、更不能 `break`。
##    老代码遇到第一个 `jump` 就 `break`，于是
##    `if … jump A / elif … jump B / else … jump C` 只画出了 A ——
##    B、C 没有任何入边，被当成孤儿标签丢到最后一列
##    （实测 `ending_normal` / `ending_bad` 就是这么「被独立出来」的）。
##    `LineIndex` 的 `depth` 正好告诉我们这一行在不在块里。
func _exits(lines: Array, from_no: int, to_no: int, has_next: bool,
		next_label: String, file_path: String) -> Array:
	var out: Array = []
	var terminated := false
	var n := from_no
	while n <= to_no and n <= lines.size():
		var l := lines[n - 1] as LineIndex.Line
		# 在 if / elif / else / choice 块里 → 条件跳转，块还会继续往下走
		var conditional := l.depth > 0
		if l.kind == LineIndex.Line.DIRECTIVE:
			match l.head:
				"jump", "goto":
					if not l.label.is_empty():
						out.append({"to": l.label, "kind": "jump", "line": l.no,
							"cond": _cond_at(lines, l.no, l.depth)})
					if not conditional:
						terminated = true
						break
				"jump_file":
					if not l.label.is_empty():
						var f := l.file if not l.file.is_empty() else file_path
						if f == file_path:
							out.append({"to": l.label, "kind": "jump", "line": l.no,
								"cond": _cond_at(lines, l.no, l.depth)})
						else:
							out.append({"to": "%s ▸ %s" % [f.get_file(), l.label],
								"kind": "jump_file", "file": f, "line": l.no,
								"cond": _cond_at(lines, l.no, l.depth)})
					if not conditional:
						terminated = true
						break
				"ending", "return":
					if not conditional:
						terminated = true
						break
				"call":
					# 调用点也是「进入被调用标签」的一条边；扫完继续往下看
					if not l.label.is_empty():
						out.append({"to": l.label, "kind": "call", "line": l.no,
							"cond": _cond_at(lines, l.no, l.depth)})
				"choice":
					pass      # 出口由下面的选项行给出
		elif l.kind == LineIndex.Line.CHOICE_OPTION:
			if not l.label.is_empty():
				out.append({"to": l.label, "kind": "choice", "line": l.no,
					"cond": l.text})
				# 选项即出口，`end` 之后不会顺流下来。
				# 但嵌套在 if 里的 choice 例外（那时后面还有代码）。
				if l.depth <= 1:
					terminated = true
		n += 1

	if not terminated and has_next and not next_label.is_empty():
		out.append({"to": next_label, "kind": "fall", "line": to_no, "cond": ""})
	return out


## 这一行所属的**分支条件**：`if flag x` / `elif …` / `else`，顶层返回空串。
##
## 连线本身画不了字，但「为什么跳过去」恰恰是看图时最想知道的事 ——
## 所以把条件记在出口上，由节点逐条列出来（见 `_make_node`）。
static func _cond_at(lines: Array, no: int, depth: int) -> String:
	if depth <= 0:
		return ""
	var i := no - 2
	while i >= 0:
		var l := lines[i] as LineIndex.Line
		if l.depth < depth - 1:
			break
		if l.depth == depth - 1 and l.kind == LineIndex.Line.DIRECTIVE \
				and (l.head == "if" or l.head == "elif" or l.head == "else"):
			if l.head == "else":
				return "else"
			return "%s %s" % [l.head, l.cond_text]
		i -= 1
	return ""


## 哪些标签是「结局」：块里有 `ending`（顶层）
func _ending_labels(lines: Array, labels: Array) -> Dictionary:
	var out: Dictionary = {}
	for k in labels.size():
		var nm := String((labels[k] as Dictionary)["name"])
		var from_no := int((labels[k] as Dictionary)["no"])
		var to_no := int((labels[k + 1] as Dictionary)["no"]) - 1 if k + 1 < labels.size() \
			else lines.size()
		for n in range(from_no, mini(to_no, lines.size()) + 1):
			var l := lines[n - 1] as LineIndex.Line
			if l.kind == LineIndex.Line.DIRECTIVE and l.head == "ending":
				out[nm] = true
				break
	return out


## 哪些标签是「子过程」：块里有 `return`（`call` 的落点，会返回到调用处）
func _sub_labels(lines: Array, labels: Array) -> Dictionary:
	var out: Dictionary = {}
	for k in labels.size():
		var nm := String((labels[k] as Dictionary)["name"])
		var from_no := int((labels[k] as Dictionary)["no"])
		var to_no := int((labels[k + 1] as Dictionary)["no"]) - 1 if k + 1 < labels.size() \
			else lines.size()
		for n in range(from_no, mini(to_no, lines.size()) + 1):
			var l := lines[n - 1] as LineIndex.Line
			if l.kind == LineIndex.Line.DIRECTIVE and l.head == "return" and l.depth == 0:
				out[nm] = true
				break
	return out


func _assign_layers(start: String, edges: Dictionary) -> void:
	var queue: Array = [start]
	_layout[start] = {"layer": 0, "order": 0}
	var order_at: Dictionary = {0: 1}
	while not queue.is_empty():
		var cur := String(queue.pop_front())
		var cur_layer := int((_layout[cur] as Dictionary)["layer"])
		for e in (edges.get(cur, []) as Array):
			var to := String((e as Dictionary)["to"])
			if _layout.has(to):
				continue
			var l := cur_layer + 1
			var o := int(order_at.get(l, 0))
			order_at[l] = o + 1
			_layout[to] = {"layer": l, "order": o}
			queue.append(to)


func _max_layer() -> int:
	var m := 0
	for k in _layout.keys():
		m = maxi(m, int((_layout[k] as Dictionary)["layer"]))
	return m


# ---------------------------------------------------------------------------
# 节点
# ---------------------------------------------------------------------------

func _make_node(name: String, no: int, exits: Array, is_orphan: bool,
		lines: Array, is_sub: bool = false, called_by: Array = [],
		is_start: bool = false, is_ending: bool = false, note: String = "") -> GraphNode:
	var node := GraphNode.new()
	node.name = "n_%s" % name
	var st := _node_style(is_orphan, is_sub, is_start, is_ending)
	node.title = "%s%s" % [String(st[0]), name]
	node.custom_minimum_size = Vector2(NODE_W, 0)
	node.draggable = true

	# 主题：GraphNode 的标题栏与面板都要单独设，否则在深色界面上会是浅色
	var title_color: Color = st[1]
	var edge: Color = title_color
	edge.a = 0.55
	node.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_ELEV, 6, 0, 0, edge, 1))
	node.add_theme_stylebox_override("titlebar",
		EdTheme.sb(EdTheme.BG_PANEL, 6, 8, 5, edge, 1))
	node.add_theme_stylebox_override("titlebar_selected",
		EdTheme.sb(EdTheme.SEL_BG, 6, 8, 5, EdTheme.ACCENT, 1))
	node.add_theme_color_override("title_color", title_color)
	node.add_theme_font_override("title_font", EdTheme.mono())
	node.add_theme_font_size_override("title_font_size", EdTheme.FS_UI)

	var info := Label.new()
	info.text = _node_summary(lines, no)
	info.add_theme_font_override("font", EdTheme.ui())
	info.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	info.add_theme_color_override("font_color", EdTheme.TEXT_DIM)
	info.custom_minimum_size = Vector2(NODE_W - 20, 0)
	node.add_child(info)

	# 第二行：备注（`label X # 备注`）与 call / return 的标注
	var note_l := Label.new()
	note_l.text = _node_note(exits, is_sub, called_by, note, is_ending)
	note_l.visible = not note_l.text.is_empty()
	note_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note_l.add_theme_font_override("font", EdTheme.ui())
	note_l.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	note_l.add_theme_color_override("font_color", EdTheme.ACCENT_DIM)
	note_l.custom_minimum_size = Vector2(NODE_W - 20, 0)
	node.add_child(note_l)

	# 出端口（右）/ 入端口（左）。GraphNode 的 slot 索引对应**子节点索引**，
	# 所以 set_slot 必须在 add_child 之后调用。
	node.set_slot(0, true, 0, EdTheme.ACCENT, true, 0, EdTheme.ACCENT)
	node.set_slot(1, false, 0, EdTheme.ACCENT_DIM, false, 0, EdTheme.ACCENT_DIM)

	# 出口信息**不放在节点里**（那会把节点撑得很高，`_fit` 只好把整张图缩得很小、
	# 看着又挤又糊）。改由「鼠标悬停在连线上」展示，并且**点连线直接跳过去** ——
	# 见 `_update_hover` / `_on_graph_gui`。

	node.tooltip_text = "第 %d 行 · %d 个出口%s\n双击跳到剧本块" % [
		no, exits.size(), ("\n%s" % note_l.text) if not note_l.text.is_empty() else ""]
	node.gui_input.connect(_on_node_input.bind(node))
	return node


## 节点的「身份」→ [标题前缀, 颜色]。
##
## 一个节点可能同时符合多个身份，按「越需要提醒的越优先」排：
## 孤儿（走不到）> 结局（流程终点）> 子过程（会被 call）> 起点。
func _node_style(is_orphan: bool, is_sub: bool, is_start: bool, is_ending: bool) -> Array:
	if is_orphan:
		return ["⚠ ", EdTheme.WARN]
	if is_ending:
		return ["★ ", ENDING_COLOR]
	if is_sub:
		return ["↩ ", EdTheme.ACCENT]
	if is_start:
		return ["▶ ", EdTheme.OK]
	return ["", EdTheme.SYN_LABEL]


# ---------------------------------------------------------------------------
# 连线悬停提示
# ---------------------------------------------------------------------------

func _on_graph_gui(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		_update_hover((e as InputEventMouseMotion).position)
		return
	# **双击连线跳过去**：到剧本块里定位到这条边的来源行。
	#
	# ⚠️ 两个坑都踩过，所以这里的时序很讲究：
	#
	# 1. **单击不行** —— 会和 `GraphEdit` 自己的鼠标处理打架
	#    （单击背景取消选中 / 起框选、按在端口附近开始拉线）。
	# 2. **按下就跳也不行** —— 双击的第一下会被它当成「按在端口上开始拉线」，
	#    而我们一按就切页走了，它**永远收不到「松开」**，
	#    于是内部状态停在「正在连线」，切回来时还挂着一条橡皮筋
	#    （用户描述成「像多了一个鼠标按住一个点」）。
	#
	# 所以：按下时只**记下**目标，等**松开**再跳；而且用 `call_deferred`
	# 让 `GraphEdit` 先把这次松开处理完。
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_pending_jump = _connection_line_at(mb.position) if mb.double_click else 0
			return
		if _pending_jump > 0:
			_goto_line.call_deferred(_pending_jump)
			_pending_jump = 0


## 鼠标位置落在哪条连线上？返回那条边的**来源行号**（没命中返回 0）
func _connection_line_at(local: Vector2) -> int:
	if _graph == null:
		return 0
	var hit: Dictionary = _graph.get_closest_connection_at_point(local, HOVER_DIST)
	if hit.is_empty():
		return 0
	var key := "%s>%s" % [String(hit.get("from_node", "")), String(hit.get("to_node", ""))]
	var e: Dictionary = _edge_by_pair.get(key, {})
	return int(e.get("line", 0))


func _update_hover(local: Vector2) -> void:
	if _graph == null:
		return
	var hit: Dictionary = _graph.get_closest_connection_at_point(local, HOVER_DIST)
	if hit.is_empty():
		_clear_hover()
		return
	var key := "%s>%s" % [String(hit.get("from_node", "")), String(hit.get("to_node", ""))]
	if key == String(_hover.get("key", "")):
		_place_tip(local)
		return
	_clear_hover()
	_hover = {"key": key, "hit": hit}
	_tip_label.text = _edge_text(key)
	_tip.size = _tip.get_combined_minimum_size()
	_tip.visible = true
	_place_tip(local)
	# 顺带把这条线加粗 —— 鼠标扫过一堆线时，得看清是哪一条
	_graph.set_connection_activity(String(hit["from_node"]), int(hit["from_port"]),
		String(hit["to_node"]), int(hit["to_port"]), 1.0)


## 连线的说明文字：`源 → 目标` + 类型 / 行号 / 条件
func _edge_text(key: String) -> String:
	var e: Dictionary = _edge_by_pair.get(key, {})
	var parts := key.split(">")
	var from_name := String(parts[0]) if parts.size() > 0 else ""
	var to_name := String(parts[1]) if parts.size() > 1 else ""
	var bits := PackedStringArray()
	bits.append(String(KIND_LABELS.get(String(e.get("kind", "")), "→")))
	if int(e.get("line", 0)) > 0:
		bits.append("第 %d 行" % int(e["line"]))
	var cond := String(e.get("cond", ""))
	if not cond.is_empty():
		bits.append(cond)
	return "%s → %s\n%s" % [_label_of_node(from_name), _label_of_node(to_name),
		" · ".join(bits)]


## 节点名（`n_标签` / `x_跨文件`）→ 显示用的名字
func _label_of_node(node_name: String) -> String:
	if node_name.begins_with("n_"):
		return node_name.substr(2)
	if node_name.begins_with("x_"):
		for c in _graph.get_children():
			if c is GraphNode and c.name == node_name:
				return String(c.title)
		return node_name.substr(2)
	return node_name


func _place_tip(local: Vector2) -> void:
	if _tip == null or not _tip.visible:
		return
	var p := local + _graph.position + Vector2(16.0, 16.0)
	p.x = minf(p.x, size.x - _tip.size.x - 6.0)
	p.y = minf(p.y, size.y - _tip.size.y - 6.0)
	_tip.position = Vector2(maxf(p.x, 4.0), maxf(p.y, 4.0))


func _clear_hover() -> void:
	if _hover.is_empty():
		return
	var h: Dictionary = _hover.get("hit", {})
	if not h.is_empty() and _graph != null:
		_graph.set_connection_activity(String(h.get("from_node", "")),
			int(h.get("from_port", 0)), String(h.get("to_node", "")),
			int(h.get("to_port", 0)), 0.0)
	_hover = {}
	if _tip != null:
		_tip.visible = false


## 点出口 → 到**剧本块**里定位到那一行
## （与剧本块里的跳转链接保持一致：定位不甩到源码页）
func _goto_line(no: int) -> void:
	if no <= 0 or _ed == null:
		return
	_ed.show_page("table")
	var table: Control = _ed._pages.get("table")
	if table != null and table.has_method("goto_line"):
		table.call("goto_line", no)


## 节点第二行的说明：call / return 的关系。
##
## 为什么不画「return 连回调用点」的边：`call` 可重入，一个子过程常被多处调用
## （`common_pause` 就被两处 call），返回边会变成一堆交叉线。
## 标注能回答同一个问题（谁调它、会不会回来），但不破坏整体结构。
static func _node_note(exits: Array, is_sub: bool, called_by: Array,
		note: String = "", is_ending: bool = false) -> String:
	var parts: PackedStringArray = []
	# 结局标记**始终显示**：它可能同时是孤儿或子过程（标题前缀只放得下一个），
	# 而「这里会结束流程」是最不该被挤掉的信息。
	if is_ending:
		parts.append("★ 结局")
	if not note.is_empty():
		parts.append(note)
	if is_sub:
		var s := "↩ 子过程（有 return）"
		if called_by.size() > 0:
			s += " · 被 %d 处调用：%s" % [called_by.size(), ", ".join(called_by)]
		parts.append(s)
	var calls: PackedStringArray = []
	for e in exits:
		if String((e as Dictionary).get("kind", "")) == "call":
			calls.append(String((e as Dictionary)["to"]))
	if calls.size() > 0:
		parts.append("→ call %s" % ", ".join(calls))
	return "\n".join(parts)


## 跨文件出口（`jump_file` 指向别的剧本）。画成一个虚线感的节点，
## 双击会**打开那个文件并跳到那个标签**。
func _make_external_node(key: String, file: String) -> GraphNode:
	var node := GraphNode.new()
	node.name = "x_%s" % key.replace("/", "_").replace(".", "_").replace(" ", "_").replace("▸", "_")
	node.title = file.get_file()
	node.custom_minimum_size = Vector2(NODE_W, 0)
	node.draggable = true
	node.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG, 6, 0, 0, EdTheme.ACCENT_DIM, 1))
	node.add_theme_stylebox_override("titlebar",
		EdTheme.sb(EdTheme.BG_PANEL, 6, 8, 5, EdTheme.ACCENT_DIM, 1))
	node.add_theme_stylebox_override("titlebar_selected",
		EdTheme.sb(EdTheme.SEL_BG, 6, 8, 5, EdTheme.ACCENT, 1))
	node.add_theme_color_override("title_color", EdTheme.ACCENT)
	node.add_theme_font_override("title_font", EdTheme.mono())
	node.add_theme_font_size_override("title_font_size", EdTheme.FS_UI)

	var info := Label.new()
	info.text = "▸ %s\n（另一个剧本文件）" % key.split(" ▸ ")[1] if key.contains(" ▸ ") else key
	info.add_theme_font_override("font", EdTheme.ui())
	info.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	info.add_theme_color_override("font_color", EdTheme.TEXT_DIM)
	info.custom_minimum_size = Vector2(NODE_W - 20, 0)
	node.add_child(info)
	node.set_slot(0, true, 0, EdTheme.ACCENT_DIM, true, 0, EdTheme.ACCENT_DIM)
	node.set_meta("external_file", file)
	node.set_meta("external_label", key.split(" ▸ ")[1] if key.contains(" ▸ ") else "")
	node.tooltip_text = "跨文件跳转：%s\n双击打开并跳过去" % key
	node.gui_input.connect(_on_node_input.bind(node))
	return node


func _node_summary(lines: Array, from_no: int) -> String:
	# 统计这个标签块里有多少句台词
	var says := 0
	var n := from_no
	while n <= lines.size():
		var l := lines[n - 1] as LineIndex.Line
		if l.kind == LineIndex.Line.LABEL and n != from_no:
			break
		if l.is_say():
			says += 1
		n += 1
	return "第 %d 行 · %d 句" % [from_no, says]


## **双击**节点才跳转。
##
## 原来接的是 `GraphEdit.node_selected` —— 那个信号在**按下**时就发，
## 于是想拖动节点、或者鼠标扫过节点，都会立刻跳到源码页，
## 图根本没法用。双击既不干扰拖拽，也不怕扫过。
func _on_node_input(event: InputEvent, node: GraphNode) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT or not mb.double_click:
		return
	_activate_node(node)
	accept_event()


func _activate_node(node: GraphNode) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node.has_meta("external_file"):
		var file := String(node.get_meta("external_file"))
		var label := String(node.get_meta("external_label"))
		if not file.is_empty() and _ed.has_method("_open_at_label"):
			_ed.call("_open_at_label", file, label)
		return
	var nm := String(node.name)
	if not nm.begins_with("n_"):
		return
	var label2 := nm.substr(2)
	var no: int = _ed.doc.label_line(label2)
	if no > 0:
		_ed.goto_source(no)


## 把整张图缩放到刚好装进窗口。
##
## 不能写死 zoom —— 序章 11 个标签、第一章可能 40 个，同一套缩放值
## 不是溢出就是小得看不清。这里按节点包围盒反算。
## 缩放要有**可读下限**：一条 11 个节点的链，硬要「全塞进窗口」会缩到 39%，
## 字全糊了 —— 那才是用户说的「太紧凑」。
## 所以初始只保证「竖着放得下、字看得清」，横向超出就横向滚（流程图本来就该这么看）。
## 「适应窗口」按钮仍然允许缩得更小（那是用户明确要的全局概览）。
func _fit(min_zoom: float = 0.2) -> void:
	if _graph == null or _graph.size.x < 10.0:
		return
	var rect := Rect2()
	var first := true
	for c in _graph.get_children():
		if not (c is GraphNode):
			continue
		var n := c as GraphNode
		var r := Rect2(n.position_offset, Vector2(NODE_W + 40.0, 96.0))
		rect = r if first else rect.merge(r)
		first = false
	if first:
		return

	var pad := 56.0
	var avail := _graph.size - Vector2(pad * 2.0, pad * 2.0)
	var z := minf(avail.x / maxf(rect.size.x, 1.0), avail.y / maxf(rect.size.y, 1.0))
	_graph.zoom = clampf(z, min_zoom, 1.0)
	_graph.scroll_offset = rect.position - Vector2(pad, pad)
