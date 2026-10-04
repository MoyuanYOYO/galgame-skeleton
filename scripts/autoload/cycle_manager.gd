extends Node

## 多周目管理器（Autoload）
##
## 记三件事：
##   · 当前是第几周目（1 起）
##   · 通关记录：每个结局被抵达过几次、先后顺序
##   · 继承数据：剧本用 `carry` 显式标记的旗标 / 变量 / 好感度，
##     在抵达结局时快照下来，下一周目开局自动还回去
##
## 与 GameManager 的分工：
##   GameManager   管「这一周目之内的软状态」，reset_run() 会把它们清空
##   CycleManager  管「跨周目延续的东西」，只有 begin_new_run() 会推进周目
##                 并把继承数据写回 GameManager
##
## 落盘 user://cycle.json，**和存档分离**（同 CollectionManager / ReadTracker）：
## 通关战绩是「这台机器上的记忆」，读一份旧档不该把它抹掉。
## 但「当前周目」是进度的一部分 —— 它决定剧本走哪条分支 ——
## 所以存档里单独带一份，读档时用 from_save_dict() 还原。
##
## 用法（main.gd 里的三处接线）：
##   _on_script_ended()      → record_ending(id)
##   _on_start_requested()   → begin_new_run(advance)
##   _build_payload()        → to_save_dict()

signal cycle_changed(cycle: int)
signal ending_recorded(ending_id: String, count: int)

const SAVE_PATH := "user://cycle.json"
const SAVE_VERSION := 1

## carry 的三种类型
const CARRY_FLAG := "flag"
const CARRY_VAR := "var"
const CARRY_AFFECTION := "affection"
const CARRY_KINDS: PackedStringArray = [CARRY_FLAG, CARRY_VAR, CARRY_AFFECTION]

var _cycle: int = 1
## 结局 id -> 抵达次数
var _clears: Dictionary = {}
## 首次抵达的先后顺序（记录面板按它排，比字典的乱序好看）
var _clear_order: Array = []
var _total_clears: int = 0
## 本周目已经抵达过结局 —— 下次「开始游戏」就进下一周目
var _advance_pending: bool = false
## 本周目剧本用 carry 标记过的键。开局清空，随剧本执行重新收集 ——
## 这样「这一周目标记了什么」永远只反映本周目，不会带着上一周目的残留。
var _carry_marks: Dictionary = {}
## 通关时快照下来的继承数据：kind -> {name: value}
var _inherited: Dictionary = {}
var _dirty := false


func _ready() -> void:
	_load()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		save_now()


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

## 当前周目，从 1 开始
func get_cycle() -> int:
	return _cycle


## 二周目及以后
func is_ng_plus() -> bool:
	return _cycle >= 2


## 这一周目走完了、还没开新周目
func is_advance_pending() -> bool:
	return _advance_pending


func total_clears() -> int:
	return _total_clears


## 通关过几个**不同**的结局
func distinct_clears() -> int:
	return _clears.size()


func has_cleared(ending_id: String) -> bool:
	return _clears.has(ending_id)


func clear_count(ending_id: String) -> int:
	return int(_clears.get(ending_id, 0))


## 按首次抵达顺序列出通关记录：[{"id": ..., "count": ...}, ...]
func clear_summary() -> Array:
	var out: Array = []
	var seen := {}
	for raw in _clear_order:
		var id := String(raw)
		if seen.has(id):
			continue
		seen[id] = true
		out.append({"id": id, "count": clear_count(id)})
	# 兜底：万一有记录没进 _clear_order（手改过 json），也别让它消失
	for id in _clears.keys():
		if not seen.has(String(id)):
			out.append({"id": String(id), "count": clear_count(String(id))})
	return out


## 下一周目会继承哪些东西。空表示「还没通关过，或剧本没标记过 carry」
func inherited_summary() -> Dictionary:
	var out: Dictionary = {}
	for kind in CARRY_KINDS:
		var bucket: Variant = _inherited.get(kind, {})
		if typeof(bucket) == TYPE_DICTIONARY and not (bucket as Dictionary).is_empty():
			out[kind] = (bucket as Dictionary).duplicate()
	return out


func has_inherited() -> bool:
	return not _inherited.is_empty()


# ---------------------------------------------------------------------------
# 写
# ---------------------------------------------------------------------------

