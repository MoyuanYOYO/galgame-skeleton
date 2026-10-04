extends Node

## 变量清单验收（纯逻辑，可 headless）
##
## 这个功能的全部价值在「判定对不对」—— 判错了会给出**假的安全感**
## （工具说没问题，实际那条分支永远走不到）。所以逐种写法都要断言：
## 三种变量 × 写 / 读 × 各种写法（`set var x` vs `set x`、`not`、
## `and` 连接、`cycle` / `cleared` 这种**不是**变量的条件）。
##
## 跑法：
##   godot --headless --path . res://tools/editor/tests/var_index_test.tscn

const VarIndex = preload("res://tools/editor/core/var_index.gd")

const A := "user://__vi_a.gvs"
const B := "user://__vi_b.gvs"

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 变量清单验收 ===")
	_case_writes()
	_case_reads()
	_case_not_variables()
	_case_issues()
	_case_engine_names()
	_case_carry()
	_case_dedup()
	_cleanup()
	_finish()


# ---------------------------------------------------------------------------

func _case_writes() -> void:
	_sec("写")
	var d := _scan_one([
		"flag rhythm_qte_cleared",
		"flag seen_intro false",
		"set var stance \"defend\"",
		"set chapter 1",
		"add var coins 3",
		"sub coins 1",
		"affection alice 5",
	])
	_ok(_n(d, "flag", "rhythm_qte_cleared", "writes") == 1, "flag <名> 算写")
	_ok(_n(d, "flag", "seen_intro", "writes") == 1, "flag <名> false 也算写")
	_ok(_n(d, "var", "stance", "writes") == 1, "set var <名> 算写")
	_ok(_n(d, "var", "chapter", "writes") == 1, "⚠ 不带 var 的 `set <名>` 也算写")
	_ok(_n(d, "var", "coins", "writes") == 2, "add / sub 都算写（2 处）")
	_ok(_n(d, "affection", "alice", "writes") == 1, "affection <角色> 算写")


func _case_reads() -> void:
	_sec("读")
	var d := _scan_one([
		"if flag rhythm_qte_cleared",
		"    narr （。）",
		"end",
		"if not flag never_set",
		"    narr （。）",
		"end",
		"if var stance == \"defend\"",
		"    narr （。）",
		"end",
		"if affection alice >= 10",
		"    narr （。）",
		"end",
		"if flag a and flag a",
		"    narr （。）",
		"end",
	])
	_ok(_n(d, "flag", "rhythm_qte_cleared", "reads") == 1, "`if flag <名>` 算读")
	_ok(_n(d, "flag", "never_set", "reads") == 1, "⚠ `if not flag <名>` 也算读")
	_ok(_n(d, "var", "stance", "reads") == 1, "`if var <名> == 值` 算读")
	_ok(_n(d, "affection", "alice", "reads") == 1, "`if affection <角色> >= n` 算读")
	_ok(_n(d, "flag", "a", "reads") == 1, "同一行里出现两次只记一处")


func _case_not_variables() -> void:
	_sec("不是变量的条件")
	var d := _scan_one([
		"if cycle >= 2",
		"    narr （。）",
		"end",
		"if cleared true_end",
		"    narr （。）",
		"end",
		"if not cleared true_end",
		"    narr （。）",
		"end",
	])
	var all := VarIndex.total(d)
	_ok(all == 0, "⚠ `cycle` / `cleared` 不该被当成变量（实得 %d 个）" % all)


func _case_issues() -> void:
	_sec("两类问题")
	var d := _scan_one([
		"flag only_set",
		"if flag never_set",
		"    narr （。）",
		"end",
		"affection alice 5",
		"if affection alice >= 1",
		"    narr （。）",
		"end",
	])
	var issues: Array = VarIndex.issues(d)
	var by_name := {}
	for it in issues:
		by_name["%s/%s" % [(it as Dictionary)["kind"], (it as Dictionary)["name"]]] = it
	_ok(by_name.has("flag/only_set"), "只写不读被标出来")
	_ok(String((by_name.get("flag/only_set", {}) as Dictionary).get("level", "")) == "warn",
		"只写不读是 warn（可能只是纯记录）")
	_ok(by_name.has("flag/never_set"), "只读不写被标出来")
	_ok(String((by_name.get("flag/never_set", {}) as Dictionary).get("level", "")) == "error",
		"只读不写是 error（几乎一定是拼错，那条分支永远走不到）")
	_ok(not by_name.has("affection/alice"), "又写又读的不报")
	_ok(issues.size() == 2, "一共 2 条（实得 %d）" % issues.size())

	# 每条问题都带一个可跳转的位置
	for it in issues:
		var s: Dictionary = (it as Dictionary).get("site", {})
		if s.is_empty() or String(s.get("file", "")).is_empty():
			_ok(false, "问题项缺少可跳转的位置")
			return
	_ok(true, "每条问题都带「跳到哪一行」")


