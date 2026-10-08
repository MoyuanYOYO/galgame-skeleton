extends Node

## OpSpec ↔ GvsParser 一致性守卫
##
## 守的是**「编辑器能写、解析器不读」**这一类静默失效：界面上能选、能填，
## 写进剧本却没人理 —— 不报错、只是没效果。已经踩过两次：
##
##   · `audio_fx` 的三个参数全摆出来，而 `pitch=` 挂在 `muffle` 上运行时压根不读
##   · `move alice at=center` —— 解析器只认位置参数，`at=` 被**静默丢掉**，
##     表现是「在编辑器里改了位置，游戏里纹丝不动」
##
## 做法：拿每条指令的插入模板当底稿，用**编辑器真实的写入路径**
## （`ScriptDoc.set_directive_arg` / `set_directive_param` / `set_directive_rest`）
## 把每个字段改成测试值，再交给 `GvsParser` 解析，逐字段断言「写进去的值读得回来」。
##
## 跑法：headless 即可。
##   godot --headless --path . res://tools/editor/tests/op_spec_test.tscn

const OpSpec = preload("res://tools/editor/core/op_spec.gd")
const ScriptDoc = preload("res://tools/editor/core/script_doc.gd")
const GvsParser = preload("res://scripts/core/gvs_parser.gd")

## 模板单独一行**必然缺参数**的指令 —— 它们的必填位置参数是自由文本（没有默认值，
## 占位符是 `<变量>` 这种），直接解析会报「缺参数」。这里给一份能独立解析的底稿。
const STANDALONE := {
	"set": "set 变量名 1",
	"add": "add 变量名 1",
	"sub": "sub 变量名 1",
	"carry": "carry flag 旗标名",
	"chapter": "chapter 章节标题",
	"ending": "ending 结局id \"结局标题\"",
	"unlock": "unlock cg cg_classroom",
	"jump": "jump 目标标签\nlabel 目标标签",
	"goto": "goto 目标标签\nlabel 目标标签",
	"call": "call 子过程\nlabel 子过程",
	"jump_file": "jump_file res://data/scripts/prologue.gvs start",
	"together": "together\nend",
}

## 解析出来的 op 名字会变的（别名）
const OP_ALIAS := {
	"pause": "wait_click",
	"goto": "jump",
	"sub": "add",       # 解析器把 sub 记成「add + 负数」
}

## 写进去的值会被**转换**的指令 —— 只查「值有没有出现」，不做严格比对。
## `sub 变量 1.25` 解析出来是 `amount = -1.25`，严格比对必然不等。
const CONTAINS_ONLY := {
	"sub": "解析器把它记成 add + 负数，值被取了反",
}

## 这些字段**没法用任意测试值往返**：
##   · `label` —— 标签引用必须指向真实存在的标签，随便改名就解析不过
##   · `asset` —— 素材 id 必须真实存在（素材索引为空时无从下手）
const SKIP_TYPES := ["label", "asset"]

## 故意不给字段规格的指令。它们靠别的路径编辑：
##   · 结构 / 块指令：渲染成只读行，由「插入」而不是「转换」产生
##   · 对白 / 旁白：走对白行那条路径（说话人下拉选「（旁白）」）
const NO_SPEC_BY_DESIGN := [
	"label", "return", "if", "elif", "else", "end", "choice",
	"narr", "narration",
]

## 有规格但**不进插入菜单**的指令，理由要写清楚
const MENU_EXEMPT := {
	"pause": "`wait_click` 的别名 —— 菜单里只留一个规范写法，避免两个一模一样的选项",
}

## 数字测试值。按字段序号轮换，**保证互不相同** ——
## 全用同一个数的话，「三个字段只写进去一个」也会被当成通过。
const NUM_VALUES := [1.25, 0.65, 0.45, 0.85]
## 整数参数（`step >= 1`：次数 / 帧 / 缓冲）用这组 —— 小数会被解析器 `int()` 截掉
const INT_VALUES := [3, 4, 5, 6]

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== OpSpec ↔ 解析器一致性守卫 ===")
	_check_coverage()
	_check_kind_filtering()
	_check_roundtrip()
	_finish()


