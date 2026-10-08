extends RefCounted

## 剧本文档 —— 行数组 + 编辑操作 + 写盘 + 外部改动同步
##
## 设计原则（整个编辑器的保真根基）：
##
##   **文档的真实状态是 `_raw`（一串原文行），`lines` 只是派生视图。**
##
## 每次改动后重新分类一遍全文，而不是增量维护行对象 —— 剧本才几百行，
## 重分类是微秒级的事，换来的是「行号、块层级、块路径永远自洽」，
## 不必担心插入/删除后行对象错位。
##
## 保真：没被编辑过的行，`raw` 一字未改。拼回去与原文件**逐字节相同**。
##
## 同步：采用「无脏状态」——改动后自动写盘（默认 500ms 防抖），
## 所以不存在「工具手里攥着未保存改动」这个状态，外部（AI / 文本编辑器）
## 改文件时可以放心整体重载，冲突从根本上消失。
## 写盘前用 mtime + size 做一次乐观锁：不匹配说明有人插队，转为提示。
##
## 撤销靠内存快照栈 —— 因为不再有「不保存就退出」这条退路，
## undo 必须自己扛起来。

const LineIndex = preload("res://tools/editor/core/line_index.gd")

const UNDO_LIMIT := 200
const AUTOSAVE_DELAY_MS := 500

## res:// 路径
var path: String = ""

## 真实状态：原文行
var _raw: PackedStringArray = PackedStringArray()

## 派生视图
var lines: Array = []
var blocks: Array = []
var kind_errors: Array = []

## 同步状态
var disk_text: String = ""
var disk_mtime: int = 0
var disk_size: int = 0
var revision: int = 0            ## 每次内容变化 +1，界面据此决定是否重建
var last_saved_revision: int = 0
var auto_save: bool = true

## 撤销栈：每个元素是当时的 `_raw` 快照
var _undo: Array = []
var _redo: Array = []

## 外部改动的提示（由 FileWatcher 写入，界面显示）
var external_notice: String = ""

var _autosave_deadline: int = 0

## 批量编辑（一次用户操作 = 一个撤销点）
var _batch_depth := 0
var _batch_dirty := false


# ---------------------------------------------------------------------------
# 装载
# ---------------------------------------------------------------------------

func load_from_disk(p: String) -> bool:
	path = p
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var t := f.get_as_text()
	f.close()

	_raw = t.split("\n")
	disk_text = t
	_snapshot_disk_meta()
	_undo.clear()
	_redo.clear()
	revision += 1
	last_saved_revision = revision
	_reparse()
	return true


## 外部改动后整体重载。调用方应先确认没有未保存内容（无脏状态设计下天然满足）。
func reload_from_disk() -> bool:
	if path.is_empty():
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var t := f.get_as_text()
	f.close()
	if t == disk_text:
		return false          # 内容其实没变（mtime 变了但内容相同，比如编辑器重写了一遍）
	_raw = t.split("\n")
	disk_text = t
	_snapshot_disk_meta()
	revision += 1
	last_saved_revision = revision
	_reparse()
	return true


# ---------------------------------------------------------------------------
# 派生视图
# ---------------------------------------------------------------------------

func _reparse() -> void:
	var r := LineIndex.parse_raw(_raw)
	lines = r["lines"]
	blocks = r["blocks"]
	kind_errors = r["errors"]


func raw_lines() -> PackedStringArray:
	return _raw


func to_text() -> String:
	return "\n".join(_raw)


func line_count() -> int:
	return _raw.size()


func line_at(no: int) -> LineIndex.Line:
	if no < 1 or no > lines.size():
		return null
	return lines[no - 1]


func text_at(no: int) -> String:
	if no < 1 or no > _raw.size():
		return ""
	return _raw[no - 1]


func is_dirty() -> bool:
	return revision != last_saved_revision


# ---------------------------------------------------------------------------
# 编辑操作
# ---------------------------------------------------------------------------

## 改动前统一入口：压入撤销快照
##
## 批量模式下（`begin_batch` 之后）不压快照、不发 revision ——
## 快照由 `begin_batch` 压一次，收尾由 `end_batch` 统一做。
## 这样「一次用户操作内部改了好几处」（比如把一行转换成另一种指令）
## 只占**一个**撤销点，Ctrl+Z 一次就能整体退回。
func _begin_edit() -> void:
	if _batch_depth > 0:
		_batch_dirty = true
		return
	_undo.append(_raw.duplicate())
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	_redo.clear()


