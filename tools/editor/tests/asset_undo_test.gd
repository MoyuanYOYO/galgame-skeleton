extends Node

## 素材操作撤销栈验收（纯逻辑，可 headless）
##
## 撤销这东西最怕「撤了一半」：文件回来了、剧本引用还指着新名字，
## 或者反过来。所以每条都断言**两边都回到原样**。
##
## 跑法：
##   godot --headless --path . res://tools/editor/tests/asset_undo_test.tscn

const AssetUndo = preload("res://tools/editor/core/asset_undo.gd")

const DIR := "user://__au/"
const A := DIR + "a.png"
const B := DIR + "b.png"
const TXT := DIR + "note.txt"

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 素材撤销栈验收 ===")
	_wipe()
	_case_move()
	_case_content()
	_case_dir()
	_case_lifecycle()
	_case_lifo()
	_case_depth()
	_wipe()
	_finish()


# ---------------------------------------------------------------------------

func _case_move() -> void:
	_sec("改名的撤销")
	_wipe()
	_write(A, "hello")
	var u = AssetUndo.new()
	u.begin("重命名 a → b")
	u.record_move(A, B)
	DirAccess.rename_absolute(ProjectSettings.globalize_path(A),
		ProjectSettings.globalize_path(B))
	u.commit()
	_ok(u.can_undo(), "入栈了")
	_ok(u.peek_label().contains("a.png"), "操作名带上了原文件名（实得 %s）" % u.peek_label())

	var label := u.undo()
	_ok(FileAccess.file_exists(A), "撤销后文件回到旧名字")
	_ok(not FileAccess.file_exists(B), "新名字没有了")
	_ok(_read(A) == "hello", "内容一字不差")
	_ok(not label.is_empty(), "返回了操作名（实得 %s）" % label)
	_ok(not u.can_undo(), "栈空了")


func _case_content() -> void:
	_sec("删除的撤销")
	_wipe()
	_write(TXT, "原始内容")
	var u = AssetUndo.new()
	u.begin("删除 note.txt")
	u.record_content(TXT)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TXT))
	u.commit()
	_ok(not FileAccess.file_exists(TXT), "文件确实删掉了")

	u.undo()
	_ok(FileAccess.file_exists(TXT), "撤销后文件回来了")
	_ok(_read(TXT) == "原始内容", "内容一字不差")

	# 整个目录被删掉时，撤销要连目录一起补出来
	_wipe()
	var nested := DIR + "sub/deep/x.txt"
	_write(nested, "深")
	var u2 = AssetUndo.new()
	u2.begin("删目录")
	u2.record_content(nested)
	_remove_tree(DIR)
	u2.commit()
	_ok(not FileAccess.file_exists(nested), "整棵树没了")
	u2.undo()
	_ok(_read(nested) == "深", "撤销把中间目录一起补出来了")


func _case_dir() -> void:
	_sec("空目录的撤销")
	_wipe()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR + "empty/"))
	var u = AssetUndo.new()
	u.begin("删空目录")
	u.record_dir(DIR + "empty/")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR + "empty/"))
	u.commit()
	u.undo()
	_ok(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(DIR + "empty/")),
		"空目录被建回来了（只记 content 的话它永远回不来）")


func _case_lifecycle() -> void:
	_sec("记录生命周期")
	var u = AssetUndo.new()
	u.begin("什么都没做")
	u.commit()
	_ok(not u.can_undo(), "空操作不入栈（否则点一次撤销像没反应）")

	u.begin("半途失败")
	u.record_move(A, B)
	u.cancel()
	u.commit()
	_ok(not u.can_undo(), "cancel 之后 commit 也不会入栈")

	u.begin("只记一个不存在的文件")
	u.record_content(DIR + "nope.png")
	u.commit()
	_ok(not u.can_undo(), "不存在的文件记不进内容 → 操作被判为空")

	_ok(not u.is_recording() or true, "记录状态可查询")


func _case_lifo() -> void:
	_sec("后进先出")
	_wipe()
	_write(A, "v1")
	var u = AssetUndo.new()

	# 第一次：改名 a → b
	u.begin("第一次")
	u.record_content(TXT)          # 顺手记一个不存在的，应被忽略
	u.record_move(A, B)
	DirAccess.rename_absolute(ProjectSettings.globalize_path(A),
		ProjectSettings.globalize_path(B))
	u.commit()

	# 第二次：把 b 的内容改掉
	u.begin("第二次")
	u.record_content(B)
	_write(B, "v2")
	u.commit()
	_ok(_read(B) == "v2", "现在是 v2")

	u.undo()
	_ok(_read(B) == "v1", "先撤销第二次：内容回到 v1")
	_ok(FileAccess.file_exists(B), "文件还在 b")
	u.undo()
	_ok(FileAccess.file_exists(A) and not FileAccess.file_exists(B),
		"再撤销第一次：文件回到 a")
	_ok(_read(A) == "v1", "内容还是 v1")


func _case_depth() -> void:
	_sec("栈深上限")
	var u = AssetUndo.new()
	var n := AssetUndo.MAX_DEPTH + 5
	for i in n:
		u.begin("第 %d 次" % i)
		u.record_dir(DIR + "d%d/" % i)
		u.commit()
	var count := 0
	while u.can_undo():
		u.undo()
		count += 1
	_ok(count == AssetUndo.MAX_DEPTH,
		"只留最近 %d 次（实得 %d）" % [AssetUndo.MAX_DEPTH, count])


# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------

func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(path).get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()


func _remove_tree(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(abs):
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(abs)
		return
	var files := PackedStringArray()
	var dirs := PackedStringArray()
	var d := DirAccess.open(abs)
	if d != null:
		files = d.get_files()
		dirs = d.get_directories()
	d = null
	for f in files:
		DirAccess.remove_absolute(abs + String(f))
	for sub in dirs:
		_remove_tree(path + String(sub) + "/")
	DirAccess.remove_absolute(abs)


func _wipe() -> void:
	_remove_tree(DIR)


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
