extends RefCounted

## GVS 行分类器 —— 编辑器的保真根基
##
## 为什么需要它：`GvsParser` 是「编译式」的，它把剧本编译成扁平指令数组，
## 途中丢掉了三样东西 —— 注释（`strip_comment`）、缩进（`strip_edges`）、空行。
## 编辑器如果拿编译结果来重建文本，作者的注释会被清空，那是灾难。
##
## 所以这里做一件不同的事：**逐行分类，原文一字不改地留着**。
## 编辑时只替换被改动的那一行，其余行原样搬运 —— 保真度 100%。
##
## 判定规则**必须与 `GvsParser.feed()` 逐条一致**，否则会出现
## 「编辑器显示的是对白、游戏却当成指令」这种最难查的偏差。
## 所以注释剥离、关键字表、对白切分全部直接调 `GvsParser` 的静态工具，
## 不自己重写一份。
##
## 用法：
##     var doc := LineIndex.parse(text)
##     for line in doc["lines"]:
##         print(line.no, line.kind_name(), line.raw)


const GvsParser = preload("res://scripts/core/gvs_parser.gd")


# ---------------------------------------------------------------------------
# 行
# ---------------------------------------------------------------------------

class Line extends RefCounted:
	const BLANK := 0
	const COMMENT := 1
	const LABEL := 2
	const DIRECTIVE := 3
	const DIALOGUE := 4
	const CHOICE_OPTION := 5
	const KIND_NAMES := ["blank", "comment", "label", "directive", "dialogue", "choice"]

	## 产出 `say` 指令的关键字（旁白）
	const SAY_KEYWORDS := ["narr", "narration"]

	var no: int = 0                    ## 1 基行号
	var raw: String = ""               ## 原始行，一字不改
	var kind: int = BLANK
	var depth: int = 0                 ## 所属块层级（0 = 顶层）
	var head: String = ""              ## 行首关键字；对白行为空
	var args: PackedStringArray = PackedStringArray()   ## 位置参数（不含 key=value）
	var params: Dictionary = {}        ## key=value 参数
	var speaker: String = ""           ## 对白：说话人
	var expr: String = ""              ## 对白：行内表情（角色@表情: 文本）
	var text: String = ""              ## 对白文本 / 选项文本
	var label: String = ""             ## label 名 / jump 目标 / 选项跳转目标
	var file: String = ""              ## jump_file 的目标文件
	var cond_text: String = ""         ## if / elif 的原始条件文本
	var block_path: PackedStringArray = PackedStringArray()  ## 嵌套路径，如 ["if","choice"]

	func kind_name() -> String:
		return KIND_NAMES[kind]

	## 这一行会不会产出一条 `say` 指令
	func is_say() -> bool:
		if kind == DIALOGUE:
			return true
		return kind == DIRECTIVE and SAY_KEYWORDS.has(head)

	## 这一行会不会产出一条 `choice` 指令
	func is_choice_start() -> bool:
		return kind == DIRECTIVE and head == "choice"

	## 块的开括号（if / choice / together）
	func opens_block() -> bool:
		return kind == DIRECTIVE \
			and (head == "if" or head == "choice" or head == "together")

	## 块的闭括号
	func closes_block() -> bool:
		return kind == DIRECTIVE and head == "end"

	## 可编辑的行：对白与选项文本。注释、指令、标签一律只读（防止误伤）
	func is_editable_text() -> bool:
		return kind == DIALOGUE or kind == CHOICE_OPTION

	## 调试用
	func describe() -> String:
		return "#%d [%s d%d] %s" % [no, kind_name(), depth, raw]


# ---------------------------------------------------------------------------
# 块
# ---------------------------------------------------------------------------

class Block extends RefCounted:
	var kind: String = ""      ## "if" / "choice"
	var start_line: int = 0    ## if / choice 所在行
	var end_line: int = 0      ## end 所在行
	var depth: int = 0
	var cond_text: String = ""
	var branches: Array = []   ## elif / else 的行号（仅 if 块）

	func span() -> int:
		return maxi(0, end_line - start_line + 1)


