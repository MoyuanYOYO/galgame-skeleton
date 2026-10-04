extends Node

## 对白表格「流畅度」验收 —— 加一行不许重画整张表
##
## **真正的守卫不是时间阈值，而是「已有行控件还是不是同一批对象」。**
## 时间阈值在别人的机器上会飘；而「插入后其余行的实例 ID 必须原封不动」
## 是确定性的 —— 一旦有人把增量路径改回全量 `rebuild()`，这条立刻失败。
##
## 时间只打印出来看趋势（顺便断言一个很宽松的上限，防止 O(n²) 回归）。
##
## 跑法（要带窗口）：
##   godot --path . res://tools/editor/tests/table_perf_test.tscn

const EditorScene = preload("res://tools/editor/editor.tscn")

## 时间阈值只当**宽松的回归哨兵**，不当性能目标 ——
## 它随机器浮动，真正的守卫是下面那条「已有行控件必须还是同一批对象」。
##
## 参考实测（247 行文档，本机）：加一行 ~31ms（改之前 ~600ms），
## 全量重建 ~510ms。全量重建只在**打开文件时发生一次** ——
## 切页 / 过滤 / 折叠 / 增删都已经不走它了（`_is_built` 会跳过）。
## 它剩下的开销是 Godot 每个 Control 的固有构造与入树成本，
## 247 行 × 约 12 个控件，没有便宜可捡。
const INSERT_BUDGET_MS := 150.0
## 这个数字**只是「别退化一个数量级」的哨兵**，不是性能目标：
## 同一台机器上实测在 540~1200ms 之间浮动（取决于当时有多少个 Godot 实例在跑），
## 定太紧会变成随机失败。真正的守卫是下面那条「已有行控件必须是同一批对象」。
const REBUILD_BUDGET_MS := 2500.0

var _ed: Control
var _tbl: Control
var _tmp := "user://__table_perf.gvs"
var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 对白表格 流畅度验收 ===")

	# 用真剧本的副本：246 行，够体现 O(n²) 与 O(n) 的差别
	var src := FileAccess.get_file_as_string("res://data/scripts/prologue.gvs")
	_write(_tmp, src)

	_ed = EditorScene.instantiate()
	add_child(_ed)
	_ed.size = get_viewport().get_visible_rect().size
	await _wait(1.0)
	_ed._open(_tmp)
	await _wait(0.5)
	_ed.show_page("table")
	await _wait(0.8)
	_tbl = _ed._pages.get("table")
	_ok(_tbl != null, "对白表格面板已创建")
	if _tbl == null:
		_finish()
		return
	_ok(_ed.doc.line_count() >= 200, "文档够大（%d 行）" % _ed.doc.line_count())

	await _test_full_rebuild_budget()
	await _test_insert_is_incremental()
	await _test_edit_one_row_is_incremental()
	await _test_anchor_ignores_offscreen_row()
	await _test_goto_hidden_line()

	_ed.queue_free()
	await _wait(0.3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp))
	_finish()


## 全量重建也要在可接受范围内（它现在只用在「打开文件」上）
func _test_full_rebuild_budget() -> void:
	_sec("全量重建（只在打开文件时走一次）")
	var t := Time.get_ticks_usec()
	_tbl.rebuild()
	var ms := (Time.get_ticks_usec() - t) / 1000.0
	print("      rebuild() = %.1f ms（%d 行）" % [ms, _ed.doc.line_count()])
	_ok(ms < REBUILD_BUDGET_MS, "全量重建 < %.0fms（实得 %.1f ms）" % [REBUILD_BUDGET_MS, ms])
	# 切回本页不该再重建（否则每次切页都要等半秒）
	var t2 := Time.get_ticks_usec()
	_tbl.on_shown()
	var ms2 := (Time.get_ticks_usec() - t2) / 1000.0
	print("      on_shown() = %.1f ms（文档没变 → 应走快路径）" % ms2)
	_ok(ms2 < 60.0, "切回本页不重建整表（实得 %.1f ms）" % ms2)


## **核心**：回车加一行，只能新增一个行控件，其余行必须原封不动
func _test_insert_is_incremental() -> void:
	_sec("加一行是增量的（不重画整张表）")

	var at := _find_line("alice: 第 20 句。")
	if at <= 0:
		# 真剧本里没有这句，退而取中间一行
		at = maxi(2, _ed.doc.line_count() / 2)
	var before := _snapshot_ids()
	var n0: int = _ed.doc.line_count()

	var t := Time.get_ticks_usec()
	_tbl._insert_say(at)
	var ms := (Time.get_ticks_usec() - t) / 1000.0
	await _wait(0.4)

	print("      _insert_say(%d) = %.1f ms" % [at, ms])
	_ok(_ed.doc.line_count() == n0 + 1, "文档行数 +1")
	_ok(ms < INSERT_BUDGET_MS, "加一行 < %.0fms（实得 %.1f ms）" % [INSERT_BUDGET_MS, ms])

	var after := _snapshot_ids()
	var same := true
	var moved := 0
	for no in before.keys():
		var old_id: int = before[no]
		var new_no: int = int(no) if int(no) < at + 1 else int(no) + 1
		if not after.has(new_no) or int(after[new_no]) != old_id:
			same = false
			print("      行 %d 的控件被换掉了（旧 %d → 新 %s）" % [
				no, old_id, str(after.get(new_no, "无"))])
			break
		moved += 1
	_ok(same, "插入点之外的 %d 个行控件**仍是同一批对象**（没有重画整表）" % moved)
	_ok(after.size() == before.size() + 1, "表体只多了一个行控件")