func _after_edit() -> void:
	if _batch_depth > 0:
		_batch_dirty = true
		# **派生视图必须立刻跟上**：批量里后续操作（比如「先换整行、
		# 再补一个参数」）要按新内容定位，拿旧 `lines` 去改会把前一步覆盖掉。
		# 重分类是微秒级的事，没必要省。
		_reparse()
		return
	revision += 1
	_reparse()
	_schedule_autosave()


## 把接下来的一组改动合并成一个撤销点。必须与 `end_batch` 成对调用。
func begin_batch() -> void:
	if _batch_depth == 0:
		_undo.append(_raw.duplicate())
		if _undo.size() > UNDO_LIMIT:
			_undo.pop_front()
		_redo.clear()
		_batch_dirty = false
	_batch_depth += 1


func end_batch() -> void:
	if _batch_depth <= 0:
		return
	_batch_depth -= 1
	if _batch_depth == 0 and _batch_dirty:
		_batch_dirty = false
		_after_edit()


## 替换某一行的原文
func set_raw(no: int, raw: String) -> bool:
	if no < 1 or no > _raw.size():
		return false
	if _raw[no - 1] == raw:
		return false
	_begin_edit()
	_raw[no - 1] = raw
	_after_edit()
	return true


## 在第 no 行**之前**插入若干行
func insert_raw(no: int, raws: PackedStringArray) -> bool:
	if no < 1 or no > _raw.size() + 1:
		return false
	_begin_edit()
	var out := PackedStringArray()
	for i in range(0, no - 1):
		out.append(_raw[i])
	for r in raws:
		out.append(r)
	for i in range(no - 1, _raw.size()):
		out.append(_raw[i])
	_raw = out
	_after_edit()
	return true


## 删除第 no 行
func remove_raw(no: int) -> bool:
	if no < 1 or no > _raw.size():
		return false
	_begin_edit()
	var out := PackedStringArray()
	for i in range(0, no - 1):
		out.append(_raw[i])
	for i in range(no, _raw.size()):
		out.append(_raw[i])
	_raw = out
	_after_edit()
	return true


## 批量替换一个区间 [from, to] 的行为 raws（1 基，含两端）
func replace_range(from: int, to: int, raws: PackedStringArray) -> bool:
	if from < 1 or to > _raw.size() or from > to:
		return false
	_begin_edit()
	var out := PackedStringArray()
	for i in range(0, from - 1):
		out.append(_raw[i])
	for r in raws:
		out.append(r)
	for i in range(to, _raw.size()):
		out.append(_raw[i])
	_raw = out
	_after_edit()
	return true


## 整篇替换（源码视图用）。
##
## `push_undo` 默认 false —— 源码视图的撤销由 `CodeEdit` 自己管，
## 这里再压一份会让两边互相打架（一个 Ctrl+Z 撤两步）。
## 表格视图那种没有内建撤销的界面才传 true。
func set_full_text(text: String, push_undo: bool = false) -> void:
	if text == to_text():
		return
	if push_undo:
		_begin_edit()
	_raw = text.split("\n")
	_after_edit()


## 只改对白/选项行的文本部分，其余语法原样保留。
##
## 对白行形如 `alice@smile: 早上好。`，只换冒号后面的部分 ——
## 说话人、表情、行首缩进都不动，这是「表格视图改文本」的底层操作。
func set_dialogue_text(no: int, new_text: String) -> bool:
	var line := line_at(no)
	if line == null:
		return false
	var raw := line.raw

	if line.kind == LineIndex.Line.CHOICE_OPTION:
		# 选项行：`"文本" -> 标签`，保留箭头与标签
		var arrow := raw.find("->")
		var suffix := ""
		if arrow != -1:
			suffix = raw.substr(arrow)
		var indent := _leading_space(raw)
		return set_raw(no, "%s\"%s\" %s" % [indent, new_text, suffix])

	if line.kind == LineIndex.Line.DIRECTIVE:
		# 旁白行：`narr 文本` 或 `narr "文本"`
		var head_end := raw.find(" ")
		if head_end == -1:
			return set_raw(no, "%s %s" % [raw, new_text])
		return set_raw(no, "%s %s" % [raw.substr(0, head_end), new_text])

	if line.kind == LineIndex.Line.DIALOGUE:
		var colon := raw.find(":")
		if colon > 0:
			# 保留冒号前的部分（含缩进、角色名、@表情）与冒号后的空格风格
			var prefix := raw.substr(0, colon + 1)
			var had_space := raw.substr(colon + 1).begins_with(" ")
			return set_raw(no, prefix + (" " if had_space else "") + new_text)
		# 无主对白：整行替换，保留缩进
		return set_raw(no, _leading_space(raw) + new_text)

	return false


