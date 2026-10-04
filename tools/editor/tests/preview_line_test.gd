extends Node

## 「从某一行开始预览」的底层验收（纯逻辑，可 headless）
##
## 两件事：
##   1. `GvsParser` 给每条指令盖 `line` 键 → `ScriptRunner.start_at_line()`
##      能把「源码第 N 行」映射成指令下标。
##   2. `ScriptDoc.line_state()` 要把**对白行里的内联表情**（`alice@smile:`）算进去 ——
##      否则预览永远停在 `show` 时那个表情（用户报的「表情没有变化」）。
##
## 跑法：
##   godot --headless --path . res://tools/editor/tests/preview_line_test.tscn

const GvsParser = preload("res://scripts/core/gvs_parser.gd")
const ScriptRunner = preload("res://scripts/core/script_runner.gd")
const ScriptDoc = preload("res://tools/editor/core/script_doc.gd")
const LineIndex = preload("res://tools/editor/core/line_index.gd")

## ⚠️ 用 `var` 不用 `const` —— `PackedStringArray.join()` 不是常量表达式，
## 写成 const 会在**解析期**报错（然后整个场景加载不了、测试挂死到 timeout）。
var SCRIPT := "\n".join(PackedStringArray([
	"# 注释：不该被当成可执行行",
	"label start",
	"bg classroom",
	"show alice expr=normal",
	"alice@smile: 第一句。",
	"alice@normal: 第二句。",
	"expr alice angry",
	"alice@angry: 第三句。",
	"choice",
	"    \"选 A\" -> label_a",
	"    \"选 B\" -> label_b",
	"end",
	"label label_a",
	"narr （A。）",
	"ending a \"A\"",
	"label label_b",
	"narr （B。）",
	"ending b \"B\"",
])) + "\n"

var _pass := 0
var _fail := 0
var _said: Array = []


func _ready() -> void:
	print("=== 按行预览 / 行内表情验收 ===")
	_case_parser_line()
	_case_start_at_line()
	_case_choice_option()
	_case_no_command()
	_case_line_state_expr()
	_finish()


# ---------------------------------------------------------------------------
# 1. 解析器盖行号
# ---------------------------------------------------------------------------

func _case_parser_line() -> void:
	_sec("解析器盖 line 键")
	var r := GvsParser.parse(SCRIPT, "t.gvs")
	_ok(bool(r["ok"]), "解析通过")
	var cmds: Array = r["commands"]
	_ok(cmds.size() > 0, "有指令（%d 条）" % cmds.size())

	var missing := 0
	var mono := true
	var last := 0
	for c in cmds:
		var d: Dictionary = c
		if not d.has("line"):
			missing += 1
			continue
		if int(d["line"]) < last:
			mono = false
		last = int(d["line"])
	_ok(missing == 0, "每条指令都有 line（缺 %d 条）" % missing)
	_ok(mono, "line 单调不减（按源码顺序发出）")

	# 具体抽查：bg 那一条应当落在第 3 行
	var bg_line := -1
	for c in cmds:
		var d2: Dictionary = c
		if String(d2.get("op", "")) == "bg":
			bg_line = int(d2["line"])
			break
	_ok(bg_line == 3, "bg 指令盖的是第 3 行（实得 %d）" % bg_line)


# ---------------------------------------------------------------------------
# 2. 从指定行开始跑
# ---------------------------------------------------------------------------

func _case_start_at_line() -> void:
	_sec("start_at_line")
	# 第 5 行 = `alice@smile: 第一句。`，第 6 行 = `alice@normal: 第二句。`
	_ok(_first_say_at(5) == "第一句。", "从第 5 行开始 → 第一句就是「第一句。」（实得 %s）"
		% _first_say_at(5))
	_ok(_first_say_at(6) == "第二句。", "从第 6 行开始 → 「第二句。」（实得 %s）"
		% _first_say_at(6))
	# 第 8 行是 `alice@angry: 第三句。`，前面第 7 行是 `expr alice angry`
	_ok(_first_say_at(8) == "第三句。", "从第 8 行开始 → 「第三句。」（实得 %s）"
		% _first_say_at(8))

	# 从第 3 行（bg）开始：没有对白，应当直接跑下去撞到第 5 行的 say
	_ok(_first_say_at(3) == "第一句。", "从 bg 行开始 → 撞到后面第一句对白（实得 %s）"
		% _first_say_at(3))

	# 行号可以落在「没有指令的行」上（注释行）→ 落到后面第一条指令
	_ok(_first_say_at(1) == "第一句。", "从注释行开始 → 落到后面第一条指令（实得 %s）"
		% _first_say_at(1))


