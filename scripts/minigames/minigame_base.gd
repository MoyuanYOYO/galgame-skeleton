class_name MinigameBase
extends Control

## 小游戏基类
##
## 契约：继承本类 + 结束时调用 finish(result) —— 就这两条。
## 剧本里写 `minigame <id>` 即可挂载，主流程通过 minigame_finished
## 信号拿到结果，完全不需要知道小游戏内部怎么实现。
##
## result 约定字段：
##   success (bool)  —— 是否达成目标，剧本可用 flag <id>_cleared 判定
##   score   (int)   —— 得分，写入变量 minigame_score
##   max     (int)   —— 满分，写入变量 minigame_max
##   need    (int)   —— 达标线（可选）
##
## 子类覆写 _on_setup() / _on_start() 即可。

signal minigame_finished(result: Dictionary)

var params: Dictionary = {}
var _started: bool = false


func setup(p: Dictionary) -> void:
	params = p
	_on_setup()


func start() -> void:
	if _started:
		return
	_started = true
	_on_start()


func finish(result: Dictionary) -> void:
	if not result.has("success"):
		result["success"] = false
	if not result.has("score"):
		result["score"] = 0
	if not result.has("max"):
		result["max"] = 0
	minigame_finished.emit(result)


# ---------------------------------------------------------------------------
# 参数读取（带默认值，剧本里可以只写关心的那几个）
# ---------------------------------------------------------------------------

func param_int(key: String, fallback: int) -> int:
	if not params.has(key):
		return fallback
	return int(params[key])


func param_float(key: String, fallback: float) -> float:
	if not params.has(key):
		return fallback
	return float(params[key])


func param_string(key: String, fallback: String) -> String:
	if not params.has(key):
		return fallback
	return String(params[key])


func param_bool(key: String, fallback: bool) -> bool:
	if not params.has(key):
		return fallback
	return bool(params[key])


# ---------------------------------------------------------------------------
# 子类覆写点
# ---------------------------------------------------------------------------

func _on_setup() -> void:
	pass


func _on_start() -> void:
	pass