## 改对白的说话人（保留文本与表情）
## 改对白的说话人（保留文本与表情）。
##
## ⚠️ **旁白行（`narr 文本`）也要能改。** 它在 GVS 里是一条指令而不是对白行，
## 但界面上它就是「说话人 = （旁白）」的一行。以前这里 `kind != DIALOGUE`
## 就 `return false` —— 于是「旁白行改说话人点了没反应」，而新建的行是
## `角色: 台词`（DIALOGUE）所以能改，表现就是「有的行行、有的行不行」（用户报的）。
##
## 两个方向都要转：
##   旁白 → 角色：`narr 文本`   → `alice: 文本`
##   角色 → 旁白：`alice: 文本` → `narr 文本`
func set_dialogue_speaker(no: int, new_speaker: String) -> bool:
	var line := line_at(no)
	if line == null:
		return false
	var raw := line.raw
	var indent := _leading_space(raw)

	# 旁白行 → 只有「改成某个角色」才有意义（改成空还是旁白）
	if line.is_say() and line.kind == LineIndex.Line.DIRECTIVE:
		if new_speaker.is_empty():
			return false
		var body := _say_body(raw, line)
		# 冒号后补一个空格（`alice:文本` 不好看，也和新建行的写法不一致）。
		# 原文自己已经有空格就沿用，别叠成两个。
		if not body.begins_with(" "):
			body = " " + body
		return set_raw(no, "%s%s:%s" % [indent, new_speaker, body])

	if line.kind != LineIndex.Line.DIALOGUE:
		return false

	# 说话人清空 = 变回旁白行。写法统一成 `narr`（`narration` 是别名）。
	if new_speaker.is_empty():
		return set_raw(no, "%snarr %s" % [indent, _say_body(raw, line).lstrip(" ")])

	var colon := raw.find(":")
	var expr_part := ("@" + line.expr) if not line.expr.is_empty() else ""
	return set_raw(no, "%s%s%s:%s" % [indent, new_speaker, expr_part, _say_body(raw, line)])


## 对白 / 旁白行的「正文部分」**原文**。
##
## ⚠️ 不能用 `line.text` —— 那是剥掉行尾注释之后的文本，
## 拿它拼回去会把 `alice: 文本  # 备注` 里的备注弄丢。
static func _say_body(raw: String, line: LineIndex.Line) -> String:
	if line.kind == LineIndex.Line.DIRECTIVE:
		var sp := raw.find(" ")
		return raw.substr(sp + 1) if sp >= 0 else ""
	var colon := raw.find(":")
	return raw.substr(colon + 1) if colon > 0 else " " + line.text


## 改对白的表情（保留说话人与文本）
func set_dialogue_expr(no: int, new_expr: String) -> bool:
	var line := line_at(no)
	if line == null or line.kind != LineIndex.Line.DIALOGUE:
		return false
	var raw := line.raw
	var colon := raw.find(":")
	var body := raw.substr(colon + 1) if colon > 0 else " " + line.text
	var expr_part := ("@" + new_expr) if not new_expr.is_empty() else ""
	return set_raw(no, "%s%s%s:%s" % [_leading_space(raw), line.speaker, expr_part, body])


static func _leading_space(s: String) -> String:
	var i := 0
	while i < s.length() and (s[i] == " " or s[i] == "\t"):
		i += 1
	return s.substr(0, i)


## ---------------------------------------------------------------------------
## 改指令参数（剧本块与源码视图共用）
## ---------------------------------------------------------------------------

