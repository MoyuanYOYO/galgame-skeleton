extends Node

## 编辑器核心自测（headless 可跑）
##
## 跑法：
##   godot --headless --path . res://tools/editor/tests/core_test.tscn
##
## 最要紧的一条断言是「逐字节保真」：把剧本解析成行、再拼回去，
## 必须与原文件**完全相同**。它一旦不成立，编辑器每保存一次就会
## 悄悄吃掉作者的注释与空行 —— 那是最不可接受的失败模式，
## 所以放在第一条，且用字节级比较而不是「看起来差不多」。

const LineIndex = preload("res://tools/editor/core/line_index.gd")
const ScriptDoc = preload("res://tools/editor/core/script_doc.gd")
const ProjectIndex = preload("res://tools/editor/core/project_index.gd")
const FileWatcher = preload("res://tools/editor/core/file_watcher.gd")
const GvsParser = preload("res://scripts/core/gvs_parser.gd")
const ScriptAudit = preload("res://scripts/core/script_audit.gd")
const ScriptStats = preload("res://scripts/core/script_stats.gd")

var _pass := 0
var _fail := 0
var _section := ""


func _ready() -> void:
	print("=== 编辑器核心自测 ===")

	_test_fidelity()
	_test_line_kinds()
	_test_dialogue_parsing()
	_test_block_structure()
	_test_parser_agreement()
	_test_doc_editing()
	_test_doc_undo()
	_test_doc_save()
	_test_directive_params()
	_test_line_state()
	_test_project_index()
	_test_file_watcher()

	print("")
	if _fail == 0:
		print("=== ALL OK  %d 项 ===" % _pass)
		get_tree().quit(0)
	else:
		print("=== FAILED  %d 通过 / %d 失败 ===" % [_pass, _fail])
		get_tree().quit(1)


# ---------------------------------------------------------------------------

func _sec(name: String) -> void:
	_section = name
	print("\n[%s]" % name)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("  FAIL  %s" % msg)


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


# ---------------------------------------------------------------------------
# 1. 保真
# ---------------------------------------------------------------------------

func _test_fidelity() -> void:
	_sec("逐字节保真")

	for path in ScriptStats.script_files():
		var text := _read(String(path))
		if text.is_empty():
			continue
		var r := LineIndex.parse(text)
		var back := LineIndex.join_text(r["lines"])
		_ok(back == text, "%s 拼回后必须与原文件逐字节相同" % String(path).get_file())
		# 顺带量一下差异有多大，出问题时便于定位
		if back != text:
			print("      原文 %d 字节，拼回 %d 字节" % [text.length(), back.length()])

	# 边界：空文件、只有换行、没有末尾换行
	var cases := ["", "\n", "a", "a\n", "a\n\nb", "\n\n\n", "  \n\t\n"]
	for c in cases:
		var r2 := LineIndex.parse(String(c))
		_ok(LineIndex.join_text(r2["lines"]) == String(c),
			"边界文本 %s 保真" % JSON.stringify(c))


# ---------------------------------------------------------------------------
# 2. 行类型
# ---------------------------------------------------------------------------

func _test_line_kinds() -> void:
	_sec("行类型分类")

	var text := _read("res://data/scripts/prologue.gvs")
	var r := LineIndex.parse(text)
	var lines: Array = r["lines"]

	var counts := {}
	for l in lines:
		var n := (l as LineIndex.Line).kind_name()
		counts[n] = int(counts.get(n, 0)) + 1

	_ok(int(counts.get("label", 0)) == 11,
		"序章应有 11 个 label，实得 %d" % int(counts.get("label", 0)))
	_ok(int(counts.get("blank", 0)) > 20,
		"空行应被识别出来（实得 %d）" % int(counts.get("blank", 0)))
	_ok(int(counts.get("comment", 0)) > 10,
		"注释行应被识别出来（实得 %d）" % int(counts.get("comment", 0)))
	_ok(int(counts.get("choice", 0)) == 4,
		"序章应有 4 个选项行（两组 choice × 2），实得 %d" % int(counts.get("choice", 0)))
	_ok(int(counts.get("dialogue", 0)) > 0, "应有对白行")

	# 注释内容必须原样留着（这是编辑器的立身之本）
	var comment_found := false
	for l in lines:
		var line := l as LineIndex.Line
		if line.kind == LineIndex.Line.COMMENT and line.raw.contains("可重播片段"):
			comment_found = true
			break
	_ok(comment_found, "注释原文必须完整保留")

	# 行号必须连续且从 1 开始
	var seq_ok := true
	for i in lines.size():
		if (lines[i] as LineIndex.Line).no != i + 1:
			seq_ok = false
			break
	_ok(seq_ok, "行号必须连续且 1 基")


