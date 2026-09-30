extends Node

## 游戏状态管理器（Autoload）
##
## 保存一次「游玩进度」中所有跨场景的软状态：旗标、好感度、剧本变量。
## 它与 ScriptRunner 的指令指针一起构成一个完整存档。

signal flags_changed()
signal affection_changed(char_id: String, value: float)
signal vars_changed()

const AFFECTION_MIN := -100.0
const AFFECTION_MAX := 100.0

var flags: Dictionary = {}
var affection: Dictionary = {}
var vars: Dictionary = {}
var play_time: float = 0.0
var chapter_title: String = ""
var tracking: bool = false


func _process(delta: float) -> void:
	if tracking:
		play_time += delta


# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------

func reset_run() -> void:
	flags.clear()
	affection.clear()
	vars.clear()
	play_time = 0.0
	chapter_title = ""
	flags_changed.emit()
	affection_changed.emit("", 0.0)
	vars_changed.emit()


# ---------------------------------------------------------------------------
# 旗标
# ---------------------------------------------------------------------------

func set_flag(flag_name: String, value: bool = true) -> void:
	if flags.get(flag_name, null) == value:
		return
	flags[flag_name] = value
	flags_changed.emit()


func get_flag(flag_name: String) -> bool:
	return bool(flags.get(flag_name, false))


func has_flag(flag_name: String) -> bool:
	return flags.has(flag_name)


# ---------------------------------------------------------------------------
# 好感度
# ---------------------------------------------------------------------------

func set_affection(char_id: String, value: float) -> void:
	var clamped := clampf(value, AFFECTION_MIN, AFFECTION_MAX)
	affection[char_id] = clamped
	affection_changed.emit(char_id, clamped)


func add_affection(char_id: String, amount: float) -> void:
	var current := get_affection(char_id)
	set_affection(char_id, current + amount)


func get_affection(char_id: String) -> float:
	return float(affection.get(char_id, 0.0))


# ---------------------------------------------------------------------------
# 变量
# ---------------------------------------------------------------------------

func set_var(var_name: String, value: Variant) -> void:
	vars[var_name] = value
	vars_changed.emit()


func add_var(var_name: String, amount: float) -> void:
	var current := float(vars.get(var_name, 0.0))
	vars[var_name] = current + amount
	vars_changed.emit()


func get_var(var_name: String, default_value: Variant = null) -> Variant:
	return vars.get(var_name, default_value)


# ---------------------------------------------------------------------------
# 序列化
# ---------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"flags": flags.duplicate(true),
		"affection": affection.duplicate(true),
		"vars": vars.duplicate(true),
		"play_time": play_time,
		"chapter_title": chapter_title,
	}


## 全部好感度（调试控制台用）
func get_all_affections() -> Dictionary:
	return affection.duplicate()


## 全部旗标（调试控制台用）
func get_all_flags() -> Dictionary:
	return flags.duplicate()


func from_dict(data: Dictionary) -> void:
	flags = _normalize_dict(data.get("flags", {}))
	affection = _normalize_dict(data.get("affection", {}))
	vars = _normalize_dict(data.get("vars", {}))
	play_time = float(data.get("play_time", 0.0))
	chapter_title = String(data.get("chapter_title", ""))
	flags_changed.emit()
	affection_changed.emit("", 0.0)
	vars_changed.emit()


## JSON 会把所有整数读回成 float，这里还原成 int 以免界面显示 "2.0"
static func _normalize_dict(src: Variant) -> Dictionary:
	var out: Dictionary = {}
	if typeof(src) != TYPE_DICTIONARY:
		return out
	for key in (src as Dictionary).keys():
		out[String(key)] = _normalize_value((src as Dictionary)[key])
	return out


static func _normalize_value(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var f := float(v)
			if is_equal_approx(f, roundf(f)):
				return int(f)
			return f
		TYPE_DICTIONARY:
			return _normalize_dict(v)
		TYPE_ARRAY:
			var arr: Array = []
			for item in (v as Array):
				arr.append(_normalize_value(item))
			return arr
	return v