## 抵达一个结局。幂等性不适用 —— 同一个结局每抵达一次都算一次通关。
func record_ending(ending_id: String) -> void:
	if ending_id.is_empty():
		return
	_clears[ending_id] = clear_count(ending_id) + 1
	_total_clears += 1
	if not _clear_order.has(ending_id):
		_clear_order.append(ending_id)
	# 抵达结局 = 本周目走完了。下次「开始游戏」就该进下一周目。
	_advance_pending = true
	# 继承数据在**这一刻**取值：剧本写「carry affection alice」的语义是
	# 「带着这一周目结束时的好感度进下一周目」，所以快照放在这里而不是
	# 放在下一周目开局 —— 那时 GameManager 已经被 reset 成空的了。
	_snapshot_carry()
	_dirty = true
	save_now()
	ending_recorded.emit(ending_id, clear_count(ending_id))


## 开一次新游戏。main.gd 在 GameManager.reset_run() **之后**调用它。
##
## advance = true  （标题界面「开始游戏」）—— 若上一周目已通关，周目数 +1
## advance = false （章节选择 / 调试台直接跳章）—— 只沿用当前周目，不推进
##
## 返回推进后的周目数。
func begin_new_run(advance: bool = true) -> int:
	# 先清标记：本周目的 carry 由本周目的剧本重新声明。
	# 放在 _apply_inheritance() 之前也没关系，两者互不影响。
	_carry_marks.clear()
	var advanced := false
	if advance and _advance_pending:
		_set_cycle(_cycle + 1)
		_advance_pending = false
		advanced = true
	_apply_inheritance()
	_dirty = true
	save_now()
	if advanced:
		cycle_changed.emit(_cycle)
	return _cycle


## 剧本 `carry <类型> <名字>` 走到时调用 —— 只是「打个标记」，
## 真正取值发生在 record_ending()。这样作者把 carry 写在哪一行都不影响结果。
func mark_carry(kind: String, name: String) -> void:
	if name.is_empty() or not CARRY_KINDS.has(kind):
		return
	_carry_marks["%s:%s" % [kind, name]] = {"kind": kind, "name": name}


func carry_marks() -> Array:
	return _carry_marks.values()


func clear_carry_marks() -> void:
	_carry_marks.clear()


## 调试 / 测试用：直接把周目数拨到某个值（不触发继承）
func force_cycle(value: int) -> void:
	_set_cycle(maxi(1, value))
	_dirty = true
	save_now()


## 清空全部周目数据（调试台 / 测试用）。**会一并清掉继承数据。**
func reset_all() -> void:
	_cycle = 1
	_clears.clear()
	_clear_order.clear()
	_total_clears = 0
	_advance_pending = false
	_carry_marks.clear()
	_inherited.clear()
	_dirty = true
	save_now()
	cycle_changed.emit(_cycle)


# ---------------------------------------------------------------------------
# 序列化
# ---------------------------------------------------------------------------

## 完整状态（落盘 user://cycle.json；测试备份还原也用它）
func to_dict() -> Dictionary:
	return {
		"cycle": _cycle,
		"clears": _clears.duplicate(true),
		"clear_order": _clear_order.duplicate(),
		"total_clears": _total_clears,
		"advance_pending": _advance_pending,
		"inherited": _inherited.duplicate(true),
	}


func from_dict(data: Dictionary) -> void:
	_cycle = maxi(1, int(data.get("cycle", 1)))
	_clears.clear()
	var raw_clears: Variant = data.get("clears", {})
	if typeof(raw_clears) == TYPE_DICTIONARY:
		for key in (raw_clears as Dictionary).keys():
			_clears[String(key)] = int((raw_clears as Dictionary)[key])
	_clear_order.clear()
	for item in data.get("clear_order", []):
		_clear_order.append(String(item))
	_total_clears = int(data.get("total_clears", 0))
	_advance_pending = bool(data.get("advance_pending", false))
	_inherited.clear()
	var raw_inherited: Variant = data.get("inherited", {})
	if typeof(raw_inherited) == TYPE_DICTIONARY:
		for kind in (raw_inherited as Dictionary).keys():
			var bucket: Variant = (raw_inherited as Dictionary)[kind]
			if typeof(bucket) != TYPE_DICTIONARY:
				continue
			var copy: Dictionary = {}
			for name in (bucket as Dictionary).keys():
				copy[String(name)] = (bucket as Dictionary)[name]
			if not copy.is_empty():
				_inherited[String(kind)] = copy
	_carry_marks.clear()
	_dirty = true