func _case_engine_names() -> void:
	_sec("引擎侧的旗标不算问题")
	# 小游戏 / 章节解锁这类旗标是引擎设或读的，剧本里查不到 ——
	# 不排除的话「只读不写」会把它们全报成错，作者看两次就不信这个功能了
	var d := _scan_one(["flag __chapter1_unlocked"])
	var issues: Array = VarIndex.issues(d)
	_ok(issues.size() == 1, "有一条记录（实得 %d）" % issues.size())
	if issues.size() == 1:
		var it: Dictionary = issues[0]
		_ok(String(it.get("level", "")) == "info",
			"⚠ 章节解锁旗标（chapters.json 的 unlock_flag）只写不读 → info（实得 %s）"
				% it.get("level", ""))
	_ok(VarIndex.problem_count(d) == 0, "problem_count 不把 info 算成问题")

	# ⚠️ 反过来：只在**注释**里出现的旗标不能算「引擎侧有」——
	# `rhythm_qte.gd` 的注释写着「成功时点亮旗标 rhythm_qte_cleared」，
	# 但代码里其实没设；这正是要报出来的真问题。
	var d2 := _scan_one([
		"if flag rhythm_qte_cleared",
		"    narr （。）",
		"end",
	])
	var i2: Array = VarIndex.issues(d2)
	_ok(i2.size() == 1, "有一条记录（实得 %d）" % i2.size())
	if i2.size() == 1:
		_ok(String((i2[0] as Dictionary).get("level", "")) == "error",
			"⚠ 只写在注释里的旗标仍按「没人设过」报错（注释不算证据）")
	_ok(VarIndex.problem_count(d2) == 1, "problem_count 算它一个")


func _case_carry() -> void:
	_sec("carry 算读")
	var d := _scan_one([
		"carry flag rhythm_qte_cleared",
		"carry var stance",
		"carry affection alice",
	])
	_ok(_n(d, "flag", "rhythm_qte_cleared", "reads") == 1, "carry flag <名> 算读")
	_ok(_n(d, "var", "stance", "reads") == 1, "carry var <名> 算读")
	_ok(_n(d, "affection", "alice", "reads") == 1, "carry affection <角色> 算读")
	_ok(_n(d, "flag", "rhythm_qte_cleared", "writes") == 0, "carry 不算写")


func _case_dedup() -> void:
	_sec("跨文件")
	var files := _setup({
		A: _lines(["flag shared", "if flag shared", "    narr （。）", "end"]),
		B: _lines(["if flag shared", "    narr （。）", "end"]),
	})
	var d := VarIndex.scan(files)
	_ok(_n(d, "flag", "shared", "writes") == 1, "写只算 A 那一次")
	_ok(_n(d, "flag", "shared", "reads") == 2, "读要跨文件累计（A 一次 + B 一次）")
	_ok(VarIndex.total(d) == 1, "同一个名字只占一条")


# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------

func _scan_one(lines: Array) -> Dictionary:
	return VarIndex.scan(_setup({A: _lines(lines)}))


func _setup(texts: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for k in texts.keys():
		_write(String(k), String(texts[k]))
		out.append(String(k))
	return out


static func _lines(arr: Array) -> String:
	return "\n".join(PackedStringArray(arr)) + "\n"


func _n(d: Dictionary, kind: String, name: String, bucket: String) -> int:
	var table: Dictionary = d.get(kind, {})
	if not table.has(name):
		return 0
	return ((table[name] as Dictionary).get(bucket, []) as Array).size()


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()


func _cleanup() -> void:
	for p in [A, B]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


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