# ---------------------------------------------------------------------------
# 3. 对白切分
# ---------------------------------------------------------------------------

func _test_dialogue_parsing() -> void:
	_sec("对白切分")

	var r := LineIndex.parse("alice: 早上好。\nalice@smile: 又是游戏。\nnarr 旁白一句。\n\"引号旁白\"\n普通文本行\nbob@angry: 带表情的话")
	var lines: Array = r["lines"]

	var l0 := lines[0] as LineIndex.Line
	_ok(l0.kind == LineIndex.Line.DIALOGUE and l0.speaker == "alice" and l0.text == "早上好。",
		"`alice: 文本` 切分正确")

	var l1 := lines[1] as LineIndex.Line
	_ok(l1.speaker == "alice" and l1.expr == "smile" and l1.text == "又是游戏。",
		"`alice@smile: 文本` 切出表情")

	var l2 := lines[2] as LineIndex.Line
	_ok(l2.kind == LineIndex.Line.DIRECTIVE and l2.is_say() and l2.text == "旁白一句。",
		"`narr 文本` 归为产出 say 的指令行")

	var l3 := lines[3] as LineIndex.Line
	_ok(l3.speaker == "" and l3.text == "引号旁白", "引号开头视为无主旁白")

	var l4 := lines[4] as LineIndex.Line
	_ok(l4.speaker == "" and l4.text == "普通文本行", "无冒号整行当文本")

	var l5 := lines[5] as LineIndex.Line
	_ok(l5.speaker == "bob" and l5.expr == "angry", "`bob@angry:` 正确")

	# 与解析器一致性的边界：冒号前带空格的长句不应被当成角色名
	var r2 := LineIndex.parse("这句 话里有空格: 后面的部分")
	var l6 := r2["lines"][0] as LineIndex.Line
	_ok(l6.speaker == "", "含空格的前缀不应被判成角色名")


# ---------------------------------------------------------------------------
# 4. 块结构
# ---------------------------------------------------------------------------

func _test_block_structure() -> void:
	_sec("块结构")

	var src := "label a\nif flag x\n    alice: 在 if 里\n    choice\n        \"选项\" -> b\n    end\nelse\n    alice: 在 else 里\nend\nalice: 在块外\nlabel b"
	var r := LineIndex.parse(src)
	var lines: Array = r["lines"]
	var blocks: Array = r["blocks"]

	_ok(blocks.size() == 2, "应识别出 2 个块（if + choice），实得 %d" % blocks.size())

	var ifb := blocks[0] as LineIndex.Block
	_ok(ifb.kind == "if" and ifb.start_line == 2 and ifb.end_line == 9,
		"if 块应覆盖第 2~9 行（实得 %d~%d）" % [ifb.start_line, ifb.end_line])
	_ok(ifb.branches.size() == 1, "if 块应记录 1 个 else 分支")

	var chb := blocks[1] as LineIndex.Block
	_ok(chb.kind == "choice" and chb.start_line == 4 and chb.end_line == 6,
		"choice 块应覆盖第 4~6 行")

	# 缩进层级：if 与它的 end 同级
	_ok((lines[1] as LineIndex.Line).depth == 0, "if 行 depth=0")
	_ok((lines[2] as LineIndex.Line).depth == 1, "if 内第一行 depth=1")
	_ok((lines[8] as LineIndex.Line).depth == 0, "if 的 end 行应与 if 同级（depth=0）")
	_ok((lines[9] as LineIndex.Line).depth == 0, "块外行 depth=0")

	# 选项行
	var opt := lines[4] as LineIndex.Line
	_ok(opt.kind == LineIndex.Line.CHOICE_OPTION and opt.text == "选项" and opt.label == "b",
		"选项行切出文本与目标标签")

	# 未闭合块要被报出来
	var r2 := LineIndex.parse("if flag x\nalice: 没闭合")
	_ok((r2["errors"] as Array).size() == 1, "未闭合的 if 应报错")

	var r3 := LineIndex.parse("end")
	_ok((r3["errors"] as Array).size() == 1, "多余的 end 应报错")


