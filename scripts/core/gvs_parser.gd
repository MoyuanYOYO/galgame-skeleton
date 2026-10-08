class_name GvsParser
extends RefCounted

## GVS (Galgame Visual Script) 剧本解析器
##
## 把行式剧本编译成「扁平指令数组 + 标签索引表」。
## 条件块 (if / elif / else / end) 和选项块 (choice / end) 会被编译成
## 条件跳转指令 (branch_false / jump)，因此运行期只需要一个整数指令指针
## (ip) 就能表达全部控制流 —— 这也是存档能只存一个整数就恢复进度的原因。
##
## 用法：
##     var result := GvsParser.parse(text, "prologue.gvs")
##     if not result["ok"]:
##         for e in result["errors"]:
##             push_error(e)
##
## 指令字典的 op 取值：
##     label / say / bg / show / hide / move / expr / clear
##     bgm / se / wait / wait_click / set / add / carry
##     jump / call / return / branch_false / choice / minigame / ending
##
## 每条指令都带一个 `line` 键（1 基源码行号），**只有编辑器在用** ——
## 它靠这个把「第 N 行」映射成指令下标（`ScriptRunner.start_at_line`），
## 从而实现「从光标那一行精确开始预览」。

## 解析结果字典的键
const KEY_OK := "ok"
const KEY_COMMANDS := "commands"
const KEY_LABELS := "labels"
const KEY_ERRORS := "errors"

## 保留关键字。出现在行首即按指令解析，否则按对白/旁白解析。
const KEYWORDS: PackedStringArray = [
	"label", "jump", "goto", "call", "return", "jump_file",
	"bg", "show", "hide", "move", "expr", "clear",
	"hop", "zoom", "shake", "screen_shake", "screen_flash", "screen_fx",
	"bg_motion", "weather",
	"anim",
	"video", "hide_video",
	"cg", "hide_cg", "unlock",
	"bgm", "se", "voice", "audio_fx",
	"wait", "wait_click", "pause",
	"set", "add", "sub", "flag", "affection",
	"carry",
	"if", "elif", "else", "end",
	"together",
	"choice",
	"minigame",
	"ending",
	"chapter",
	"narr", "narration",
]

## `together` 块里**只允许**这些指令。
##
## 用**允许表**而不是禁止表：以后新增指令时，默认是「不能在 together 里用」——
## 这个方向安全（顶多提示作者去改，不会静默产生错误语义）。
##
## 被排除的是三类：结构 / 流程（`label` `jump` `if` `choice` `ending`…）、
## 阻塞型（`say` `wait` `wait_click` `minigame` `video wait=true`）、
## 以及「本来就是异步且不需要等」的 `clear` 之外的杂项。
const TOGETHER_ALLOWED: PackedStringArray = [
	"bg", "cg", "hide_cg", "show", "hide", "move", "expr",
	"hop", "zoom", "shake", "screen_shake", "screen_flash", "screen_fx",
	"bg_motion", "weather", "anim", "video", "hide_video",
	"bgm", "se", "voice", "audio_fx",
	"set", "add", "sub", "flag", "affection", "carry", "unlock",
]


# ---------------------------------------------------------------------------
# 对外入口
# ---------------------------------------------------------------------------

static func parse(text: String, source_name: String = "<inline>") -> Dictionary:
	var builder := Builder.new()
	builder.source = source_name
	builder.run(text)

	for blk in builder.blocks:
		builder.errors.append("%s:%d: 未闭合的 %s 块" % [
			source_name, int(blk.get("line", 0)), String(blk.get("kind", "?"))])

	builder.resolve_labels()

	return {
		KEY_OK: builder.errors.is_empty(),
		KEY_COMMANDS: builder.commands,
		KEY_LABELS: builder.labels,
		KEY_ERRORS: builder.errors,
	}


static func is_keyword(token: String) -> bool:
	return KEYWORDS.has(token)


# ---------------------------------------------------------------------------
# 词法工具
# ---------------------------------------------------------------------------

## 去掉注释。引号内的 # 会被保留。
static func strip_comment(line: String) -> String:
	var in_quote := false
	var quote_char := ""
	var i := 0
	while i < line.length():
		var c := line[i]
		if in_quote:
			if c == quote_char:
				in_quote = false
		elif c == "\"" or c == "'":
			in_quote = true
			quote_char = c
		elif c == "#":
			# 只有行首、或前面是空白时才算注释开始。
			# 否则 screen_flash color=#ff0000 这种十六进制颜色会被从 # 处截断。
			if i == 0 or line[i - 1] == " " or line[i - 1] == "\t":
				return line.substr(0, i)
		i += 1
	return line