# ---------------------------------------------------------------------------
# 解析
# ---------------------------------------------------------------------------

## 把剧本全文切成行。
##
## 返回 {"lines": Array[Line], "blocks": Array[Block], "errors": Array[String]}
## errors 是**分类器自己**发现的问题（未闭合块、多余的 end），
## 语法层面的错误仍由 `ScriptAudit` 负责，两者互补。
static func parse(text: String) -> Dictionary:
	return parse_raw(text.split("\n"))


## 从「已经是行数组」的原文解析。
##
## 编辑器内部始终把文档存成行数组，每次改动后重新分类 —— 走这条入口
## 可以省掉 join 再 split 的一次无谓拷贝。
static func parse_raw(raw_lines: PackedStringArray) -> Dictionary:
	var lines: Array = []
	var blocks: Array = []
	var errors: Array = []

	var stack: Array = []      # 元素是 Block

	var n := 1
	for raw in raw_lines:
		var line := Line.new()
		line.no = n
		line.raw = raw
		_classify(line, raw, stack)
		lines.append(line)

		# 块栈维护放在分类之后 —— 分类需要知道「我在 choice 里吗」，
		# 那是这一行**之前**的栈状态。
		_update_stack(line, stack, blocks, errors, n)
		n += 1

	for b in stack:
		errors.append("第 %d 行的 %s 块没有闭合" % [(b as Block).start_line, (b as Block).kind])

	return {"lines": lines, "blocks": blocks, "errors": errors}


## 单行分类。stack 是「这一行之前」的块栈。
static func _classify(line: Line, raw: String, stack: Array) -> void:
	line.block_path = PackedStringArray(_path_of(stack))
	line.depth = stack.size()

	# 与 GvsParser.Builder.run() 完全相同的规范化顺序
	var code := GvsParser.strip_comment(raw).replace("\t", " ").strip_edges()
	if code.is_empty():
		# 空行与「只含注释的行」要分开 —— 注释行在折叠时应当跟着块走，
		# 空行则无所谓。判断依据是剥注释后为空、但原文非空。
		line.kind = Line.COMMENT if not raw.strip_edges().is_empty() else Line.BLANK
		return

	var tokens := code.split(" ", false)
	var head := tokens[0] if tokens.size() > 0 else ""

	# 选项块内部的裸行按「选项」处理（与 Builder.feed 的第一条分支一致）
	if not stack.is_empty() and (stack.back() as Block).kind == "choice" and head != "end":
		line.kind = Line.CHOICE_OPTION
		_parse_option(line, code)
		return

	if head == "label":
		line.kind = Line.LABEL
		line.head = "label"
		line.label = tokens[1] if tokens.size() > 1 else ""
		return

	if not GvsParser.is_keyword(head):
		# 对白 / 旁白
		line.kind = Line.DIALOGUE
		_parse_dialogue(line, code)
		return

	line.kind = Line.DIRECTIVE
	line.head = head
	_parse_directive(line, code, tokens)