## 改位置参数（第 index 个）。
##
## 关键：**没有这个位置参数时要插到第一个 kv 参数之前**，不能简单追加到行尾 ——
## `move alice fade=0.5` 追加 `left` 会变成 `move alice fade=0.5 left`，
## 而解析器只把「连续的、不含 = 的词」当位置参数，`left` 会被**静默丢掉**。
func set_directive_arg(no: int, index: int, value: String) -> bool:
	var line := line_at(no)
	if line == null:
		return false

	if index < line.args.size():
		var span := _arg_span(line.raw, index)
		if span.x < 0:
			return false
		# 写空串 = **把这个位置参数去掉**（`flag f1 true` → `flag f1`，值回到默认 true）。
		# 连同它前面的分隔空白一起删，否则会在行尾留下一个空格。
		if value.is_empty():
			var start := span.x
			while start > 0 and (line.raw[start - 1] == " " or line.raw[start - 1] == "\t"):
				start -= 1
			return set_raw(no, line.raw.substr(0, start) + line.raw.substr(span.x + span.y))
		return set_raw(no, line.raw.substr(0, span.x) + value
			+ line.raw.substr(span.x + span.y))

	# 清空一个**还不存在**的位置参数 = 什么都不用做（别在行尾留一个孤零零的空格）
	if value.is_empty():
		return false

	# 位置参数不存在 → 插到第一个 kv 参数之前
	var raw := line.raw
	var re := RegEx.new()
	if re.compile("[ \\t][A-Za-z_][A-Za-z0-9_]*=") != OK:
		return set_raw(no, raw.rstrip(" ") + " " + value)
	var m := re.search(raw)
	if m != null:
		var cut := m.get_start()
		return set_raw(no, raw.substr(0, cut) + " " + value + raw.substr(cut))
	return set_raw(no, raw.rstrip(" ") + " " + value)


## 替换「从第 index 个位置参数一直到最后」的整段（后面的 kv 参数保留）。
##
## 用于**值本身可能含空格**的位置参数：`ending normal "春日的答案"` 的标题、
## `chapter 序章 · 新学期` 的章节名。它们不是一个词，按词替换只会改掉第一个词、
## 把剩下的留在原地，拼出 `ending normal "新的" 的答案"` 这种东西。
func set_directive_rest(no: int, index: int, value: String) -> bool:
	var line := line_at(no)
	if line == null:
		return false
	var start := _arg_span(line.raw, index)
	if start.x < 0:
		# 还没有这个位置参数 → 走「插到第一个 kv 之前」那套逻辑
		return set_directive_arg(no, index, value)
	var end := start.x + start.y
	var k := index
	while true:
		var sp := _arg_span(line.raw, k + 1)
		if sp.x < 0:
			break
		end = sp.x + sp.y
		k += 1
	return set_raw(no, line.raw.substr(0, start.x) + value + line.raw.substr(end))


## 「吃到行尾」字段的读取（`call 打招呼 who=alice count=2` 里的 `who=alice count=2`）。
##
## 与 `rest` 的区别：`rest` 只吃到**最后一个位置参数**，遇到 kv 就停了；
## `tail` 连 kv 一起吃掉。`call` 的参数两种写法都允许（具名 / 位置），
## 所以只能用 `tail`。
##
## `raw` 是行原文（`Line.raw`），`index` 是字段对应的位置参数下标。
static func directive_tail(raw: String, index: int) -> String:
	var start := _tail_start(raw, index)
	if start < 0:
		return ""
	return raw.substr(start).strip_edges()


## 替换「吃到行尾」的那一段。空串表示清掉这一段（连分隔空白一起）。
func set_directive_tail(no: int, index: int, value: String) -> bool:
	var line := line_at(no)
	if line == null:
		return false
	var start := _tail_start(line.raw, index)
	if start < 0:
		return false
	var head := line.raw.substr(0, start).rstrip(" \t")
	if value.strip_edges().is_empty():
		return set_raw(no, head)
	return set_raw(no, head + " " + value.strip_edges())