# ---------------------------------------------------------------------------
# 1. 覆盖率：每条指令在编辑器里都有落脚点
# ---------------------------------------------------------------------------

func _check_coverage() -> void:
	print("-- 指令覆盖 --")

	var missing: Array = []
	for kw in GvsParser.KEYWORDS:
		var k := String(kw)
		if OpSpec.has_spec(k) or NO_SPEC_BY_DESIGN.has(k):
			continue
		missing.append(k)
	_ok(missing.is_empty(),
		"每条关键字要么有字段规格、要么在「故意不给规格」名单里（缺：%s）"
		% ", ".join(missing))

	var in_menu := {}
	for group in OpSpec.insert_menu():
		for op in ((group as Array)[1] as Array):
			in_menu[String(op)] = true

	var unreachable: Array = []
	for op_key in OpSpec.specs().keys():
		var op := String(op_key)
		if in_menu.has(op) or MENU_EXEMPT.has(op):
			continue
		unreachable.append(op)
	_ok(unreachable.is_empty(),
		"有规格的指令都能从插入菜单选到（缺：%s）" % ", ".join(unreachable))

	# 结构指令必须有模板 —— 没有的话会插出一个光秃秃的关键字
	var no_template: Array = []
	for op2 in OpSpec.STRUCTURAL:
		if String(OpSpec.structural_template(String(op2))).strip_edges().is_empty():
			no_template.append(String(op2))
	_ok(no_template.is_empty(),
		"结构指令都有插入模板（缺：%s）" % ", ".join(no_template))


# ---------------------------------------------------------------------------
# 2. 按「效果种类」过滤字段
# ---------------------------------------------------------------------------

## 用户报的原问题：不管选哪个音频特效，界面都摆着三个参数。
## 真相是**只有 `duration` 通用** —— `strength` 有 9 个效果用得到，
## `pitch` 只有 `pitch` 一个用得到。摆出来不改，等于告诉作者「写了就有用」。
func _check_kind_filtering() -> void:
	print("-- 按种类过滤字段 --")

	var glitch_keys := _field_keys("audio_fx", {"kind": "glitch"})
	_ok(glitch_keys.has("duration") and glitch_keys.has("strength"),
		"glitch 显示 秒 / 强度（实得 %s）" % str(glitch_keys))
	_ok(not glitch_keys.has("pitch"), "glitch **不**显示「移调」（运行时压根不读它）")

	var pitch_keys := _field_keys("audio_fx", {"kind": "pitch"})
	_ok(pitch_keys.has("pitch") and pitch_keys.has("duration"),
		"pitch 显示 秒 / 移调（实得 %s）" % str(pitch_keys))
	_ok(not pitch_keys.has("strength"), "pitch 不显示「强度」（强度由移调倍数本身表达）")

	var muffle_keys := _field_keys("audio_fx", {"kind": "muffle"})
	_ok(muffle_keys.has("strength") and not muffle_keys.has("pitch"),
		"muffle 只显示 秒 / 强度（%s）" % str(muffle_keys))

	# 清除类没有参数可调
	var off_keys := _field_keys("audio_fx", {"kind": "off"})
	_ok(not off_keys.has("duration") and not off_keys.has("strength"),
		"off / none / clear 不显示任何参数（%s）" % str(off_keys))

	# 插入模板只该带默认种类用得上的参数
	var template := OpSpec.default_text("audio_fx")
	_ok(not template.contains("pitch="),
		"插入模板不含默认效果（glitch）用不到的 pitch=（%s）" % template)
	_ok(template.contains("strength="), "插入模板带着真正生效的 strength=（%s）" % template)

	# --- 立绘位置：选「自定义」才显示 x / y ---
	var slot_keys := _field_keys("show", {"at": "center"})
	_ok(not slot_keys.has("x") and not slot_keys.has("y"),
		"位置选槽位时不显示 x / y（实得 %s）" % str(slot_keys))
	_ok(slot_keys.has("scale"), "缩放与位置无关，一直显示")
	var custom_keys := _field_keys("show", {"at": OpSpec.CUSTOM_POS})
	_ok(custom_keys.has("x") and custom_keys.has("y"),
		"位置选「自定义」时才显示 x / y（实得 %s）" % str(custom_keys))
	# move 同样
	_ok(_field_keys("move", {"at": "left"}).has("x") == false,
		"move 选槽位时也不显示 x / y")
	_ok(_field_keys("move", {"at": OpSpec.CUSTOM_POS}).has("y"), "move 选自定义时显示 y")

	# 「自定义」不在脚本里 —— 它是合成项，写回的是坐标
	_ok(not Array(OpSpec.ANCHORS).has(OpSpec.CUSTOM_POS),
		"「自定义」不是真的槽位（不会写进剧本）")
	var at_field: Dictionary = {}
	for f in OpSpec.get_spec("show").get("fields", []):
		if String((f as Dictionary).get("key", "")) == "at":
			at_field = f
	_ok((at_field.get("custom", {}) as Dictionary).has("sets")
		and (at_field.get("custom", {}) as Dictionary).has("clears"),
		"位置字段带 custom（sets = 选中时写入的坐标，clears = 选槽位时清掉的坐标）")

	# 模板不该在「位置 = 槽位」时写坐标
	var show_tpl := OpSpec.default_text("show")
	_ok(not show_tpl.contains("x=") and not show_tpl.contains("y="),
		"插入模板不带坐标（位置默认是槽位）：%s" % show_tpl)


