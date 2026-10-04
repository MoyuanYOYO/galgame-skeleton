extends Node

## 素材引用重写验收（纯逻辑，可 headless）
##
## 素材改名 / 删除最怕的不是「改不动」，是**改坏**：
## 台词正文里出现同名的词、前缀相同的另一个 id、注释里的名字……
## 这些改错了剧本不报错，只是画面黑掉或者台词变了 —— 所以每条都要断言。
##
## 跑法：
##   godot --headless --path . res://tools/editor/tests/asset_refs_test.tscn

const AssetRefs = preload("res://tools/editor/core/asset_refs.gd")

const A := "user://__ar_a.gvs"
const B := "user://__ar_b.gvs"

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 素材引用重写验收 ===")
	_case_bg()
	_case_char()
	_case_expr()
	_case_purity()
	_case_find_and_dry_run()
	_cleanup()
	_finish()


# ---------------------------------------------------------------------------
# 1. 平铺素材（背景）
# ---------------------------------------------------------------------------

func _case_bg() -> void:
	_sec("背景改名")
	var files := _setup({
		A: _lines([
			"# 注释里提到 classroom，不许动",
			"label start",
			"bg classroom fade=0.8",
			"bg  classroom   # 两个空格 + 行尾注释",
			"    bg classroom",
			"bg classroom2",
			"cg classroom",
			"alice@smile: 我笑了 smile。",
			"narr （教室里没有人。）",
		]),
		B: _lines([
			"label x",
			"bg classroom",
			"unlock cg cg_classroom",
		]),
	})
	var r := AssetRefs.rewrite_asset("bg", "classroom", "classroom_dusk", files)
	_ok(int(r["lines"]) == 4, "改了 4 行（A 三行 + B 一行，实得 %d）" % int(r["lines"]))
	_ok(int(r["files"]) == 2, "两个文件都被改到（实得 %d）" % int(r["files"]))

	var a := _read(A)
	_ok(a.contains("bg classroom_dusk fade=0.8"), "位置参数被换掉，后面的 kv 保留")
	_ok(a.contains("bg  classroom_dusk   # 两个空格 + 行尾注释"),
		"多空格与行尾注释原样保留")
	_ok(a.contains("    bg classroom_dusk"), "行首缩进保留")
	_ok(a.contains("bg classroom2"), "⚠ 前缀相同的另一个 id（classroom2）不受影响")
	_ok(a.contains("# 注释里提到 classroom，不许动"), "注释行一字不改")
	_ok(a.contains("cg classroom"), "别的指令的同名参数不受影响（cg 不是 bg）")
	_ok(a.contains("alice@smile: 我笑了 smile。"), "对白正文一字不改")
	_ok(a.contains("narr （教室里没有人。）"), "旁白一字不改")
	_ok(_read(B).contains("bg classroom_dusk"), "另一个剧本也被改到")
	_ok(_read(B).contains("unlock cg cg_classroom"), "cg 的 unlock 不被 bg 改名波及")

	# `unlock cg <id>` 的 id 在第二个位置参数上，且要按 type 分流
	var files2 := _setup({
		A: _lines([
			"unlock cg cg_classroom",
			"unlock music cg_classroom",
			"cg cg_classroom",
		]),
	})
	AssetRefs.rewrite_asset("cg", "cg_classroom", "cg_classroom_am", files2)
	var a2 := _read(A)
	_ok(a2.contains("unlock cg cg_classroom_am"), "unlock cg 的 id 被改")
	_ok(a2.contains("unlock music cg_classroom"), "⚠ unlock music 的同名 id 不受影响")
	_ok(a2.contains("cg cg_classroom_am"), "cg 指令被改")


# ---------------------------------------------------------------------------
# 2. 角色改名
# ---------------------------------------------------------------------------

func _case_char() -> void:
	_sec("角色改名")
	var files := _setup({
		A: _lines([
			"show alice expr=smile at=left",
			"    hide alice fade=0.3",
			"move alice x=960",
			"expr alice smile",
			"anim alice speed=1.2",
			"alice: 你好。",
			"alice@smile: 又见面了。",
			"carol: 我不是 alice。",
			"affection alice 5",
			"if affection alice >= 10",
			"    affection alice -5",
			"carry affection alice",
			"elif affection alice >= 5   # alice 的备注",
			"# show alice 的注释",
		]),
	})
	AssetRefs.rewrite_asset("char", "alice", "carol", files)
	var a := _read(A)
	_ok(a.contains("show carol expr=smile at=left"), "show 的角色被改")
	_ok(a.contains("    hide carol fade=0.3"), "缩进行里的 hide 也被改，缩进保留")
	_ok(a.contains("move carol x=960"), "move 被改")
	_ok(a.contains("expr carol smile"), "expr 的第一参数被改，表情没动")
	_ok(a.contains("anim carol speed=1.2"), "anim 被改")
	_ok(a.contains("carol: 你好。"), "对白前缀的说话人被改")
	_ok(a.contains("carol@smile: 又见面了。"), "说话人改了、表情保留")
	_ok(a.contains("carol: 我不是 alice。"),
		"⚠ 说话人不是 alice 的对白，正文里的 alice 不许动")
	_ok(a.contains("affection carol 5"), "affection 的键被改（否则会有幽灵角色）")
	_ok(a.contains("if affection carol >= 10"), "if 条件里的角色名被改")
	_ok(a.contains("    affection carol -5"), "块内的 affection 被改")
	_ok(a.contains("carry affection carol"), "carry affection 的名字被改")
	_ok(a.contains("elif affection carol >= 5   # alice 的备注"),
		"elif 条件被改，行尾注释里的 alice 保留")
	_ok(a.contains("# show alice 的注释"), "注释行一字不改")