## 「吃到行尾」字段的起点：第 index 个位置参数的起点；
## 这个位置参数还不存在时，取**最后一个位置参数之后**；
## 连位置参数都没有时，取指令头之后。
static func _tail_start(raw: String, index: int) -> int:
	var span := _arg_span(raw, index)
	if span.x >= 0:
		return span.x
	var last := index - 1
	while last >= 0:
		var s := _arg_span(raw, last)
		if s.x >= 0:
			return s.x + s.y
		last -= 1
	var i := 0
	var n := raw.length()
	while i < n and (raw[i] == " " or raw[i] == "\t"):
		i += 1
	while i < n and raw[i] != " " and raw[i] != "\t":
		i += 1
	return i


## 第 index 个位置参数在原文里的 [起点, 长度]；找不到返回 (-1, 0)。
## **不能用 `raw.find(旧值)`** —— 旧值可能作为子串出现在别处：
## `flag true_flag true` 里找 `"true"` 会命中名字里的那一段，
## 于是「把值改成 false」会把旗标名改成 `false_flag`。
## 这种损坏不报错、剧本也能解析，只是剧情从此走错 —— 必须按「词」定位。
static func _arg_span(raw: String, index: int) -> Vector2i:
	var i := 0
	var n := raw.length()
	while i < n and (raw[i] == " " or raw[i] == "\t"):
		i += 1                                  # 行首缩进
	while i < n and raw[i] != " " and raw[i] != "\t":
		i += 1                                  # 指令头
	var seen := 0
	while i < n:
		while i < n and (raw[i] == " " or raw[i] == "\t"):
			i += 1
		if i >= n:
			break
		var start := i
		while i < n and raw[i] != " " and raw[i] != "\t":
			i += 1
		if raw.substr(start, i - start).contains("="):
			break                               # 位置参数到此为止
		if seen == index:
			return Vector2i(start, i - start)
		seen += 1
	return Vector2i(-1, 0)


## 改 / 加 kv 参数。用正则只替换那一个 `key=值`，
## **不重新拼整行** —— 重拼会打乱作者的参数顺序，让 diff 变得难读，
## 而剧本是要进版本控制的。
func set_directive_param(no: int, key: String, value: Variant) -> bool:
	var line := line_at(no)
	if line == null:
		return false
	var text := _fmt_param(value)
	var re := RegEx.new()
	if re.compile("(^|[ \\t])%s=\\S+" % key) != OK:
		return false
	if re.search(line.raw) != null:
		return set_raw(no, re.sub(line.raw, "$1%s=%s" % [key, text], true))
	return set_raw(no, line.raw.rstrip(" \t") + " %s=%s" % [key, text])


## 删掉 kv 参数（让解析器的默认值生效）
func strip_directive_param(no: int, key: String) -> bool:
	var line := line_at(no)
	if line == null:
		return false
	var re := RegEx.new()
	if re.compile("[ \\t]%s=\\S+" % key) != OK:
		return false
	return set_raw(no, re.sub(line.raw, "", true).rstrip(" \t"))


static func _fmt_param(v: Variant) -> String:
	match typeof(v):
		TYPE_BOOL:
			return "true" if bool(v) else "false"
		TYPE_INT:
			return str(int(v))
		TYPE_FLOAT:
			var f := float(v)
			if is_equal_approx(f, roundf(f)):
				return str(int(roundf(f)))
			return String.num(f, 2)
	return str(v)


# ---------------------------------------------------------------------------
# 撤销 / 重做
# ---------------------------------------------------------------------------

func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo() -> bool:
	if _undo.is_empty():
		return false
	_redo.append(_raw.duplicate())
	_raw = _undo.pop_back()
	revision += 1
	_reparse()
	_schedule_autosave()
	return true


func redo() -> bool:
	if _redo.is_empty():
		return false
	_undo.append(_raw.duplicate())
	_raw = _redo.pop_back()
	revision += 1
	_reparse()
	_schedule_autosave()
	return true


# ---------------------------------------------------------------------------
# 写盘与外部改动
# ---------------------------------------------------------------------------

func _snapshot_disk_meta() -> void:
	disk_mtime = FileAccess.get_modified_time(path)
	disk_size = _file_size(path)


static func _file_size(p: String) -> int:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n


## 磁盘上的文件是否已经不是我们认识的那一份
func has_external_change() -> bool:
	if path.is_empty():
		return false
	return FileAccess.get_modified_time(path) != disk_mtime \
		or _file_size(path) != disk_size