# ---------------------------------------------------------------------------
# 5. 与解析器的一致性（最关键的交叉验证）
# ---------------------------------------------------------------------------

func _test_parser_agreement() -> void:
	_sec("与 GvsParser 语义一致")

	for path in ScriptStats.script_files():
		var p := String(path)
		var text := _read(p)
		if text.is_empty():
			continue
		var file := p.get_file()

		var parsed := GvsParser.parse(text, file)
		var commands: Array = parsed.get("commands", [])

		var parse_says := 0
		var parse_choices := 0
		var parse_labels := 0
		for c in commands:
			match String((c as Dictionary).get("op", "")):
				"say":
					parse_says += 1
				"choice":
					parse_choices += 1
				"label":
					parse_labels += 1

		var idx := LineIndex.parse(text)
		var idx_says := LineIndex.say_lines(idx["lines"]).size()
		var idx_choices := 0
		for l in idx["lines"]:
			if (l as LineIndex.Line).is_choice_start():
				idx_choices += 1
		var idx_labels := LineIndex.all_labels(idx["lines"]).size()

		_ok(idx_says == parse_says,
			"%s 对白数一致（分类器 %d / 解析器 %d）" % [file, idx_says, parse_says])
		_ok(idx_choices == parse_choices,
			"%s choice 数一致（分类器 %d / 解析器 %d）" % [file, idx_choices, parse_choices])
		_ok(idx_labels == parse_labels,
			"%s label 数一致（分类器 %d / 解析器 %d）" % [file, idx_labels, parse_labels])

		# 每条对白的文本也必须对得上（顺序一致）
		var parse_texts: Array = []
		for c in commands:
			if String((c as Dictionary).get("op", "")) == "say":
				parse_texts.append(String((c as Dictionary).get("text", "")))
		var idx_texts: Array = []
		for l in LineIndex.say_lines(idx["lines"]):
			idx_texts.append((l as LineIndex.Line).text)

		var same := parse_texts.size() == idx_texts.size()
		if same:
			for i in parse_texts.size():
				if parse_texts[i] != idx_texts[i]:
					same = false
					print("      第 %d 条不一致：解析器=%s 分类器=%s"
						% [i, parse_texts[i], idx_texts[i]])
					break
		_ok(same, "%s 每条对白文本按序一致" % file)


# ---------------------------------------------------------------------------
# 6. 文档编辑
# ---------------------------------------------------------------------------