func _case_choice_option() -> void:
	_sec("落在 choice 选项行上")
	var runner = ScriptRunner.new()
	add_child(runner)
	runner.load_text(SCRIPT, "res://t.gvs")
	# 第 10 行 = `    "选 B" -> label_b`
	var ok := runner.start_at_line(10)
	_ok(ok, "start_at_line 返回 true")
	_ok(runner.is_waiting_choice(), "从选项行开始 → 停在「等待选择」（而不是跳过整个 choice）")
	runner.queue_free()


func _case_no_command() -> void:
	_sec("这一行之后没有指令")
	var runner = ScriptRunner.new()
	add_child(runner)
	runner.load_text(SCRIPT, "res://t.gvs")
	_ok(not runner.start_at_line(999), "超出文件末尾 → 返回 false（调用方退回按标签开始）")
	_ok(not runner.start_at_line(0), "行号 0 → false")
	runner.queue_free()


# ---------------------------------------------------------------------------
# 3. 行内表情要进 line_state
# ---------------------------------------------------------------------------

func _case_line_state_expr() -> void:
	_sec("对白行的内联表情")
	var doc = ScriptDoc.new()
	doc.set_full_text(SCRIPT, false)
	_ok(doc.line_count() > 10, "文档载入（%d 行）" % doc.line_count())

	# 第 4 行 `show alice expr=normal` → 第 5 行 `alice@smile:` 要把表情换掉，
	# 第 6 行 `alice@normal:` 再换回来 —— 这就是「对白行里的内联表情」。
	_ok(_expr_at(doc, 4) == "normal", "第 4 行 show 之后是 normal（实得 %s）" % _expr_at(doc, 4))
	_ok(_expr_at(doc, 5) == "smile",
		"⚠ 第 5 行 `alice@smile:` → 表情变 smile（实得 %s）" % _expr_at(doc, 5))
	_ok(_expr_at(doc, 6) == "normal",
		"第 6 行 `alice@normal:` → 换回 normal（实得 %s）" % _expr_at(doc, 6))
	# 第 7 行是 `expr alice angry`，第 8 行 `alice@angry:` 沿用
	_ok(_expr_at(doc, 7) == "angry", "第 7 行 `expr alice angry`（实得 %s）" % _expr_at(doc, 7))
	_ok(_expr_at(doc, 8) == "angry", "第 8 行仍是 angry（实得 %s）" % _expr_at(doc, 8))

	# 没上台的角色不该被对白凭空加上去
	doc.set_full_text("label start\nalice@smile: 人还没上来。\n", false)
	var st: Dictionary = doc.line_state(2)
	_ok((st.get("chars", []) as Array).is_empty(),
		"角色不在台上时，对白里的 @表情 不会把它加进来")

	# 背景等累积状态仍然正常
	doc.set_full_text(SCRIPT, false)
	var st2: Dictionary = doc.line_state(8)
	_ok(String(st2.get("bg", "")) == "classroom", "累积背景仍在（实得 %s）" % st2.get("bg", ""))


func _expr_at(doc, no: int) -> String:
	var st: Dictionary = doc.line_state(no)
	for c in st.get("chars", []):
		var d: Dictionary = c
		if String(d.get("id", "")) == "alice":
			return String(d.get("expr", ""))
	return ""


## 从第 no 行开始跑，返回第一句台词
func _first_say_at(no: int) -> String:
	var runner = ScriptRunner.new()
	add_child(runner)
	_said = []
	runner.say.connect(func(_sp: String, text: String, _ex: String) -> void:
		_said.append(text))
	runner.load_text(SCRIPT, "res://t.gvs")
	runner.start_at_line(no)
	var out := String(_said[0]) if _said.size() > 0 else "<无>"
	runner.queue_free()
	return out


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