## 指令行的参数切分。
##
## GVS 的参数形态有两种：
##   位置参数   `show alice expr=normal` 里的 `alice`
##   kv 参数    `expr=normal`
## 位置参数的个数因指令而异（`expr alice smile` 有两个），
## 而 `move alice x=960` 这种「位置参数后面直接跟 kv」也很常见，
## 所以统一取「从第 2 个词起、连续的、不含 = 的词」作为位置参数，
## 遇到第一个含 = 的词就停下来交给 kv。
static func _parse_directive(line: Line, code: String, tokens: PackedStringArray) -> void:
	var args := PackedStringArray()
	var i := 1
	while i < tokens.size() and not tokens[i].contains("="):
		args.append(tokens[i])
		i += 1
	line.args = args

	# 特殊形态单独处理，它们的「参数」不是普通 kv
	match line.head:
		"jump", "goto":
			line.label = args[0] if args.size() > 0 else ""
			return
		"call":
			line.label = args[0] if args.size() > 0 else ""
			# 参数（具名 `who=alice` / 位置 `alice`）要留给变量清单 ——
			# 子过程里的 `{$who}` 读的就是它，不认的话会被误报成「只读不写」。
			line.params = GvsParser.parse_kv(tokens, 1)
			return
		"jump_file":
			line.file = args[0] if args.size() > 0 else ""
			line.label = args[1] if args.size() > 1 else ""
			return
		"if", "elif":
			# 条件表达式整体留着 —— 它的语法是 `flag X` / `affection X >= 1` /
			# `cycle >= 2`，不是 kv，硬拆反而会丢信息
			line.cond_text = " ".join(tokens.slice(1))
			line.params = GvsParser.parse_kv(tokens, 1)
			return
		"else", "end", "return", "wait_click", "pause", "clear":
			line.params = {}
			return
		"narr", "narration":
			# 旁白：`narr 文本`，文本可能含空格，直接取整行剩余
			var body := ""
			if code.contains(" "):
				body = code.substr(code.find(" ") + 1).strip_edges()
			line.text = GvsParser.unquote(body)
			return
		"wait":
			line.params = {"duration": float(args[0].to_float()) if args.size() > 0 else 0.0}
			return
		"ending":
			line.label = args[0] if args.size() > 0 else ""
			line.text = GvsParser.unquote(" ".join(args.slice(1))) if args.size() > 1 else ""
			return
		"chapter":
			line.text = GvsParser.unquote(" ".join(args))
			return
		"choice":
			line.params = {}
			return

	# 其余：位置参数 + kv
	line.params = GvsParser.parse_kv(tokens, i)


## 对白切分。**必须与 GvsParser.Builder._do_dialogue 完全一致**。
##
## 三种形态：
##     "旁白文本"              引号开头 → 旁白
##     alice: 文本             角色: 文本
##     alice@smile: 文本       角色@表情: 文本
## 其余一律当无主对白。
static func _parse_dialogue(line: Line, code: String) -> void:
	if code.begins_with("\"") or code.begins_with("'"):
		line.text = GvsParser.unquote(code)
		return

	var colon := code.find(":")
	if colon > 0:
		var prefix := code.substr(0, colon).strip_edges()
		# 长度 24 的上限是解析器定的：防止把一句带冒号的正常台词误判成角色名
		if not prefix.is_empty() and not prefix.contains(" ") and prefix.length() <= 24:
			var at := prefix.find("@")
			if at > 0:
				line.speaker = prefix.substr(0, at)
				line.expr = prefix.substr(at + 1)
			else:
				line.speaker = prefix
			line.text = code.substr(colon + 1).strip_edges()
			return

	line.text = code


## 选项行：`"选项文本" -> 目标标签`
static func _parse_option(line: Line, code: String) -> void:
	var arrow := code.find("->")
	if arrow == -1:
		line.text = GvsParser.unquote(code)
		return
	line.text = GvsParser.unquote(code.substr(0, arrow).strip_edges())
	line.label = code.substr(arrow + 2).strip_edges()


# ---------------------------------------------------------------------------
# 块栈
# ---------------------------------------------------------------------------

static func _path_of(stack: Array) -> Array:
	var out: Array = []
	for b in stack:
		out.append((b as Block).kind)
	return out