func _test_doc_editing() -> void:
	_sec("文档编辑")

	var tmp := "user://__editor_core_test.gvs"
	var src := _read("res://data/scripts/prologue.gvs")
	_write(tmp, src)

	var doc := ScriptDoc.new()
	_ok(doc.load_from_disk(tmp), "装载临时剧本")
	_ok(doc.line_count() > 200, "行数应 > 200（实得 %d）" % doc.line_count())
	_ok(doc.to_text() == src, "装载后拼回原文一致")

	# 改一行对白文本，其余部分必须原样
	var target := -1
	for l in doc.lines:
		var line := l as LineIndex.Line
		if line.kind == LineIndex.Line.DIALOGUE and line.speaker == "alice" and line.text == "早上好。":
			target = line.no
			break
	_ok(target > 0, "找得到 `alice: 早上好。` 那一行")

	if target > 0:
		doc.set_dialogue_text(target, "晚上好。")
		var after := doc.line_at(target) as LineIndex.Line
		_ok(after.text == "晚上好。", "文本已替换")
		_ok(after.speaker == "alice", "说话人未被破坏")
		_ok(after.raw.begins_with("alice:"), "行首语法保持原样（实得 %s）" % after.raw)

		# 只动了一行：其余行逐字节相同
		var other_same := true
		var orig_lines := src.split("\n")
		var new_lines := doc.to_text().split("\n")
		if orig_lines.size() != new_lines.size():
			other_same = false
		else:
			for i in orig_lines.size():
				if i == target - 1:
					continue
				if orig_lines[i] != new_lines[i]:
					other_same = false
					print("      第 %d 行被意外改动" % (i + 1))
					break
		_ok(other_same, "编辑一行时其余行必须逐字节不变")

	# 表情替换
	if target > 0:
		doc.set_dialogue_expr(target, "smile")
		var after2 := doc.line_at(target) as LineIndex.Line
		_ok(after2.expr == "smile" and after2.speaker == "alice" and after2.text == "晚上好。",
			"改表情不影响说话人与文本（实得 %s）" % after2.raw)

	# 插入与删除
	var n0 := doc.line_count()
	var before_insert := doc.to_text()
	doc.insert_raw(1, PackedStringArray(["# 插入的注释"]))
	_ok(doc.line_count() == n0 + 1, "插入一行")
	_ok(doc.text_at(1) == "# 插入的注释", "插入位置正确")
	_ok((doc.line_at(1) as LineIndex.Line).kind == LineIndex.Line.COMMENT, "插入的注释被正确分类")

	doc.remove_raw(1)
	_ok(doc.line_count() == n0, "删除一行")
	# 比较基准要用「插入前的内容」而不是原始文件 —— 这一节前面已经改过对白了
	_ok(doc.to_text() == before_insert, "删回原状后与插入前逐字节一致")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))


# ---------------------------------------------------------------------------
# 7. 撤销 / 重做
# ---------------------------------------------------------------------------

func _test_doc_undo() -> void:
	_sec("撤销重做")

	var tmp := "user://__editor_undo_test.gvs"
	_write(tmp, "label a\nalice: 原句。\n")

	var doc := ScriptDoc.new()
	doc.load_from_disk(tmp)
	_ok(not doc.can_undo(), "刚装载时无可撤销内容")

	doc.set_dialogue_text(2, "第一改。")
	doc.set_dialogue_text(2, "第二改。")
	_ok(doc.can_undo(), "改动后可撤销")

	doc.undo()
	_ok((doc.line_at(2) as LineIndex.Line).text == "第一改。", "撤销一步回到第一改")
	doc.undo()
	_ok((doc.line_at(2) as LineIndex.Line).text == "原句。", "再撤销回到原句")

	_ok(doc.can_redo(), "可重做")
	doc.redo()
	_ok((doc.line_at(2) as LineIndex.Line).text == "第一改。", "重做回到第一改")

	# 撤销到底之后内容必须与原文完全一致
	doc.undo()
	_ok(doc.to_text() == "label a\nalice: 原句。\n", "撤销到底后与原文逐字节一致")

	# 新编辑应清空重做栈
	doc.set_dialogue_text(2, "新的分支。")
	_ok(not doc.can_redo(), "产生新编辑后重做栈应清空")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))


# ---------------------------------------------------------------------------
# 8. 写盘
# ---------------------------------------------------------------------------