## 写盘。
##
## 返回 {"ok": bool, "conflict": bool, "message": String}
## conflict 为真表示磁盘上的文件已被别人改过 —— 这时**不写**，
## 交由调用方决定（提示用户 / 重载 / 强制覆盖）。
func save(force: bool = false) -> Dictionary:
	if path.is_empty():
		return {"ok": false, "conflict": false, "message": "没有打开任何文件"}

	if not force and has_external_change():
		return {"ok": false, "conflict": true,
			"message": "文件已被外部修改，本次未写入"}

	var text := to_text()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "conflict": false,
			"message": "无法写入 %s" % path}
	f.store_string(text)
	f.close()

	disk_text = text
	_snapshot_disk_meta()
	last_saved_revision = revision
	_autosave_deadline = 0
	return {"ok": true, "conflict": false, "message": "已保存"}


func _schedule_autosave() -> void:
	if auto_save:
		_autosave_deadline = Time.get_ticks_msec() + AUTOSAVE_DELAY_MS


## 由编辑器每帧调用。返回本次是否真的写了盘（供界面刷新状态）。
func tick_autosave() -> bool:
	if _autosave_deadline == 0:
		return false
	if Time.get_ticks_msec() < _autosave_deadline:
		return false
	_autosave_deadline = 0
	if not is_dirty():
		return false
	var r := save()
	if bool(r.get("conflict", false)):
		external_notice = String(r.get("message", ""))
		return false
	external_notice = ""
	return true


## 丢弃当前内存改动，回到磁盘内容（用于「外部已改，我要加载外部版本」）
func discard_and_reload() -> bool:
	_undo.clear()
	_redo.clear()
	return reload_from_disk()


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

## 会产出 say 的行
func say_lines() -> Array:
	return LineIndex.say_lines(lines)


## 所有选项块
func choice_blocks() -> Array:
	var out: Array = []
	for b in blocks:
		if (b as LineIndex.Block).kind == "choice":
			out.append(b)
	return out


## 标签名 → 行号
func label_line(name: String) -> int:
	return LineIndex.find_label(lines, name)


## 标签的备注：`label X  # 备注文字` 里 `#` 后面的内容。
##
## 用**行尾注释**存备注，不另开 sidecar 文件，因为：
##   - 它跟着剧本走（git、源码视图、别的工具都看得见）；
##   - `LineIndex` 解析前会先 `strip_comment`，所以完全不影响语义；
##   - 剧本块的标签行可以直接编辑它（就一行）。
func label_notes() -> Dictionary:
	var out := {}
	for l in lines:
		var line := l as LineIndex.Line
		if line.kind != LineIndex.Line.LABEL or line.label.is_empty():
			continue
		var h := line.raw.find("#")
		if h < 0:
			continue
		var note := line.raw.substr(h + 1).strip_edges()
		if not note.is_empty():
			out[line.label] = note
	return out


## 全文标签
func labels() -> PackedStringArray:
	return LineIndex.all_labels(lines)