func _field_keys(op: String, ctx: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for f in OpSpec.fields_for(op, ctx):
		out.append(String((f as Dictionary).get("key", "")))
	return out


# ---------------------------------------------------------------------------
# 3. 字段往返：写进去的值必须读得回来
# ---------------------------------------------------------------------------

func _check_roundtrip() -> void:
	print("-- 字段往返 --")
	var problems: Array = []
	var checked := 0
	var ops := OpSpec.specs().keys()
	ops.sort()

	for op_key in ops:
		var op := String(op_key)
		var base := String(STANDALONE.get(op, _template_of(op)))
		var doc := ScriptDoc.new()
		doc.set_full_text("label start\n" + base + "\n")
		var line := doc.line_at(2)
		if line == null:
			problems.append("%s：底稿只有 %d 行" % [op, doc.line_count()])
			continue

		# 逐字段写测试值（走编辑器真实的写入路径）
		var plan: Array = []
		var idx := 0
		for fd in OpSpec.fields_for(op, OpSpec.default_context(op)):
			var f: Dictionary = fd
			if SKIP_TYPES.has(String(f.get("type", ""))):
				continue
			var value: Variant = _test_value(f, _current_of(line, f), idx)
			if value == null:
				continue
			idx += 1
			plan.append({"field": f, "value": value})
			_write_field(doc, 2, f, value)

		var r := GvsParser.parse(doc.to_text(), "roundtrip.gvs")
		if not bool(r["ok"]):
			problems.append("%s：写完字段后解析不过（%s）｜%s"
				% [op, str(r["errors"]), doc.text_at(2)])
			continue
		var cmd := _find_cmd(r, String(OP_ALIAS.get(op, op)))
		if cmd.is_empty():
			problems.append("%s：解析结果里找不到这条指令（%s）" % [op, doc.text_at(2)])
			continue

		for item in plan:
			var d: Dictionary = item
			var f2: Dictionary = d["field"]
			var key := String(f2.get("key", ""))
			var want := _fmt(d["value"])
			var strict := cmd.has(key) and not CONTAINS_ONLY.has(op)
			if strict:
				# 字段名与指令字典的键一致 → 严格比对
				if _fmt(cmd[key]) != want:
					problems.append("%s.%s：期望 %s，实得 %s"
						% [op, key, want, _fmt(cmd[key])])
			else:
				# 键名不一样（`bg` 的 `fade` 存成 `duration`、`show` 的 `type`
				# 存成 `transition`）→ 退一步查「这个值有没有出现」。
				# 够用来抓「参数被静默丢掉」，也不会因为改名而误报。
				if not str(cmd).contains(want):
					problems.append("%s.%s：写进去的 %s 在解析结果里找不到（%s）"
						% [op, key, want, str(cmd)])
			checked += 1

	if problems.is_empty():
		_ok(true, "%d 个字段写进去的值都读得回来" % checked)
	else:
		_ok(false, "%d 个字段里有问题：\n      %s"
			% [problems.size(), "\n      ".join(problems)])

	# 位置切到「自定义」之后 x / y 才出现 —— 上面的循环用的是默认上下文，
	# 那两个字段是隐藏的，得单独测一遍。
	_check_custom_pos("show")
	_check_custom_pos("move")


## 模拟「位置下拉选自定义」的完整写回（写坐标 + 删掉 at=），
## 断言解析器真的按坐标摆位（槽位没了、x / y 有值）。
##
## ⚠️ 不能断言 `at` 为空：`show` 的解析器默认值就是 `center`，
## 缺省和「显式写了 center」在结果里是一样的。所以先写一个**别的槽位**
## 再删掉，然后断言它没留下来 —— 这才真的证明「删除生效了」。
func _check_custom_pos(op: String) -> void:
	var doc := ScriptDoc.new()
	doc.set_full_text("label start\n" + _template_of(op) + "\n")
	doc.set_directive_param(2, "at", "left")
	doc.set_directive_param(2, "x", 640.0)
	doc.set_directive_param(2, "y", 900.0)
	doc.strip_directive_param(2, "at")
	var r := GvsParser.parse(doc.to_text(), "custom.gvs")
	var cmd := _find_cmd(r, op)
	_ok(bool(r["ok"])
			and is_equal_approx(float(cmd.get("x", 0.0)), 640.0)
			and is_equal_approx(float(cmd.get("y", 0.0)), 900.0)
			and String(cmd.get("at", "")) != "left",
		"%s 切到自定义后槽位被清掉、坐标能读回来（%s）" % [op, doc.text_at(2)])


func _template_of(op: String) -> String:
	if OpSpec.is_structural(op):
		return OpSpec.structural_template(op)
	return OpSpec.default_text(op)


## 测试值。**故意不等于当前值** —— 否则「压根没写进去」也会被当成通过。
func _test_value(fd: Dictionary, current: String, idx: int) -> Variant:
	match String(fd.get("type", "")):
		OpSpec.F_ENUM:
			for v in (fd.get("values", []) as Array):
				if String(v) != current:
					return String(v)
			return null
		OpSpec.F_NUM:
			# `step >= 1` 的是**整数**参数（次数 / 帧 / 缓冲）——
			# 写 1.25 进去会被解析器的 `int()` 截成 1，断言就变成假失败。
			var int_field := float(fd.get("step", 0.0)) >= 1.0
			var pool: Array = INT_VALUES if int_field else NUM_VALUES
			for v in pool:
				if _fmt(v) != current:
					return v
			return null
		OpSpec.F_BOOL:
			return current != "true"
		OpSpec.F_TEXT:
			return "测试值"
		OpSpec.F_EXPR:
			return "smile" if current != "smile" else "normal"
	return null


func _current_of(line, fd: Dictionary) -> String:
	if fd.has("pos"):
		var p := int(fd["pos"])
		if p >= 0 and p < line.args.size():
			return String(line.args[p])
		return ""
	return _fmt(line.params.get(String(fd.get("key", "")), ""))


## 走编辑器真实的写入路径（与 `TablePanel._field_write` 一致）
func _write_field(doc, no: int, fd: Dictionary, value: Variant) -> void:
	if fd.has("pos"):
		var p := int(fd["pos"])
		if fd.get("tail", false):
			doc.set_directive_tail(no, p, _fmt(value))
		elif fd.get("rest", false):
			doc.set_directive_rest(no, p, _fmt(value))
		else:
			doc.set_directive_arg(no, p, _fmt(value))
		return
	doc.set_directive_param(no, String(fd.get("key", "")), value)


static func _find_cmd(result: Dictionary, op: String) -> Dictionary:
	for c in (result.get("commands", []) as Array):
		var cmd: Dictionary = c
		if String(cmd.get("op", "")) == op:
			return cmd
	return {}


static func _fmt(v: Variant) -> String:
	match typeof(v):
		TYPE_BOOL:
			return "true" if bool(v) else "false"
		TYPE_INT:
			return str(int(v))
		TYPE_FLOAT:
			var f := float(v)
			if is_equal_approx(f, roundf(f)):
				return str(int(roundf(f)))
			return String.num(f, 4)
		TYPE_NIL:
			return ""
	return str(v)


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