func _test_doc_save() -> void:
	_sec("写盘与外部改动")

	var tmp := "user://__editor_save_test.gvs"
	_write(tmp, "label a\nalice: 原句。\n")

	var doc := ScriptDoc.new()
	doc.load_from_disk(tmp)
	doc.set_dialogue_text(2, "改过了。")

	var r := doc.save()
	_ok(bool(r.get("ok", false)), "写盘成功")
	_ok(not doc.is_dirty(), "写盘后不再是脏状态")
	_ok(_read(tmp).contains("改过了。"), "磁盘内容已更新")

	# 外部改动检测
	_write(tmp, "label a\nalice: 别人改的。\n")
	_ok(doc.has_external_change(), "能检测到外部改动")

	var r2 := doc.save()
	_ok(bool(r2.get("conflict", false)), "外部改动后拒绝静默覆盖（乐观锁生效）")
	_ok(_read(tmp).contains("别人改的。"), "冲突时磁盘内容未被破坏")

	var r3 := doc.save(true)
	_ok(bool(r3.get("ok", false)), "强制覆盖可以写入")
	_ok(_read(tmp).contains("改过了。"), "强制覆盖生效")

	# 重载
	_write(tmp, "label a\nalice: 最新版本。\n")
	_ok(doc.reload_from_disk(), "整体重载成功")
	_ok((doc.line_at(2) as LineIndex.Line).text == "最新版本。", "重载后内容是新版")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))


# ---------------------------------------------------------------------------
# 8.5 指令参数写回
# ---------------------------------------------------------------------------

func _test_directive_params() -> void:
	_sec("指令参数写回")

	var tmp := "user://__editor_param_test.gvs"
	_write(tmp, "move alice fade=0.5\nexpr alice smile\nbg classroom\n")
	var doc := ScriptDoc.new()
	doc.load_from_disk(tmp)

	# 位置参数存在 → 直接替换
	doc.set_directive_arg(1, 0, "bob")
	_ok(doc.text_at(1) == "move bob fade=0.5", "替换位置参数（实得 %s）" % doc.text_at(1))

	# **关键坑**：位置参数不存在时要插到第一个 kv 参数之前。
	# 简单追加到行尾会写成 `move bob fade=0.5 left`，
	# 而解析器只把「连续的、不含 = 的词」当位置参数 —— `left` 会被静默丢掉。
	doc.set_directive_arg(1, 1, "left")
	_ok(doc.text_at(1) == "move bob left fade=0.5",
		"新位置参数插到 kv 之前（实得 %s）" % doc.text_at(1))

	# 用解析器交叉验证：它真的认出了 at=left
	var parsed := GvsParser.parse(doc.to_text(), "t.gvs")
	var at_found := false
	for c in (parsed["commands"] as Array):
		var cmd: Dictionary = c
		if String(cmd.get("op", "")) == "move" and String(cmd.get("at", "")) == "left":
			at_found = true
	_ok(at_found, "解析器认出了新加的位置参数（不是静默丢失）")

	# kv 替换 / 新增 / 删除
	doc.set_directive_param(1, "fade", 1.25)
	_ok(doc.text_at(1).contains("fade=1.25"), "kv 参数被替换（实得 %s）" % doc.text_at(1))
	doc.set_directive_param(1, "ease", "in_cubic")
	_ok(doc.text_at(1).contains("ease=in_cubic"), "kv 参数被追加")
	doc.strip_directive_param(1, "ease")
	_ok(not doc.text_at(1).contains("ease="), "kv 参数被删除（实得 %s）" % doc.text_at(1))

	# 改参数不能重排顺序（剧本要进版本控制，diff 得能读）
	_ok(doc.text_at(1).begins_with("move bob left"), "参数顺序未被重排")

	# 改别的行不受影响
	_ok(doc.text_at(2) == "expr alice smile", "相邻行未被牵连")
	_ok(doc.text_at(3) == "bg classroom", "相邻行未被牵连")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))


# ---------------------------------------------------------------------------
# 9. 素材索引
# ---------------------------------------------------------------------------