## 某行的状态摘要（给预览窗右侧用）
func line_state(no: int) -> Dictionary:
	var line := line_at(no)
	if line == null:
		return {}
	# 往前回溯，收集「到这一行为止」仍然生效的舞台状态
	var state := {
		"bg": "", "bgm": "", "chars": [], "cg": "", "weather": "",
	}
	for i in range(0, no):
		var l := lines[i] as LineIndex.Line
		if l.kind == LineIndex.Line.DIALOGUE:
			# 对白行也能带表情：`alice@smile: 文本`。
			# `GvsParser._do_dialogue` 把 `@` 后面的东西放进 say 指令的 `expr`，
			# 而 `ScriptRunner` 执行它之前会**先发一条 `expr` 舞台指令** ——
			# 所以「执行到这一行」的画面里，表情是已经变过的。
			# ⚠️ 漏掉这里，预览就永远停在 `show` 时那个表情
			# （用户报的「表情没有变化，只有立绘入场的表情」）。
			# 角色不在台上时不动它 —— 与 `Stage.set_expr` 的「找不到就忽略」一致。
			if not l.speaker.is_empty() and not l.expr.is_empty():
				for c in state["chars"]:
					if String((c as Dictionary).get("id", "")) == l.speaker:
						(c as Dictionary)["expr"] = l.expr
			continue
		if l.kind != LineIndex.Line.DIRECTIVE:
			continue
		match l.head:
			"bg":
				state["bg"] = l.args[0] if l.args.size() > 0 else ""
			"bgm":
				state["bgm"] = l.args[0] if l.args.size() > 0 else ""
			"cg":
				state["cg"] = l.args[0] if l.args.size() > 0 else ""
			"hide_cg":
				state["cg"] = ""
			"weather":
				state["weather"] = l.args[0] if l.args.size() > 0 else ""
			"show":
				var cid := l.args[0] if l.args.size() > 0 else ""
				var entry := {"id": cid,
					"expr": String(l.params.get("expr", "normal")),
					"at": String(l.params.get("at", "center"))}
				for axis in ["x", "y", "scale"]:
					if l.params.has(axis):
						entry[axis] = float(l.params[axis])
				_upsert_char(state["chars"], entry)
				# ⚠️ **`show` 的语义是「重新定位」：没给的轴回到默认。**
				# 而 `_upsert_char` 只覆盖、**不删除** —— 不显式清掉行里没给的坐标，
				# `show alice x=460 y=1600` 之后再 `show alice at=left`，
				# 预览里 alice 还停在 460（游戏里是对的，`Stage.show_char` 每次重置
				# `pos_x` / `pos_y` / `base_scale`）。用户报的「预览没显示移动后的立绘」
				# 就是这一类：**预览的累积状态与运行时的状态机不是同一套规则**。
				for c in state["chars"]:
					if String((c as Dictionary).get("id", "")) != cid:
						continue
					for axis in ["x", "y", "scale"]:
						if not l.params.has(axis):
							(c as Dictionary).erase(axis)
			"hide":
				_remove_char(state["chars"], l.args[0] if l.args.size() > 0 else "")
			"move":
				# 与运行时 `Stage.move_char` 对齐 —— 三处细节，缺一处预览就与游戏不一致：
				#   1. 槽位**两种写法都认**。编辑器「移到」下拉写出来的是 `at=right`，
				#      以前只认位置参数（`l.args[1]`）→ **编辑器里改完位置，预览纹丝不动**
				#      （用户报的「预览窗没有正确显示移动后的立绘」）。
				#   2. 给了槽位就把 `x` 交还槽位（`y` 保留）—— 槽位表里只有横向比率，
				#      不清 `x` 则 show 设的坐标盖过槽位、立绘停在原地。
				#   3. **不凭空把角色加到台上** —— `move` 只移动已经在台上的立绘
				#      （`Stage.move_char` 开头 `if not _chars.has(id): return`）。
				#      加进来的话，预览会显示一个游戏里根本不存在的立绘。
				var cid2 := l.args[0] if l.args.size() > 0 else ""
				var at2 := String(l.params.get("at", ""))
				if at2.is_empty() and l.args.size() > 1:
					at2 = String(l.args[1])
				for c in state["chars"]:
					if String((c as Dictionary).get("id", "")) != cid2:
						continue
					var e: Dictionary = c
					if not at2.is_empty():
						e["at"] = at2
						if not l.params.has("x"):
							e.erase("x")
					for axis in ["x", "y", "scale"]:
						if l.params.has(axis):
							e[axis] = float(l.params[axis])
			"expr":
				var cid3 := l.args[0] if l.args.size() > 0 else ""
				for c in state["chars"]:
					if String((c as Dictionary).get("id", "")) == cid3:
						(c as Dictionary)["expr"] = l.args[1] if l.args.size() > 1 else "normal"
			"clear":
				state["chars"] = []
	return state


static func _upsert_char(arr: Array, entry: Dictionary) -> void:
	var cid := String(entry.get("id", ""))
	for c in arr:
		if String((c as Dictionary).get("id", "")) == cid:
			for k in entry.keys():
				(c as Dictionary)[k] = entry[k]
			return
	arr.append(entry)


static func _remove_char(arr: Array, cid: String) -> void:
	for i in range(arr.size() - 1, -1, -1):
		if String((arr[i] as Dictionary).get("id", "")) == cid:
			arr.remove_at(i)