# ---------------------------------------------------------------------------
# 3. 表情改名
# ---------------------------------------------------------------------------

func _case_expr() -> void:
	_sec("表情改名")
	var files := _setup({
		A: _lines([
			"show alice expr=smile at=center",
			"show bob expr=smile",
			"expr alice smile",
			"expr bob smile",
			"alice@smile: 早上好。",
			"bob@smile: 早。",
			"alice@happy: 我笑了 smile。",
			"narr （smile 是英文单词。）",
		]),
	})
	AssetRefs.rewrite_expr("alice", "smile", "beaming", files)
	var a := _read(A)
	_ok(a.contains("show alice expr=beaming at=center"), "alice 的 show expr 被改")
	_ok(a.contains("show bob expr=smile"), "⚠ bob 的同名表情不受影响")
	_ok(a.contains("expr alice beaming"), "expr 指令的第二个参数被改")
	_ok(a.contains("expr bob smile"), "⚠ bob 的 expr 不受影响")
	_ok(a.contains("alice@beaming: 早上好。"), "对白前缀的表情被改")
	_ok(a.contains("bob@smile: 早。"), "⚠ bob 的对白前缀不受影响")
	_ok(a.contains("alice@happy: 我笑了 smile。"),
		"⚠ 表情本来就不是 smile 的对白：正文里的 smile 不许动")
	_ok(a.contains("narr （smile 是英文单词。）"), "旁白一字不改")


# ---------------------------------------------------------------------------
# 4. 保真
# ---------------------------------------------------------------------------

func _case_purity() -> void:
	_sec("保真")
	# 只改一行 → 其余行必须逐字节相同
	var original := _lines([
		"# 注释",
		"",
		"label start",
		"bg classroom fade=0.8",
		"",
		"alice@smile: 第一句。",
		"    alice: 缩进的第二句。",
		"narr （旁白。）",
		"",
		"label next",
		"ending normal \"春日的答案\"",
	])
	var files := _setup({A: original})
	AssetRefs.rewrite_asset("bg", "classroom", "rooftop", files)
	var after := _read(A)
	var before_lines := original.split("\n")
	var after_lines := after.split("\n")
	_ok(before_lines.size() == after_lines.size(), "行数不变")
	var diff := 0
	for i in before_lines.size():
		if before_lines[i] != after_lines[i]:
			diff += 1
	_ok(diff == 1, "只有 1 行不同（实得 %d）" % diff)
	_ok(after_lines[3] == "bg rooftop fade=0.8", "改的正是那一行")

	# 没有引用时不写盘（mtime 不该变）
	var files2 := _setup({A: "label start\nnarr （没有素材引用。）\n"})
	var r := AssetRefs.rewrite_asset("bg", "nothing_here", "whatever", files2)
	_ok(int(r["files"]) == 0 and int(r["lines"]) == 0, "没有引用时什么都不做")


# ---------------------------------------------------------------------------
# 5. 查引用 / dry run
# ---------------------------------------------------------------------------

func _case_find_and_dry_run() -> void:
	_sec("查引用")
	var src := _lines([
		"bg classroom",
		"bg classroom",
		"alice@smile: 我笑了 smile。",
	])
	var files := _setup({A: src})
	var hits := AssetRefs.find_asset("bg", "classroom", files)
	_ok(hits.size() == 2, "找到 2 处引用（实得 %d）" % hits.size())
	_ok(int((hits[0] as Dictionary).get("line", 0)) == 1, "第一处在第 1 行")
	_ok(_read(A) == src, "⚠ find 是只读的：文件一个字节都没变")

	var hits2 := AssetRefs.find_expr("alice", "smile", files)
	_ok(hits2.size() == 1, "表情只认前缀里的那个（实得 %d）" % hits2.size())

	# 命中数必须等于实际改写行数 —— 否则「提示 N 处、实际改 M 处」
	var r := AssetRefs.rewrite_asset("bg", "classroom", "hall", files)
	_ok(int(r["lines"]) == hits.size(),
		"find 与 rewrite 的口径一致（find %d / rewrite %d）" % [hits.size(), int(r["lines"])])


# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------

func _setup(texts: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for k in texts.keys():
		_write(String(k), String(texts[k]))
		out.append(String(k))
	return out


static func _lines(arr: Array) -> String:
	return "\n".join(PackedStringArray(arr)) + "\n"


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


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