## `line_state` = 「到某一行为止的累积舞台状态」。预览窗的「从此处预览」与
## 「跟随光标」都靠它摆画面，所以它必须和**运行时的状态机**给出同样的结果 ——
## 不一致的话，预览会显示一个游戏里根本不存在的画面
## （用户报的「点击预览，预览窗没有正确显示移动后的立绘」）。
##
## 这类 bug 的共同点是**同一个语义在两处各写了一遍**：运行时 `Stage` 一套、
## 编辑器 `line_state` 一套，改了一处忘了另一处。所以下面的断言逐条钉住
## 「两边一致」这个事实，而不是「某个函数被调到了」。
func _test_line_state() -> void:
	_section = "累积舞台状态（line_state）"

	# --- move 的槽位两种写法都认 ---
	# 编辑器「移到」下拉写出来的是 `at=right`。以前只认位置参数（`l.args[1]`），
	# 于是「在编辑器里改完位置，预览纹丝不动」。
	var doc := ScriptDoc.new()
	doc.set_full_text("\n".join([
		"label start", "bg classroom",
		"show alice at=left",
		"move alice at=right",
		"narr 测试。", ""]))
	_ok(String(_char_entry(doc.line_state(5), "alice").get("at", "")) == "right",
		"move 的 at= 写法在累积状态里生效（实得 %s）"
		% String(_char_entry(doc.line_state(5), "alice").get("at", "—")))

	# --- move 到槽位要把 x 交还槽位，y 保留（槽位表里只有横向比率）---
	doc.set_full_text("\n".join([
		"label start", "bg classroom",
		"show alice x=460 y=1600",
		"move alice right",
		"narr 测试。", ""]))
	var c := _char_entry(doc.line_state(5), "alice")
	_ok(String(c.get("at", "")) == "right", "move 到槽位：at 更新")
	_ok(not c.has("x"), "move 到槽位：x 交还槽位（实得 %s）" % str(c.get("x", "—")))
	_ok(c.has("y") and is_equal_approx(float(c["y"]), 1600.0),
		"move 到槽位：y 保留（实得 %s）" % str(c.get("y", "—")))

	# --- show 是「重新定位」：没给的轴回默认 ---
	# `_upsert_char` 只覆盖不删除，所以要显式清 —— 否则
	# `show alice x=460 y=1600` 之后再 `show alice at=left`，预览里还在 460。
	doc.set_full_text("\n".join([
		"label start", "bg classroom",
		"show alice x=460 y=1600",
		"show alice at=left",
		"narr 测试。", ""]))
	var c2 := _char_entry(doc.line_state(5), "alice")
	_ok(String(c2.get("at", "")) == "left", "再 show 到槽位：at 更新")
	_ok(not c2.has("x") and not c2.has("y"),
		"再 show 没给坐标 → 旧坐标被清掉（实得 x=%s y=%s）"
		% [str(c2.get("x", "—")), str(c2.get("y", "—"))])

	# --- move 不会让不在台上的角色出现（与 `Stage.move_char` 一致）---
	doc.set_full_text("\n".join([
		"label start", "bg classroom",
		"move bob right",
		"narr 测试。", ""]))
	_ok((doc.line_state(4).get("chars", []) as Array).is_empty(),
		"move 一个没 show 过的角色：不会凭空出现在台上")


func _char_entry(st: Dictionary, cid: String) -> Dictionary:
	for c in st.get("chars", []):
		if String((c as Dictionary).get("id", "")) == cid:
			return c
	return {}