## 存档里只带「当前周目」与「是否待进入下一周目」。
##
## 通关记录 / 继承数据**不进去**：它们和 CG 收藏、已读记录是同一类东西 ——
## 「这台机器上的长期记忆」，不该因为读了一份旧档就退回从前。
func to_save_dict() -> Dictionary:
	return {"cycle": _cycle, "advance_pending": _advance_pending}


func from_save_dict(data: Dictionary) -> void:
	if typeof(data) != TYPE_DICTIONARY or data.is_empty():
		return
	_cycle = maxi(1, int(data.get("cycle", _cycle)))
	_advance_pending = bool(data.get("advance_pending", _advance_pending))
	_dirty = true


func save_now() -> void:
	if not _dirty:
		return
	_dirty = false
	JsonUtil.save_json(SAVE_PATH, {
		"version": SAVE_VERSION,
		"cycle": _cycle,
		"clears": _clears,
		"clear_order": _clear_order,
		"total_clears": _total_clears,
		"advance_pending": _advance_pending,
		"inherited": _inherited,
	})


# ---------------------------------------------------------------------------
# 内部
# ---------------------------------------------------------------------------

func _set_cycle(value: int) -> void:
	_cycle = maxi(1, value)


func _bucket(kind: String) -> Dictionary:
	if not _inherited.has(kind):
		_inherited[kind] = {}
	return _inherited[kind]


## 把本周目标记过的状态取值快照下来。
##
## 两个刻意的取舍：
##
## 1. **本周目一个 carry 都没声明时，直接原样保留上一周目的继承数据。**
##    否则玩家在二周目走了一条没写 carry 的分支（比如直奔坏结局），
##    继承数据就被悄悄清空了 —— 而玩家完全看不出发生了什么。
##    「没声明」理解成「不改动」比理解成「清空」安全得多。
##
## 2. 只取「真的存在」的键：剧本写了 `carry flag 某个旗标`，但那一周目根本没走到
##    点亮它的地方 —— 这时不该凭空造一个 false 塞进下一周目，那会让
##    「有没有点亮过」这类判断在下周目开局就变成「明确没点亮」，
##    而不是「还没有这个旗标」。两者在 `if not flag x` 下行为一致，
##    但在 `if flag x` 之外（比如调试台列全部旗标）差别很明显。
func _snapshot_carry() -> void:
	if _carry_marks.is_empty():
		return
	_inherited.clear()
	for key in _carry_marks.keys():
		var mark: Dictionary = _carry_marks[key]
		var kind := String(mark["kind"])
		var name := String(mark["name"])
		match kind:
			CARRY_FLAG:
				if GameManager.has_flag(name):
					_bucket(kind)[name] = GameManager.get_flag(name)
			CARRY_VAR:
				if GameManager.vars.has(name):
					_bucket(kind)[name] = GameManager.vars[name]
			CARRY_AFFECTION:
				if GameManager.affection.has(name):
					_bucket(kind)[name] = GameManager.get_affection(name)


func _apply_inheritance() -> void:
	if _cycle < 2 or _inherited.is_empty():
		return
	var flags: Variant = _inherited.get(CARRY_FLAG, {})
	if typeof(flags) == TYPE_DICTIONARY:
		for name in (flags as Dictionary).keys():
			GameManager.set_flag(String(name), bool((flags as Dictionary)[name]))
	var vars: Variant = _inherited.get(CARRY_VAR, {})
	if typeof(vars) == TYPE_DICTIONARY:
		for name in (vars as Dictionary).keys():
			GameManager.set_var(String(name), (vars as Dictionary)[name])
	var affs: Variant = _inherited.get(CARRY_AFFECTION, {})
	if typeof(affs) == TYPE_DICTIONARY:
		for name in (affs as Dictionary).keys():
			GameManager.set_affection(String(name), float((affs as Dictionary)[name]))


func _load() -> void:
	# 先判存在 —— JsonUtil 读不到文件会打警告，首次运行时不该有噪音
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var raw: Variant = JsonUtil.load_json(SAVE_PATH)
	if typeof(raw) != TYPE_DICTIONARY:
		return
	from_dict(raw as Dictionary)
	_dirty = false
