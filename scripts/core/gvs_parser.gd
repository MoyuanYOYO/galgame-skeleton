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
##     bgm / se / wait / wait_click / set / add
##     jump / call / return / branch_false / choice / minigame / ending

## 解析结果字典的键
const KEY_OK := "ok"
const KEY_COMMANDS := "commands"
const KEY_LABELS := "labels"
const KEY_ERRORS := "errors"

## 保留关键字。出现在行首即按指令解析，否则按对白/旁白解析。
const KEYWORDS: PackedStringArray = [
	"label", "jump", "goto", "call", "return", "jump_file",
	"bg", "show", "hide", "move", "expr", "clear",
	"hop", "zoom", "shake", "screen_shake", "screen_flash",
	"bg_motion", "weather",
	"cg", "hide_cg", "unlock",
	"bgm", "se", "voice",
	"wait", "wait_click", "pause",
	"set", "add", "sub", "flag", "affection",
	"if", "elif", "else", "end",
	"choice",
	"minigame",
	"ending",
	"chapter",
	"narr", "narration",
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

	func error(msg: String) -> void:
		errors.append("%s:%d: %s" % [source, line_no, msg])

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

		match head:
			"label": _do_label(tokens)
			"jump", "goto": _do_jump(tokens, "jump")
			"call": _do_jump(tokens, "call")
			"jump_file": _do_jump_file(tokens)
			"return": commands.append({"op": "return"})
			"bg": _do_bg(tokens)
			"show": _do_show(tokens)
			"hide": _do_hide(tokens)
			"move": _do_move(tokens)
			"hop": _do_hop(tokens)
			"zoom": _do_zoom(tokens)
			"shake": _do_shake(tokens)
			"screen_shake": _do_screen_shake(tokens)
			"screen_flash": _do_screen_flash(tokens)
			"bg_motion": _do_bg_motion(tokens)
			"weather": _do_weather(tokens)
			"expr": _do_expr(tokens)
			"clear": commands.append({"op": "clear"})
			"cg": _do_cg(tokens)
			"hide_cg": _do_hide_cg(tokens)
			"unlock": _do_unlock(tokens)
			"bgm": _do_bgm(tokens)
			"se": _do_se(tokens)
			"voice": _do_voice(tokens)
			"wait": _do_wait(tokens)
			"wait_click", "pause": commands.append({"op": "wait_click"})
			"set": _do_set(tokens)
			"add": _do_add(tokens, 1.0)
			"sub": _do_add(tokens, -1.0)
			"flag": _do_flag(tokens)
			"affection": _do_affection(tokens)
			"if": _do_if(tokens)
			"elif": _do_elif(tokens)
			"else": _do_else()
			"end": _do_end()
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
		commands.append({"op": "label", "name": label_name})

	func _do_jump(tokens: PackedStringArray, op: String) -> void:
		if tokens.size() < 2:
			error("%s 缺少目标标签" % op)
			return
		var idx := commands.size()
		# 除了解析后的 target 下标，也把标签名留着 ——
		# 静态校验（未使用标签 / 悬空跳转）要靠它，运行时用不到
		commands.append({"op": op, "target": -1, "label": tokens[1]})
		pending.append({"cmd": idx, "label": tokens[1]})

	func _do_jump_file(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("jump_file 需要 <剧本路径> [标签]")
			return
		commands.append({
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
		commands.append({"op": "flag", "name": tokens[1], "value": value})

	func _do_affection(tokens: PackedStringArray) -> void:
		if tokens.size() < 3:
			error("affection 需要 <角色> <增减值>")
			return
		commands.append({
			"op": "affection",
			"char": tokens[1],
			"amount": float(tokens[2].to_float()),
		})

	func _do_bg(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("bg 缺少背景 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		commands.append({
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
		commands.append({
			"op": "show",
			"char": tokens[1],
			"expr": String(kv.get("expr", "normal")),
			"at": String(kv.get("at", "center")),
			"transition": String(kv.get("type", "fade")),
			"duration": float(kv.get("fade", 0.3)),
		})

	func _do_hide(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("hide 缺少角色 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		commands.append({
			"op": "hide",
			"char": tokens[1],
			"transition": String(kv.get("type", "fade")),
			"duration": float(kv.get("fade", 0.3)),
		})

	func _do_move(tokens: PackedStringArray) -> void:
		if tokens.size() < 3:
			error("move 需要 <角色> <位置>")
			return
		var kv := GvsParser.parse_kv(tokens, 3)
		commands.append({
			"op": "move",
			"char": tokens[1],
			"at": tokens[2],
			"duration": float(kv.get("fade", 0.35)),
			"ease": String(kv.get("ease", "out_cubic")),
		})

	func _do_expr(tokens: PackedStringArray) -> void:
		if tokens.size() < 3:
			error("expr 需要 <角色> <表情>")
			return
		var kv := GvsParser.parse_kv(tokens, 3)
		commands.append({
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
		commands.append({
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
		commands.append({
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
		commands.append({
			"op": "shake",
			"char": tokens[1],
			"strength": float(kv.get("strength", 28.0)),
			"times": int(kv.get("times", 5)),
			"duration": float(kv.get("duration", 0.45)),
		})

	## 全屏震动 —— 背景 / 立绘 / CG / UI 一起动
	func _do_screen_shake(tokens: PackedStringArray) -> void:
		var kv := GvsParser.parse_kv(tokens, 1)
		commands.append({
			"op": "screen_shake",
			"strength": float(kv.get("strength", 36.0)),
			"times": int(kv.get("times", 5)),
			"duration": float(kv.get("duration", 0.45)),
		})

	## 全屏闪光
	func _do_screen_flash(tokens: PackedStringArray) -> void:
		var kv := GvsParser.parse_kv(tokens, 1)
		commands.append({
			"op": "screen_flash",
			"color": String(kv.get("color", "#ffffff")),
			"duration": float(kv.get("duration", 0.25)),
		})

	## 背景运镜（Ken Burns）：缓慢缩放 / 平移，让静止的背景「活」起来
	func _do_bg_motion(tokens: PackedStringArray) -> void:
		var kv := GvsParser.parse_kv(tokens, 1)
		commands.append({
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
		commands.append({
			"op": "weather",
			"kind": tokens[1],
			"intensity": float(kv.get("intensity", 1.0)),
		})

	## 展示一张全屏 CG，同时把它计入收藏
	func _do_cg(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("cg 缺少 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		commands.append({
			"op": "cg",
			"id": tokens[1],
			"fade": float(kv.get("fade", 0.5)),
			"transition": String(kv.get("type", "fade")),
		})

	## 收掉全屏 CG。支持 type= 指定退场转场（遮罩会反向走一遍）
	func _do_hide_cg(tokens: PackedStringArray) -> void:
		var kv := GvsParser.parse_kv(tokens, 1)
		commands.append({
			"op": "hide_cg",
			"fade": float(kv.get("fade", 0.4)),
			"transition": String(kv.get("type", "fade")),
		})

	## 只解锁收藏，不改变画面（用于隐藏要素 / 演出之外的解锁）
	func _do_unlock(tokens: PackedStringArray) -> void:
		if tokens.size() < 3:
			error("unlock 需要 <类型> <id>，例如 unlock music theme")
			return
		commands.append({
			"op": "unlock",
			"type": tokens[1],
			"id": tokens[2],
		})

	func _do_bgm(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("bgm 缺少音频 id")
			return
		var kv := GvsParser.parse_kv(tokens, 2)
		commands.append({
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
		commands.append({
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
		commands.append({
			"op": "voice",
			"id": tokens[1],
			"volume": float(kv.get("volume", 1.0)),
		})

	func _do_wait(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("wait 缺少秒数")
			return
		commands.append({"op": "wait", "duration": maxf(0.0, float(tokens[1].to_float()))})

	## 同时接受 `set <变量> <值>` 和 `set var <变量> <值>` 两种写法
	func _do_set(tokens: PackedStringArray) -> void:
		var start := _value_start(tokens)
		if tokens.size() < start + 2:
			error("set 需要 <变量> <值>")
			return
		commands.append({
			"op": "set",
			"name": tokens[start],
			"value": GvsParser.literal(" ".join(tokens.slice(start + 1))),
		})

	func _do_add(tokens: PackedStringArray, sign: float) -> void:
		var start := _value_start(tokens)
		if tokens.size() < start + 2:
			error("add/sub 需要 <变量> <数值>")
			return
		commands.append({
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
		commands.append({
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
		commands.append({"op": "jump", "target": -1})
		top["ends"].append(jump_idx)
		commands[top["branch"]]["target"] = commands.size()
		var idx := commands.size()
		commands.append({
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
		commands.append({"op": "jump", "target": -1})
		top["ends"].append(jump_idx)
		commands[top["branch"]]["target"] = commands.size()
		top["branch"] = -1

	func _do_end() -> void:
		if blocks.is_empty():
			error("多余的 end")
			return
		var top: Dictionary = blocks.pop_back()
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
		commands.append({"op": "choice", "options": [], "fallthrough": -1})
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
		opts.append({"text": opt_text, "label": label_part, "target": -1})

	func _do_minigame(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("minigame 缺少 id")
			return
		commands.append({
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
		commands.append({"op": "ending", "id": tokens[1], "title": title})

	## 设置当前章节名，会显示在存档槽摘要上
	func _do_chapter(tokens: PackedStringArray) -> void:
		if tokens.size() < 2:
			error("chapter 缺少标题")
			return
		commands.append({
			"op": "chapter",
			"title": GvsParser.unquote(" ".join(tokens.slice(1))),
		})

	func _do_narration(line: String) -> void:
		var body := line.substr(line.find(" ") + 1).strip_edges() if line.contains(" ") else ""
		commands.append({"op": "say", "speaker": "", "text": GvsParser.unquote(body), "expr": ""})

	## 对白行：`角色: 文本`、`角色@表情: 文本`、`"旁白"`
	func _do_dialogue(line: String) -> void:
		if line.begins_with("\"") or line.begins_with("'"):
			commands.append({
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
				commands.append({
					"op": "say", "speaker": speaker, "text": body, "expr": expr,
				})
				return

		commands.append({"op": "say", "speaker": "", "text": line, "expr": ""})