func _test_project_index() -> void:
	_sec("素材索引")

	# 守卫：编辑器自己留了一份素材目录表（为了能脱离 autoload 静态调用），
	# 那就必须证明这一份没有跑偏 —— 目录约定只能有一个权威。
	var same_dirs := true
	for kind in ScriptAudit.ASSET_DIRS.keys():
		var authority := String(ScriptAudit.ASSET_DIRS[kind])
		var mine := String(ProjectIndex.KIND_DIRS.get(kind, ""))
		if mine != authority:
			same_dirs = false
			print("      %s：编辑器写 %s，权威是 %s" % [kind, mine, authority])
	for kind in ProjectIndex.KIND_DIRS.keys():
		if not ScriptAudit.ASSET_DIRS.has(kind):
			same_dirs = false
			print("      %s：编辑器多出一类，权威表里没有" % kind)
	_ok(same_dirs, "编辑器素材目录表与 ScriptAudit.ASSET_DIRS 完全一致")

	var idx := ProjectIndex.new()
	idx.scan()

	_ok(idx.count("bg") >= 3, "背景应 >= 3（实得 %d）" % idx.count("bg"))
	_ok(idx.count("cg") >= 6, "CG 应 >= 6（实得 %d）" % idx.count("cg"))
	_ok(idx.count("bgm") >= 5, "音乐应 >= 5（实得 %d）" % idx.count("bgm"))
	_ok(idx.count("se") >= 3, "音效应 >= 3（实得 %d）" % idx.count("se"))

	_ok(idx.char_ids().size() >= 2, "角色应 >= 2（实得 %d）" % idx.char_ids().size())
	_ok(idx.char_exprs("alice").size() >= 2, "alice 应有 >= 2 个表情")
	_ok(idx.char_exprs("alice").has("normal"), "alice 有 normal")
	_ok(idx.char_exprs("alice").has("smile"), "alice 有 smile")

	# 尺寸必须真的读出来（验证直读路径可用）
	var bg := idx.get_entry("bg", "classroom")
	_ok(not bg.is_empty(), "取得到 classroom 背景")
	if not bg.is_empty():
		var s: Vector2i = bg.get("size", Vector2i.ZERO)
		_ok(s.x > 0 and s.y > 0, "背景尺寸读出来了（%dx%d）" % [s.x, s.y])
		_ok(s == Vector2i(1920, 1080), "classroom 应为 1920×1080，实得 %dx%d" % [s.x, s.y])

	# 音频时长
	var se := idx.get_entry("se", "bell")
	if not se.is_empty():
		_ok(float(se.get("duration", 0.0)) > 0.0, "音效时长读出来了")

	# 与 ScriptAudit 的交叉验证：索引里有的、剧本引用得到
	var usage := idx.script_usage()
	_ok(usage.has("bg"), "剧本引用了背景")

	# 索引里存在的素材，ScriptAudit 也必须认为存在（两者口径要一致）
	var agree := true
	for kind in ["bg", "cg"]:
		for id in idx.ids(kind):
			if not ScriptAudit.has_real_asset(kind, id):
				agree = false
				print("      %s/%s 索引认为存在，ScriptAudit 说没有" % [kind, id])
	_ok(agree, "索引与 ScriptAudit 的存在性判断一致")

	# 未使用反查
	var unused := idx.unused()
	_ok(unused is Dictionary, "未使用素材反查可运行")

	# 健康检查
	var h := idx.health()
	_ok(h is Array, "健康检查可运行（%d 条）" % h.size())


# ---------------------------------------------------------------------------
# 10. 文件监听
# ---------------------------------------------------------------------------

func _test_file_watcher() -> void:
	_sec("文件监听")

	var tmp := "user://__editor_watch_test.txt"
	_write(tmp, "第一版")

	var w := FileWatcher.new()
	w.watch(tmp)
	_ok(w.is_watching(tmp), "开始监听")

	# 没改动时不应报变化
	w.poll_now()
	var none := w.poll_now()
	_ok(none.is_empty(), "无改动时不报变化")

	# 改内容
	_write(tmp, "第二版内容更长")
	var changed := w.poll_now()
	_ok(changed.size() == 1 and changed[0] == tmp, "改动被检测到")

	# 同一改动只报一次
	var again := w.poll_now()
	_ok(again.is_empty(), "同一改动只报告一次")

	# 等一秒让 mtime 前进，再测「等长替换」（只靠 size 检测不到的那种）
	OS.delay_msec(1100)
	_write(tmp, "第三版内容更长")
	var c2 := w.poll_now()
	_ok(c2.size() == 1, "mtime 变化被检测到")

	w.unwatch(tmp)
	_ok(not w.is_watching(tmp), "取消监听")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))


# ---------------------------------------------------------------------------

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("  无法写入 %s" % path)
		return
	f.store_string(text)
	f.close()