static func _update_stack(line: Line, stack: Array, blocks: Array,
		errors: Array, lineno: int) -> void:
	if line.kind != Line.DIRECTIVE:
		return
	match line.head:
		"if":
			var b := Block.new()
			b.kind = "if"
			b.start_line = lineno
			b.depth = stack.size()
			b.cond_text = line.cond_text
			stack.append(b)
			blocks.append(b)
		"choice":
			var b := Block.new()
			b.kind = "choice"
			b.start_line = lineno
			b.depth = stack.size()
			stack.append(b)
			blocks.append(b)
		"together":
			# 演出并行组：`together … end`。块内只放非阻塞的演出 / 音频指令，
			# 但那属于语义校验（GvsParser 负责），行分类器只管缩进与折叠。
			var b := Block.new()
			b.kind = "together"
			b.start_line = lineno
			b.depth = stack.size()
			stack.append(b)
			blocks.append(b)
		"elif", "else":
			if stack.is_empty() or (stack.back() as Block).kind != "if":
				errors.append("第 %d 行的 %s 没有对应的 if" % [lineno, line.head])
			else:
				(stack.back() as Block).branches.append(lineno)
				# 分支关键字与它的 if 同级，不能显示成块内内容
				line.depth = stack.size() - 1
				line.block_path = PackedStringArray(_path_of(stack.slice(0, stack.size() - 1)))
		"end":
			if stack.is_empty():
				errors.append("第 %d 行有多余的 end" % lineno)
				return
			var b: Block = stack.pop_back()
			b.end_line = lineno
			# end 与它的开括号同级 —— 分类时用的是 pop **之前**的深度，
			# 这里必须按 pop 之后修正，否则折叠与缩进都会错一层
			line.depth = stack.size()
			line.block_path = PackedStringArray(_path_of(stack))


# ---------------------------------------------------------------------------
# 查询辅助
# ---------------------------------------------------------------------------

## 全文里所有会产出 say 的行
static func say_lines(lines: Array) -> Array:
	var out: Array = []
	for l in lines:
		if (l as Line).is_say():
			out.append(l)
	return out


## 行号 → Line
static func by_number(lines: Array, no: int) -> Line:
	for l in lines:
		if (l as Line).no == no:
			return l
	return null


## 某个标签所在的行号；找不到返回 -1
static func find_label(lines: Array, name: String) -> int:
	for l in lines:
		var line := l as Line
		if line.kind == Line.LABEL and line.label == name:
			return line.no
	return -1


## 全文出现过的所有标签名（按出现顺序）
static func all_labels(lines: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for l in lines:
		var line := l as Line
		if line.kind == Line.LABEL and not line.label.is_empty():
			out.append(line.label)
	return out


## 全文里所有被引用到的标签（jump / call / 选项跳转）
static func referenced_labels(lines: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for l in lines:
		var line := l as Line
		if line.kind == Line.DIRECTIVE and (line.head == "jump" or line.head == "goto" \
				or line.head == "call") and not line.label.is_empty():
			out.append(line.label)
		elif line.kind == Line.CHOICE_OPTION and not line.label.is_empty():
			out.append(line.label)
	return out


## 全文里被 flag 指令置位的旗标名
static func set_flags(lines: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for l in lines:
		var line := l as Line
		if line.kind == Line.DIRECTIVE and line.head == "flag" and line.args.size() > 0:
			out.append(line.args[0])
	return out


## 包含某一行的所有块（由外到内）。用于「这一行在哪个 if / choice 里」的提示。
static func enclosing_blocks(blocks: Array, no: int) -> Array:
	var out: Array = []
	for b in blocks:
		var blk := b as Block
		if no >= blk.start_line and (blk.end_line == 0 or no <= blk.end_line):
			out.append(blk)
	return out


## 把行数组拼回全文。
##
## **保真的关键**：每行取的是 `raw`（一字未改的原文），
## 所以只要没被编辑过，拼回去和原文件**逐字节相同** —— 注释、空行、
## 缩进风格、行尾空格全部原样保留。编辑时只替换改动的那几行的 raw。
static func join_text(lines: Array) -> String:
	var out := PackedStringArray()
	for l in lines:
		out.append((l as Line).raw)
	return "\n".join(out)