static func unquote(raw: String) -> String:
	var v := raw.strip_edges()
	if v.length() >= 2:
		var first := v[0]
		var last := v[v.length() - 1]
		if (first == "\"" and last == "\"") or (first == "'" and last == "'"):
			return v.substr(1, v.length() - 2)
	return v


## 把字面量文本转成合适的 Variant：bool / int / float / null / String
static func literal(raw: String) -> Variant:
	var v := raw.strip_edges()
	if v.length() >= 2:
		var first := v[0]
		var last := v[v.length() - 1]
		if (first == "\"" and last == "\"") or (first == "'" and last == "'"):
			return v.substr(1, v.length() - 2)
	if v == "true":
		return true
	if v == "false":
		return false
	if v == "null" or v == "nil":
		return null
	if v.is_valid_int():
		return v.to_int()
	if v.is_valid_float():
		return v.to_float()
	return v


## 把 `key=value key2=value2` 形式的词元解析成字典
static func parse_kv(tokens: PackedStringArray, start: int) -> Dictionary:
	var out: Dictionary = {}
	var i := start
	while i < tokens.size():
		var t := tokens[i]
		var eq := t.find("=")
		if eq > 0:
			out[t.substr(0, eq)] = literal(t.substr(eq + 1))
		i += 1
	return out


## 解析条件表达式。
##     flag <name>
##     not flag <name>
##     affection <char> <cmp> <value>
##     var <name> <cmp> <value>
##     cycle <cmp> <n>            当前周目数（多周目）
##     cleared <结局id>           这个结局通关过没有（多周目）
##     <name>                      (裸标识符等价于 flag <name>)
static func parse_condition(tokens: PackedStringArray, start: int) -> Dictionary:
	var cond := {"negate": false, "kind": "flag", "name": "", "cmp": "==", "value": null}
	var i := start
	if i < tokens.size() and tokens[i] == "not":
		cond["negate"] = true
		i += 1
	if i >= tokens.size():
		return cond

	var head := tokens[i]
	match head:
		"flag":
			cond["kind"] = "flag"
			if i + 1 < tokens.size():
				cond["name"] = tokens[i + 1]
		"affection", "var":
			cond["kind"] = head
			if i + 1 < tokens.size():
				cond["name"] = tokens[i + 1]
			if i + 2 < tokens.size():
				cond["cmp"] = tokens[i + 2]
			if i + 3 < tokens.size():
				cond["value"] = literal(" ".join(tokens.slice(i + 3)))
		"cycle":
			# 周目数没有「名字」，只有比较式：if cycle >= 2
			cond["kind"] = "cycle"
			cond["name"] = ""
			if i + 1 < tokens.size():
				cond["cmp"] = tokens[i + 1]
			if i + 2 < tokens.size():
				cond["value"] = literal(tokens[i + 2])
		"cleared", "clear":
			# 结局 id 放 name 字段，和 flag 一样；negate 由上面的 not 统一处理
			cond["kind"] = "cleared"
			if i + 1 < tokens.size():
				cond["name"] = tokens[i + 1]
		_:
			cond["kind"] = "flag"
			cond["name"] = head
	return cond


# ---------------------------------------------------------------------------
# 构建器（内部状态机）
# ---------------------------------------------------------------------------