## 改一行的说话人 / 参数，也只重建那一行
func _test_edit_one_row_is_incremental() -> void:
	_sec("改一行只重建那一行")

	var at := _find_line("alice: 第 30 句。")
	if at <= 0:
		at = maxi(2, _ed.doc.line_count() / 2 + 3)
	var before := _snapshot_ids()
	var row_before := int(before.get(at, 0))
	_ok(row_before != 0, "目标行有控件（第 %d 行）" % at)

	_tbl._commit_speaker(_tbl._row_by_no[at] as Control, "bob")
	await _wait(0.3)

	var after := _snapshot_ids()
	_ok(int(after.get(at, 0)) != row_before, "被改的那一行确实重建了")
	var others_same := true
	for no in before.keys():
		if int(no) == at:
			continue
		if int(after.get(no, 0)) != int(before[no]):
			others_same = false
			print("      行 %d 被牵连重建" % no)
			break
	_ok(others_same, "其余行一个都没动")


## **落点永远是「当前行」，视图不会被拽走。**
##
## 用户报的「连续按回车会跳到最顶层」有两条错误路径，都在这条测试里守住：
##   ① 落点被改成「视口顶端那一行」→ 内容被写到别处，新行冒到最顶上；
##   ② 视图去追屏幕外的当前行 → 实测滚动位置从 7139 跳到 794。
##
## 正确行为：**落点不变（插在当前行之后），视图一动不动**，
## 新行在视口外时给一句明确提示（否则「按了回车屏幕没变」会被当成没生效）。
##
## 这条要在**够长的文档**上测（短文档根本滚不动），所以放在这里。
func _test_anchor_ignores_offscreen_row() -> void:
	_sec("落点永远是当前行，视图不被拽走")

	_tbl._set_current(10)
	await _wait(0.3)
	_tbl._scroll.scroll_vertical = 999999
	await _wait(0.5)
	var far: int = _tbl._current_no
	var scroll_before: int = _tbl._scroll.scroll_vertical
	_ok(not _tbl._row_in_view(far),
		"当前行（第 %d 行）确实在屏幕外（scroll=%d）" % [far, scroll_before])
	_ok(_tbl._anchor_no() == far, "落点仍然是当前行（实得 %d）" % _tbl._anchor_no())

	var ev := InputEventKey.new()
	ev.keycode = KEY_ENTER
	ev.pressed = true
	get_viewport().gui_release_focus()
	_tbl._unhandled_key_input(ev)
	await _wait(0.7)

	_ok(_tbl._current_no == far + 1,
		"新行插在**当前行之后**，没有挪到别处（实得第 %d 行，期望 %d）"
		% [_tbl._current_no, far + 1])
	_ok(_tbl._scroll.scroll_vertical == scroll_before,
		"视图一动不动（实得 %d，插入前 %d）" % [
			_tbl._scroll.scroll_vertical, scroll_before])
	_ok(not _tbl._row_in_view(_tbl._current_no), "新行确实在视口外")
	_ok(_ed._notice.text.contains("视口外"),
		"而且明确提示了「在视口外」（实得 %s）" % _ed._notice.text)


## 跳到**隐藏行**（空行 / 注释）时要退到最近的可见行。
##
## 触发场景很常见：源码视图的光标停在空行上 → 切到表格页
## → `goto_line(caret_line)` 拿到的是个不显示的行。
## 早先的实现会因为「这一行不显示」直接放弃滚动，视图停在文件开头 ——
## 用户看到的就是「跳到最顶层」。
func _test_goto_hidden_line() -> void:
	_sec("跳到隐藏行时退到最近的可见行")

	var blank := 0
	for i in range(100, _ed.doc.line_count() + 1):
		if _ed.doc.text_at(i).strip_edges().is_empty():
			blank = i
			break
	_ok(blank > 0, "找得到一个空行（第 %d 行）" % blank)
	if blank <= 0:
		return
	_ok(not _tbl._row_visible(blank), "它确实是隐藏的（默认不显示空行与注释）")

	_tbl._scroll.scroll_vertical = 0
	await _wait(0.3)
	_tbl.goto_line(blank)
	await _wait(0.6)
	_ok(_tbl._scroll.scroll_vertical > 0,
		"视图滚到了那一行附近，没有停在文件开头（scroll=%d）"
		% _tbl._scroll.scroll_vertical)
	var top: int = _tbl._top_visible_no()
	_ok(absi(top - blank) <= 3,
		"视口顶端就在那一行附近（顶端=%d，目标=%d）" % [top, blank])


# ---------------------------------------------------------------------------

## 行号 → 控件实例 ID 的快照
func _snapshot_ids() -> Dictionary:
	var out := {}
	for no in _tbl._row_by_no.keys():
		var row := _tbl._row_by_no[no] as Object
		if row != null and is_instance_valid(row):
			out[int(no)] = row.get_instance_id()
	return out


func _find_line(prefix: String) -> int:
	for i in range(1, _ed.doc.line_count() + 1):
		if _ed.doc.text_at(i).begins_with(prefix):
			return i
	return -1


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


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