class Builder extends RefCounted:
	var commands: Array = []
	var labels: Dictionary = {}
	var errors: Array = []
	var blocks: Array = []
	var pending: Array = []
	var source: String = "<inline>"
	var line_no: int = 0
	var _line: String = ""
	## `together` 块栈。元素 `{cmd: 顶层指令下标, body: 块内指令数组}`
	## —— 块内的指令**不进顶层** `commands`，而是塞进 body，
	## 由 `together` 那一条指令带着一起执行。
	var _together: Array = []

	func error(msg: String) -> void:
		errors.append("%s:%d: %s" % [source, line_no, msg])

	## 追加一条指令，并盖上**源码行号**。
	##
	## 行号是给编辑器用的：编译结果里唯一的定位点是标签，所以「从第 N 行开始预览」
	## 原本只能退化成「从最近的标签开始」。有了这个键，`ScriptRunner.start_at_line()`
	## 才能精确落到那一行。**游戏本身不读它**（全部消费方都是 `cmd.get("op")`）。
	##
	## ⚠️ 在 `together` 块里时指令进的是块内 body，不是顶层 —— 否则块内那些
	## 「同时启动」的指令会被顶层顺序执行一遍。
	func _push(cmd: Dictionary) -> void:
		cmd["line"] = line_no
		if not _together.is_empty():
			((_together.back() as Dictionary)["body"] as Array).append(cmd)
			return
		commands.append(cmd)

	func run(text: String) -> void:
		var raw_lines := text.split("\n")
		var n := 1
		for raw in raw_lines:
			var line := GvsParser.strip_comment(raw).replace("\t", " ").strip_edges()
			if not line.is_empty():
				feed(line, n)
			n += 1

	## 把待解析的标签引用回填成指令索引
	func resolve_labels() -> void:
		for p in pending:
			var target_name: String = p["label"]
			if not labels.has(target_name):
				errors.append("%s: 未定义的标签 '%s'" % [source, target_name])
				continue
			var target_index: int = labels[target_name]
			var cmd: Dictionary = commands[p["cmd"]]
			if p.has("opt"):
				var opts: Array = cmd["options"]
				opts[int(p["opt"])]["target"] = target_index
			else:
				cmd["target"] = target_index

	# ------------------------------------------------------------------
	# 单行分发
	# ------------------------------------------------------------------

	func feed(line: String, lineno: int) -> void:
		line_no = lineno
		_line = line
		var tokens := line.split(" ", false)
		var head := tokens[0] if tokens.size() > 0 else ""

		# 选项块内部的裸行按「选项」处理
		if not blocks.is_empty() and String(blocks.back()["kind"]) == "choice" and head != "end":
			_add_option(line)
			return

		# `together` 块只收「非阻塞的演出 / 音频指令」。这里直接报错而不是静默忽略 ——
		# 写进去的指令没生效却什么都不说，正是本项目最想避免的那类 bug。
		if not _together.is_empty() and head != "end" and not TOGETHER_ALLOWED.has(head):
			error("together 块里不能写 %s（只允许：%s）"
				% [head, ", ".join(TOGETHER_ALLOWED)])
			return

		match head:
			"label": _do_label(tokens)
			"jump", "goto": _do_jump(tokens, "jump")
			"call": _do_call(tokens)
			"jump_file": _do_jump_file(tokens)
			"return": _push({"op": "return"})
			"bg": _do_bg(tokens)
			"show": _do_show(tokens)
			"hide": _do_hide(tokens)
			"move": _do_move(tokens)
			"hop": _do_hop(tokens)
			"zoom": _do_zoom(tokens)
			"shake": _do_shake(tokens)
			"screen_shake": _do_screen_shake(tokens)
			"screen_flash": _do_screen_flash(tokens)
			"screen_fx": _do_screen_fx(tokens)
			"bg_motion": _do_bg_motion(tokens)
			"weather": _do_weather(tokens)
			"anim": _do_anim(tokens)
			"video": _do_video(tokens)
			"hide_video": _do_hide_video(tokens)
			"expr": _do_expr(tokens)
			"clear": _push({"op": "clear"})
			"cg": _do_cg(tokens)
			"hide_cg": _do_hide_cg(tokens)
			"unlock": _do_unlock(tokens)
			"bgm": _do_bgm(tokens)
			"se": _do_se(tokens)
			"voice": _do_voice(tokens)
			"audio_fx": _do_audio_fx(tokens)
			"wait": _do_wait(tokens)
			"wait_click", "pause": _push({"op": "wait_click"})
			"set": _do_set(tokens)
			"add": _do_add(tokens, 1.0)
			"sub": _do_add(tokens, -1.0)
			"flag": _do_flag(tokens)
			"affection": _do_affection(tokens)
			"carry": _do_carry(tokens)
			"if": _do_if(tokens)
			"elif": _do_elif(tokens)
			"else": _do_else()
			"end": _do_end()
			"together": _do_together(tokens)
			"choice": _do_choice()
			"minigame": _do_minigame(tokens)
			"ending": _do_ending(tokens)
			"chapter": _do_chapter(tokens)
			"narr", "narration": _do_narration(line)
			_: _do_dialogue(line)

	# ------------------------------------------------------------------
	# 指令实现
	# ------------------------------------------------------------------

	func _do_label(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("label 缺少名称")
			return
		var label_name := tokens[1]
		if labels.has(label_name):
			error("标签重复定义: %s" % label_name)
		labels[label_name] = commands.size()
		_push({"op": "label", "name": label_name})

	func _do_jump(tokens: PackedStringArray, op: String) -> void:
		if tokens.size() < 2:
			error("%s 缺少目标标签" % op)
			return
		var idx := commands.size()
		# 除了解析后的 target 下标，也把标签名留着 ——
		# 静态校验（未使用标签 / 悬空跳转）要靠它，运行时用不到
		_push({"op": op, "target": -1, "label": tokens[1]})
		pending.append({"cmd": idx, "label": tokens[1]})

	## 调用子过程，可带参数。
	##
	##   call 打招呼
	##   call 打招呼 who=alice count=2        具名参数 → 子过程里写 {$who} / {$count}
	##   call 打招呼 alice 2                  位置参数 → 子过程里写 {$1} / {$2}
	##
	## 参数在子过程里**作用域是局部的**（进调用栈，`return` 时一并弹掉），
	## 所以同名参数在嵌套调用里不会互相串味；查找是「内层优先」。
	##
	## 具名与位置两种写法可以混用（`call f who=alice 2`），插值时先查具名再查位置。
	func _do_call(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("call 缺少目标标签")
			return
		var args: Array = []
		for i in range(2, tokens.size()):
			if not tokens[i].contains("="):
				args.append(GvsParser.literal(tokens[i]))
		var idx := commands.size()
		_push({
			"op": "call",
			"target": -1,
			"label": tokens[1],
			"params": GvsParser.parse_kv(tokens, 2),
			"args": args,
		})
		pending.append({"cmd": idx, "label": tokens[1]})

	## 演出并行组：块内指令**同时启动**，块结束等最长的那条跑完。
	##
	##   together
	##       bg rooftop type=dissolve fade=1.2
	##       show alice transition=slide_left fade=1.0
	##       bgm sunset fade=1.5
	##   end
	##
	## 为什么需要它：GVS 的演出指令本来就是「启动即返回」（Tween 在后台跑），
	## 所以「同时发生」不用特别支持；真正缺的是**「等这一组都跑完再继续」** ——
	## 以前只能手写一个 `wait`，而那个数字要跟着每个 duration 一起改，非常脆。
	##
	## 可选的 `duration=` 覆盖「等多久」。**不写是 -1，写 0 是「只启动、不等」** ——
	## 用 -1 当哨兵是为了区分「没写」与「显式写了 0」，两者语义完全不同。
	func _do_together(tokens: PackedStringArray) -> void:
		if not _together.is_empty():
			error("together 不能嵌套")
			return
		var kv := GvsParser.parse_kv(tokens, 1)
		var body: Array = []
		var cmd := {
			"op": "together",
			"body": body,
			"duration": float(kv.get("duration", -1.0)),
		}
		_push(cmd)          # 此时栈还是空的 → 进顶层
		_together.append({"body": body})
		blocks.append({"kind": "together", "line": line_no,
			"branch": commands.size() - 1})

	func _do_jump_file(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("jump_file 需要 <剧本路径> [标签]")
			return
		_push({
			"op": "jump_file",
			"file": tokens[1],
			"label": tokens[2] if tokens.size() > 2 else "",
		})

	func _do_flag(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("flag 缺少名称")
			return
		var value := true
		if tokens.size() > 2:
			value = bool(GvsParser.literal(tokens[2]))
		_push({"op": "flag", "name": tokens[1], "value": value})

	func _do_affection(tokens: PackedStringArray) -> void:
		if tokens.size() < 3:
			error("affection 需要 <角色> <增减值>")
			return
		_push({
			"op": "affection",
			"char": tokens[1],
			"amount": float(tokens[2].to_float()),
		})

	## 标记一个「跨周目继承」的状态。
	##
	##   carry flag <旗标名>        下一周目保留这个旗标
	##   carry var <变量名>         下一周目保留这个变量
	##   carry affection <角色 id>  下一周目保留这个角色的好感度
	##
	## 只是**打标记**，取值发生在抵达结局的那一刻（见 CycleManager.record_ending），
	## 所以作者把它写在剧本哪一行都不影响结果 —— 继承的永远是「这一周目结束时」的值。
	func _do_carry(tokens: PackedStringArray) -> void:
		if tokens.size() < 3:
			error("carry 需要 <类型> <名字>，例如 carry flag met_alice / carry var hp / carry affection alice")
			return
		var kind := String(tokens[1])
		if not CycleManager.CARRY_KINDS.has(kind):
			error("carry 未知类型 %s（可用：%s）"
				% [kind, ", ".join(CycleManager.CARRY_KINDS)])
			return
		_push({"op": "carry", "kind": kind, "name": tokens[2]})

	func _do_bg(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("bg 缺少背景 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		_push({
			"op": "bg",
			"id": tokens[1],
			"transition": String(kv.get("type", "fade")),
			"duration": float(kv.get("fade", 0.4)),
		})

	func _do_show(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("show 缺少角色 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		var cmd := {
			"op": "show",
			"char": tokens[1],
			"expr": String(kv.get("expr", "normal")),
			"at": String(kv.get("at", "center")),
			"transition": String(kv.get("type", "fade")),
			"duration": float(kv.get("fade", 0.3)),
		}
		# 绝对定位 / 基准缩放只在真的写了才带上。「没写」与「写了默认值」
		# 在下游必须是同一件事 —— 下游靠「键在不在」决定要不要覆盖。
		if kv.has("x"):
			cmd["x"] = float(kv["x"])
		if kv.has("y"):
			cmd["y"] = float(kv["y"])
		if kv.has("scale"):
			cmd["scale"] = float(kv["scale"])
		_push(cmd)

	func _do_hide(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("hide 缺少角色 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		_push({
			"op": "hide",
			"char": tokens[1],
			"transition": String(kv.get("type", "fade")),
			"duration": float(kv.get("fade", 0.3)),
		})

	func _do_move(tokens: PackedStringArray) -> void:
		if tokens.size() < 3:
			error("move 需要 <角色> <位置>（或用 x= / y= 指定坐标）")
			return
		# 第二个词若带 '='，那它就是参数（x= / y= / duration= …）而不是位置关键字。
		# 于是 `move alice center` 与 `move alice x=960 y=1100` 都能写，
		# 后者 at 留空 = 不动预设，只覆盖坐标。
		var kv_start := 2
		var at := ""
		if not tokens[2].contains("="):
			at = tokens[2]
			kv_start = 3
		var kv := GvsParser.parse_kv(tokens, kv_start)
		# ⚠️ `at=` 也要认。规范写法是位置参数（`move alice center`），但编辑器的
		# 「移到」下拉写出来的是 `at=center` —— 不认的话那条指令的 `at` 会是空串，
		# 表现是「在编辑器里改了位置，游戏里纹丝不动」，而且**一声不吭**。
		# `show` 一直是两种都认的，这里对齐。
		if at.is_empty() and kv.has("at"):
			at = String(kv["at"])
		var cmd := {
			"op": "move",
			"char": tokens[1],
			"at": at,
			"duration": float(kv.get("fade", 0.35)),
			"ease": String(kv.get("ease", "out_cubic")),
		}
		if kv.has("x"):
			cmd["x"] = float(kv["x"])
		if kv.has("y"):
			cmd["y"] = float(kv["y"])
		if kv.has("scale"):
			cmd["scale"] = float(kv["scale"])
		_push(cmd)

	func _do_expr(tokens: PackedStringArray) -> void:
		if tokens.size() < 3:
			error("expr 需要 <角色> <表情>")
			return
		var kv := GvsParser.parse_kv(tokens, 3)
		_push({
			"op": "expr",
			"char": tokens[1],
			"expr": tokens[2],
			"duration": float(kv.get("fade", 0.18)),
		})

	## 兴奋小跳（不是 jump —— 那个是标签跳转）
	func _do_hop(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("hop 缺少角色 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		_push({
			"op": "hop",
			"char": tokens[1],
			"height": float(kv.get("height", 40.0)),
			"times": int(kv.get("times", 2)),
			"duration": float(kv.get("duration", 0.7)),
		})

	## 靠近 / 远离（缩放）
	func _do_zoom(tokens: PackedStringArray) -> void:
		if tokens.size() < 3:
			error("zoom 需要 <角色> <倍数>")
			return
		var kv := GvsParser.parse_kv(tokens, 3)
		_push({
			"op": "zoom",
			"char": tokens[1],
			"scale": float(tokens[2].to_float()),
			"duration": float(kv.get("duration", 0.4)),
			"ease": String(kv.get("ease", "out_back")),
		})

	## 立绘抖动
	func _do_shake(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("shake 缺少角色 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		_push({
			"op": "shake",
			"char": tokens[1],
			"strength": float(kv.get("strength", 28.0)),
			"times": int(kv.get("times", 5)),
			"duration": float(kv.get("duration", 0.45)),
		})

	## 全屏震动 —— 背景 / 立绘 / CG / UI 一起动
	func _do_screen_shake(tokens: PackedStringArray) -> void:
		var kv := GvsParser.parse_kv(tokens, 1)
		_push({
			"op": "screen_shake",
			"strength": float(kv.get("strength", 36.0)),
			"times": int(kv.get("times", 5)),
			"duration": float(kv.get("duration", 0.45)),
		})

	## 全屏闪光
	func _do_screen_flash(tokens: PackedStringArray) -> void:
		var kv := GvsParser.parse_kv(tokens, 1)
		_push({
			"op": "screen_flash",
			"color": String(kv.get("color", "#ffffff")),
			"duration": float(kv.get("duration", 0.25)),
		})

	## 全屏后处理特效：glitch / wave / swirl / pixelate / chromatic / invert / blur
	##
	## 这里对未知种类**直接报错**，不像 weather 那样静默降级成 none。
	## 理由：种类是一个封闭的小集合，写错基本只有「拼错」一种可能，
	## 而静默降级的后果是「剧本写了、演出不出来」，正是本项目最想避免的那类
	## bug（tools/audit 会把这条错误变成 CI 的非零退出码）。
	##
	## duration <= 0 表示持续到显式关闭（`screen_fx none` 或下一条 screen_fx）。
	func _do_screen_fx(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("screen_fx 缺少类型（%s）" % ScreenFxSpec.list_text())
			return
		var kind := String(tokens[1])
		if not ScreenFxSpec.is_valid(kind):
			error("screen_fx 未知类型 %s（可用：%s）" % [kind, ScreenFxSpec.list_text()])
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		_push({
			"op": "screen_fx",
			"kind": kind,
			"strength": float(kv.get("strength", 1.0)),
			"duration": float(kv.get("duration", ScreenFxSpec.DEFAULT_DURATION)),
		})

	## 背景运镜（Ken Burns）：缓慢缩放 / 平移，让静止的背景「活」起来
	func _do_bg_motion(tokens: PackedStringArray) -> void:
		var kv := GvsParser.parse_kv(tokens, 1)
		_push({
			"op": "bg_motion",
			"scale": float(kv.get("scale", 1.0)),
			"x": float(kv.get("x", 0.0)),
			"y": float(kv.get("y", 0.0)),
			"duration": float(kv.get("duration", 6.0)),
			"ease": String(kv.get("ease", "in_out_cubic")),
		})

	## 天气：none / rain / snow / sakura
	func _do_weather(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("weather 缺少类型（none / rain / snow / sakura）")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		_push({
			"op": "weather",
			"kind": tokens[1],
			"intensity": float(kv.get("intensity", 1.0)),
		})

	## 控制某个立绘的帧序列动画（素材是「帧序列目录」时才有意义）
	##
	##   anim alice                    恢复常速循环播放
	##   anim alice speed=0.5          慢放
	##   anim alice pause=true         定格在当前帧
	##   anim alice once               只播一遍，停在最后一帧
	##   anim alice frame=3            跳到第 3 帧（0 基）
	func _do_anim(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("anim 缺少角色 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		_push({
			"op": "anim",
			"char": tokens[1],
			"speed": float(kv.get("speed", 1.0)),
			"pause": bool(kv.get("pause", false)),
			"once": bool(kv.get("once", false)),
			"frame": int(kv.get("frame", -1)),
		})

	## 播放一段视频（Godot 只认 Ogg Theora .ogv，素材放 assets/video/<id>.ogv）
	##
	##   video op                      全屏播放，不阻塞，播完自动收起
	##   video op wait=true            播完再继续剧情
	##   video op at=320,180 size=640,360
	##   video op layer=ui             压在 UI 之上（world / ui / top）
	##   video op loop=true volume=0.5 fade=0.4 speed=1.5
	func _do_video(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("video 缺少 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		var layer := String(kv.get("layer", "world")).strip_edges().to_lower()
		if not VideoScreen.LAYERS.has(layer):
			error("video 未知图层 %s（可用：%s）"
				% [layer, ", ".join(VideoScreen.LAYERS)])
			return
		# together 里不能用 wait=true：那个等待态会被块自己的等待覆盖掉，
		# 表现为「写了 wait 却没等」—— 静默失效，所以直接报错。
		if not _together.is_empty() and bool(kv.get("wait", false)):
			error("together 块里的 video 不能用 wait=true（块结束会等最长的那条）")
			return
		_push({
			"op": "video",
			"id": tokens[1],
			"at": String(kv.get("at", "full")),
			"size": String(kv.get("size", "")),
			"layer": layer,
			"fade": float(kv.get("fade", 0.0)),
			"volume": float(kv.get("volume", 1.0)),
			"speed": float(kv.get("speed", 1.0)),
			"buffer": int(kv.get("buffer", VideoScreen.DEFAULT_BUFFER_MS)),
			"loop": bool(kv.get("loop", false)),
			"wait": bool(kv.get("wait", false)),
			"hide": bool(kv.get("hide", true)),
		})

	## 收掉视频（淡出）
	func _do_hide_video(tokens: PackedStringArray) -> void:
		var kv := GvsParser.parse_kv(tokens, 1)
		_push({
			"op": "hide_video",
			"fade": float(kv.get("fade", 0.3)),
		})

	## 展示一张全屏 CG，同时把它计入收藏
	func _do_cg(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("cg 缺少 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		_push({
			"op": "cg",
			"id": tokens[1],
			"fade": float(kv.get("fade", 0.5)),
			"transition": String(kv.get("type", "fade")),
		})

	## 收掉全屏 CG。支持 type= 指定退场转场（遮罩会反向走一遍）
	func _do_hide_cg(tokens: PackedStringArray) -> void:
		var kv := GvsParser.parse_kv(tokens, 1)
		_push({
			"op": "hide_cg",
			"fade": float(kv.get("fade", 0.4)),
			"transition": String(kv.get("type", "fade")),
		})

	## 只解锁收藏，不改变画面（用于隐藏要素 / 演出之外的解锁）
	func _do_unlock(tokens: PackedStringArray) -> void:
		if tokens.size() < 3:
			error("unlock 需要 <类型> <id>，例如 unlock music theme")
			return
		_push({
			"op": "unlock",
			"type": tokens[1],
			"id": tokens[2],
		})

	func _do_bgm(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("bgm 缺少音频 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		_push({
			"op": "bgm",
			"id": tokens[1],
			"volume": float(kv.get("volume", 0.8)),
			"fade": float(kv.get("fade", 1.0)),
		})

	func _do_se(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("se 缺少音频 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		_push({
			"op": "se",
			"id": tokens[1],
			"volume": float(kv.get("volume", 1.0)),
		})

	## 语音。写在台词**前面** —— 播放的同时会被记下来，
	## 玩家点说话人名字牌可以重播这一句。
	func _do_voice(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("voice 缺少语音 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		_push({
			"op": "voice",
			"id": tokens[1],
			"volume": float(kv.get("volume", 1.0)),
		})

	## 给某条音轨挂 / 清音频效果器。
	##
	##   audio_fx bgm glitch                       默认 0.8 秒后自动清除
	##   audio_fx voice pitch pitch=1.6            移调（变尖 / 变沉）
	##   audio_fx bgm distortion duration=2 strength=1.5
	##   audio_fx all off                          清掉所有音轨上我们加的效果器
	##
	## 音轨与效果器的清单都在 `AudioFxSpec`（解析器 / 运行时 / 编辑器共用一份）。
	##
	## 未知音轨 / 未知效果器**直接报错**，不像 weather 那样静默降级成 none：
	## 两个都是封闭的小集合，写错基本只有「拼错」一种可能，而静默降级的后果是
	## 「剧本写了、演出不出来」—— 正是本项目最想避免的那类 bug
	## （tools/audit 会把这条错误变成 CI 的非零退出码）。
	##
	## 想在**文字显示的中间**触发，用台词里的内联标签 `[fx=glitch bus=bgm]`，
	## 不走这条指令。
	func _do_audio_fx(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("audio_fx 需要 <音轨> [效果]，音轨：%s" % AudioFxSpec.tracks_text())
			return
		var track := String(tokens[1]).strip_edges().to_lower()
		if not AudioFxSpec.is_valid_track(track):
			error("audio_fx 未知音轨 %s（可用：%s）" % [track, AudioFxSpec.tracks_text()])
			return
		var kind := "glitch"
		if tokens.size() > 2:
			kind = String(tokens[2]).strip_edges().to_lower()
		if not AudioFxSpec.is_valid_kind(kind):
			error("audio_fx 未知效果器 %s（可用：%s）" % [kind, AudioFxSpec.list_text()])
			return
		var kv := GvsParser.parse_kv(tokens, 3)
		_push({
			"op": "audio_fx",
			"track": track,
			"kind": kind,
			"duration": float(kv.get("duration", AudioFxSpec.DEFAULT_DURATION)),
			"strength": float(kv.get("strength", 1.0)),
			"pitch": float(kv.get("pitch", 1.0)),
		})

	func _do_wait(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("wait 缺少秒数")
			return
		_push({"op": "wait", "duration": maxf(0.0, float(tokens[1].to_float()))})

	## 同时接受 `set <变量> <值>` 和 `set var <变量> <值>` 两种写法
	func _do_set(tokens: PackedStringArray) -> void:
		var start := _value_start(tokens)
		if tokens.size() < start + 2:
			error("set 需要 <变量> <值>")
			return
		_push({
			"op": "set",
			"name": tokens[start],
			"value": GvsParser.literal(" ".join(tokens.slice(start + 1))),
		})

	func _do_add(tokens: PackedStringArray, sign: float) -> void:
		var start := _value_start(tokens)
		if tokens.size() < start + 2:
			error("add/sub 需要 <变量> <数值>")
			return
		_push({
			"op": "add",
			"name": tokens[start],
			"amount": sign * float(tokens[start + 1].to_float()),
		})

	## 跳过可选的 `var` 前缀词
	static func _value_start(tokens: PackedStringArray) -> int:
		if tokens.size() > 1 and tokens[1] == "var":
			return 2
		return 1

	func _do_if(tokens: PackedStringArray) -> void:
		var idx := commands.size()
		_push({
			"op": "branch_false",
			"cond": GvsParser.parse_condition(tokens, 1),
			"target": -1,
		})
		blocks.append({"kind": "if", "line": line_no, "branch": idx, "ends": []})

	func _do_elif(tokens: PackedStringArray) -> void:
		if blocks.is_empty() or String(blocks.back()["kind"]) != "if":
			error("elif 没有对应的 if")
			return
		var top: Dictionary = blocks.back()
		var jump_idx := commands.size()
		_push({"op": "jump", "target": -1})
		top["ends"].append(jump_idx)
		commands[top["branch"]]["target"] = commands.size()
		var idx := commands.size()
		_push({
			"op": "branch_false",
			"cond": GvsParser.parse_condition(tokens, 1),
			"target": -1,
		})
		top["branch"] = idx

	func _do_else() -> void:
		if blocks.is_empty() or String(blocks.back()["kind"]) != "if":
			error("else 没有对应的 if")
			return
		var top: Dictionary = blocks.back()
		var jump_idx := commands.size()
		_push({"op": "jump", "target": -1})
		top["ends"].append(jump_idx)
		commands[top["branch"]]["target"] = commands.size()
		top["branch"] = -1

	func _do_end() -> void:
		if blocks.is_empty():
			error("多余的 end")
			return
		var top: Dictionary = blocks.pop_back()
		# `together` 块没有跳转要回填，只需要把它自己的 body 收尾
		if String(top["kind"]) == "together":
			if not _together.is_empty():
				_together.pop_back()
			return
		var here := commands.size()
		if String(top["kind"]) == "if":
			if int(top["branch"]) >= 0:
				commands[top["branch"]]["target"] = here
			for j in top["ends"]:
				commands[int(j)]["target"] = here
		else:
			var cmd: Dictionary = commands[top["branch"]]
			cmd["fallthrough"] = here
			var opts: Array = cmd["options"]
			for i in opts.size():
				var opt: Dictionary = opts[i]
				if int(opt["target"]) < 0:
					pending.append({"cmd": top["branch"], "opt": i, "label": String(opt["label"])})

	func _do_choice() -> void:
		var idx := commands.size()
		_push({"op": "choice", "options": [], "fallthrough": -1})
		blocks.append({"kind": "choice", "line": line_no, "branch": idx})

	func _add_option(line: String) -> void:
		var top: Dictionary = blocks.back()
		var cmd: Dictionary = commands[top["branch"]]
		var arrow := line.find("->")
		if arrow == -1:
			error("选项缺少 '-> 标签': %s" % line)
			return
		var opt_text := GvsParser.unquote(line.substr(0, arrow).strip_edges())
		var label_part := line.substr(arrow + 2).strip_edges()
		var opts: Array = cmd["options"]
		opts.append({"text": opt_text, "label": label_part, "target": -1, "line": line_no})

	func _do_minigame(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("minigame 缺少 id")
			return
		_push({
			"op": "minigame",
			"id": tokens[1],
			"params": GvsParser.parse_kv(tokens, 2),
		})

	func _do_ending(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("ending 缺少 id")
			return
		var title := ""
		if tokens.size() > 2:
			title = GvsParser.unquote(" ".join(tokens.slice(2)))
		_push({"op": "ending", "id": tokens[1], "title": title})

	## 设置当前章节名，会显示在存档槽摘要上
	func _do_chapter(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("chapter 缺少标题")
			return
		_push({
			"op": "chapter",
			"title": GvsParser.unquote(" ".join(tokens.slice(1))),
		})

	func _do_narration(line: String) -> void:
		var body := line.substr(line.find(" ") + 1).strip_edges() if line.contains(" ") else ""
		_push({"op": "say", "speaker": "", "text": GvsParser.unquote(body), "expr": ""})

	## 对白行：`角色: 文本`、`角色@表情: 文本`、`"旁白"`
	func _do_dialogue(line: String) -> void:
		if line.begins_with("\"") or line.begins_with("'"):
			_push({
				"op": "say", "speaker": "", "text": GvsParser.unquote(line), "expr": "",
			})
			return

		var colon := line.find(":")
		if colon > 0:
			var prefix := line.substr(0, colon).strip_edges()
			if not prefix.is_empty() and not prefix.contains(" ") and prefix.length() <= 24:
				var body := line.substr(colon + 1).strip_edges()
				var speaker := prefix
				var expr := ""
				var at := prefix.find("@")
				if at > 0:
					speaker = prefix.substr(0, at)
					expr = prefix.substr(at + 1)
				_push({
					"op": "say", "speaker": speaker, "text": body, "expr": expr,
				})
				return

		_push({"op": "say", "speaker": "", "text": line, "expr": ""})
