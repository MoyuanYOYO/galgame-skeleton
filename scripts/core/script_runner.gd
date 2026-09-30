class_name ScriptRunner
extends Node

## 剧本调度器
##
## 执行 GvsParser 编译出来的扁平指令流。它本身不碰任何界面 ——
## 所有需要「演出来」的指令都通过信号抛出，由 main.gd 转发给
## Stage（演出层）和 UI 层。这样调度器可以脱离界面单独做单元测试。
##
## 阻塞型指令（say / choice / wait / wait_click / minigame）会让调度器
## 进入等待态，必须由外部调用 advance() / submit_choice() /
## submit_minigame() 才会继续。

signal stage_command(cmd: Dictionary)
signal audio_command(cmd: Dictionary)
signal say(speaker: String, text: String, expr: String)
signal choices(options: Array)
signal choice_made(index: int, text: String)
signal minigame_requested(id: String, params: Dictionary)
signal line_logged(speaker: String, text: String)
signal script_ended(ending_id: String, title: String)

enum State {
	IDLE,
	RUNNING,
	WAITING_SAY,
	WAITING_CHOICE,
	WAITING_TIMER,
	WAITING_CLICK,
	WAITING_MINIGAME,
	ENDED,
}

## 重播片段播完时发出的 ending_id
const ENDING_REPLAY_DONE := "__replay_done__"

const STATE_NAMES: PackedStringArray = [
	"idle", "running", "waiting_say", "waiting_choice",
	"waiting_timer", "waiting_click", "waiting_minigame", "ended",
]

var parse_errors: Array = []

## 最近一次落进「未知指令」分支的 op 名，空串表示全部指令都被处理过。
##
## 存在意义：解析器认识、但调度器没实现转发的指令既不报错也没有效果，
## 是最难发现的一类 bug（玩家只会觉得「这句演出怎么没了」）。
## 有了这个字段，测试就能把「静默失效」变成可断言的事实。
var last_unknown_op: String = ""

var _commands: Array = []
var _labels: Dictionary = {}
var _current_file: String = ""
var _ip: int = 0
var _state: int = State.IDLE
var _call_stack: Array = []
var _wait_end_ms: int = 0
var _pending_choice: Array = []
var _pending_minigame_id: String = ""
var _stop_ip: int = -1


func _ready() -> void:
	set_process(false)


# ---------------------------------------------------------------------------
# 装载与启动
# ---------------------------------------------------------------------------

func load_script(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_error("[GVS] 剧本文件不存在: %s" % path)
		parse_errors = ["剧本文件不存在: %s" % path]
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[GVS] 无法打开剧本: %s" % path)
		parse_errors = ["无法打开剧本: %s" % path]
		return false
	var text := file.get_as_text()
	file.close()

	var result := GvsParser.parse(text, path.get_file())
	if not bool(result[GvsParser.KEY_OK]):
		parse_errors = result[GvsParser.KEY_ERRORS]
		for e in parse_errors:
			push_error("[GVS] %s" % e)
		return false

	parse_errors = []
	_commands = result[GvsParser.KEY_COMMANDS]
	_labels = result[GvsParser.KEY_LABELS]
	_current_file = path
	_ip = 0
	_call_stack.clear()
	_stop_ip = -1
	_state = State.IDLE
	return true


## 当前所在的标签名 —— 位置不超过 _ip 的、最近的那个标签。
##
## 标签在编译结果里不是指令，只是「名字 → 指令下标」的映射，
## 所以只能这样反查。调试控制台和路线图都要用它。
func get_current_label() -> String:
	var best := ""
	var best_index := -1
	for name in _labels.keys():
		var idx := int(_labels[name])
		if idx <= _ip and idx > best_index:
			best_index = idx
			best = String(name)
	return best


func start(label: String = "") -> void:
	if _commands.is_empty():
		push_error("[GVS] 没有已加载的剧本，先调用 load_script()")
		return
	if label.is_empty():
		_ip = 0
	elif _labels.has(label):
		_ip = int(_labels[label])
	else:
		push_error("[GVS] 找不到起始标签: %s" % label)
		return
	_call_stack.clear()
	_stop_ip = -1
	_state = State.RUNNING
	_step()


## 剧情重播：只跑 [start_label, end_label) 这一段，跑到 end_label 就自动收尾。
## 与 start() 的区别是带了「终点」，因此可以安全地重播某个场景而不冲进结局。
func start_replay(file: String, start_label: String, end_label: String) -> bool:
	if start_label.is_empty() or not load_script(file):
		return false
	if not _labels.has(start_label):
		push_error("[GVS] 重播起始标签不存在: %s" % start_label)
		return false
	_stop_ip = int(_labels[end_label]) if _labels.has(end_label) else -1
	_ip = int(_labels[start_label])
	_call_stack.clear()
	_state = State.RUNNING
	_step()
	return true


func is_replaying() -> bool:
	return _stop_ip >= 0


func stop() -> void:
	_state = State.IDLE
	_stop_ip = -1
	set_process(false)


# ---------------------------------------------------------------------------
# 外部驱动接口
# ---------------------------------------------------------------------------

## 玩家点击推进对白（或结束 wait_click）
func advance() -> void:
	if _state == State.WAITING_SAY or _state == State.WAITING_CLICK:
		_state = State.RUNNING
		_step()


func submit_choice(index: int) -> void:
	if _state != State.WAITING_CHOICE:
		return
	if index < 0 or index >= _pending_choice.size():
		push_warning("[GVS] 选项下标越界: %d" % index)
		return
	var picked: Dictionary = _pending_choice[index]
	choice_made.emit(index, String(picked["text"]))
	_ip = int(picked["target"])
	_pending_choice = []
	_state = State.RUNNING
	_step()


func submit_minigame(result: Dictionary) -> void:
	if _state != State.WAITING_MINIGAME:
		return
	var success := bool(result.get("success", false))
	GameManager.set_var("minigame_id", _pending_minigame_id)
	GameManager.set_var("minigame_success", success)
	GameManager.set_var("minigame_score", int(result.get("score", 0)))
	GameManager.set_var("minigame_max", int(result.get("max", 0)))
	if success:
		GameManager.set_flag("%s_cleared" % _pending_minigame_id)
	_state = State.RUNNING
	_step()


# ---------------------------------------------------------------------------
# 状态查询
# ---------------------------------------------------------------------------

func is_waiting_say() -> bool:
	return _state == State.WAITING_SAY


func is_waiting_click() -> bool:
	return _state == State.WAITING_CLICK


func is_waiting_choice() -> bool:
	return _state == State.WAITING_CHOICE


func is_waiting_minigame() -> bool:
	return _state == State.WAITING_MINIGAME


func is_blocked() -> bool:
	return _state in [
		State.WAITING_SAY, State.WAITING_CHOICE, State.WAITING_TIMER,
		State.WAITING_CLICK, State.WAITING_MINIGAME,
	]


func is_ended() -> bool:
	return _state == State.ENDED


func get_state_name() -> String:
	if _state >= 0 and _state < STATE_NAMES.size():
		return STATE_NAMES[_state]
	return "unknown"


func get_current_file() -> String:
	return _current_file


## 当前剧本里有没有这个标签（调试控制台用）
func has_label(label: String) -> bool:
	return _labels.has(label)


## 直接跳到某个标签，不经过剧本控制流（调试控制台用）。
## 会清掉等待态 —— 否则跳完还停在「等玩家点击」上。
func jump_to_label(label: String) -> bool:
	if not _labels.has(label):
		return false
	_ip = int(_labels[label])
	_state = State.RUNNING
	_pending_choice = []
	_wait_end_ms = 0
	return true


# ---------------------------------------------------------------------------
# 存档支持
# ---------------------------------------------------------------------------

func get_state() -> Dictionary:
	var ip := _ip
	# 处于阻塞态时，指针已经越过当前指令 —— 回退一格，
	# 读档后重新执行该条指令即可复现当时的画面。
	if is_blocked():
		ip = maxi(0, _ip - 1)
	return {
		"file": _current_file,
		"ip": ip,
		"call_stack": _call_stack.duplicate(),
	}


func restore_state(data: Dictionary) -> bool:
	var path := String(data.get("file", ""))
	if path.is_empty() or not load_script(path):
		return false
	_ip = clampi(int(data.get("ip", 0)), 0, maxi(0, _commands.size() - 1))
	_call_stack.clear()
	for v in data.get("call_stack", []):
		_call_stack.append(int(v))
	_state = State.RUNNING
	_step()
	return true


# ---------------------------------------------------------------------------
# 执行核心
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _state == State.WAITING_TIMER and Time.get_ticks_msec() >= _wait_end_ms:
		set_process(false)
		_state = State.RUNNING
		_step()


func _step() -> void:
	while _state == State.RUNNING:
		# 重播模式：跑到终点标签就收尾，不会继续冲进后面的剧情。
		# 必须加 _call_stack.is_empty() 守卫 —— 片段里可能 call 一个定义在
		# 终点之后的子过程，那时 _ip 会跳到终点之后，若不排除就会被误判成
		# 「已播完」而提前结束。
		if _stop_ip >= 0 and _call_stack.is_empty() and _ip >= _stop_ip:
			_stop_ip = -1
			_end_script(ENDING_REPLAY_DONE, "")
			return
		if _ip < 0 or _ip >= _commands.size():
			_end_script("", "")
			return
		var cmd: Dictionary = _commands[_ip]
		_ip += 1
		_execute(cmd)


func _execute(cmd: Dictionary) -> void:
	var op := String(cmd.get("op", ""))
	match op:
		"label":
			pass
		"say":
			_exec_say(cmd)
		# 舞台指令。加新指令时要同步三处：GvsParser.KEYWORDS、这里的转发分支、
		# main.gd 的 _on_stage_command。少改任何一处，指令都会「解析成功但没人执行」——
		# 只留一条 warning，玩家完全看不出问题。smoke 第 18 节专门守这个。
		"bg", "show", "hide", "move", "expr", "clear", "hide_cg":
			stage_command.emit(cmd)
		"hop", "zoom", "shake", "screen_shake", "screen_flash", "bg_motion", "weather":
			stage_command.emit(cmd)
		"cg":
			# 展示 CG 的同时把它计入收藏
			CollectionManager.unlock("cg", String(cmd.get("id", "")))
			stage_command.emit(cmd)
		"unlock":
			CollectionManager.unlock(String(cmd.get("type", "")), String(cmd.get("id", "")))
		"bgm", "se", "voice":
			audio_command.emit(cmd)
		"set":
			GameManager.set_var(String(cmd["name"]), cmd.get("value"))
		"add":
			GameManager.add_var(String(cmd["name"]), float(cmd.get("amount", 0.0)))
		"flag":
			GameManager.set_flag(String(cmd["name"]), bool(cmd.get("value", true)))
		"affection":
			GameManager.add_affection(String(cmd["char"]), float(cmd.get("amount", 0.0)))
		"jump":
			_ip = int(cmd["target"])
		"jump_file":
			_exec_jump_file(cmd)
		"call":
			_call_stack.append(_ip)
			_ip = int(cmd["target"])
		"return":
			if _call_stack.is_empty():
				_end_script("", "")
			else:
				_ip = int(_call_stack.pop_back())
		"branch_false":
			if not _evaluate(cmd.get("cond", {})):
				_ip = int(cmd["target"])
		"choice":
			_exec_choice(cmd)
		"wait":
			_exec_wait(cmd)
		"wait_click":
			_state = State.WAITING_CLICK
		"minigame":
			_exec_minigame(cmd)
		"ending":
			_end_script(String(cmd.get("id", "")), String(cmd.get("title", "")))
		"chapter":
			GameManager.chapter_title = String(cmd.get("title", ""))
		_:
			last_unknown_op = op
			push_warning("[GVS] 未知指令: %s" % op)


func _exec_say(cmd: Dictionary) -> void:
	var speaker := String(cmd.get("speaker", ""))
	var text := String(cmd.get("text", ""))
	var expr := String(cmd.get("expr", ""))
	if not expr.is_empty() and not speaker.is_empty():
		stage_command.emit({"op": "expr", "char": speaker, "expr": expr})
	# 状态必须在发信号「之前」落定：订阅者（main.gd）会在 say 的回调里
	# 查询 is_waiting_say() 来决定要不要武装自动播放定时器。如果先 emit
	# 再改状态，回调看到的就是 RUNNING，自动播放会永远不再武装 —— 表现为
	# 「只能推进一句就卡住」。
	_state = State.WAITING_SAY
	line_logged.emit(speaker, text)
	say.emit(speaker, text, expr)


func _exec_choice(cmd: Dictionary) -> void:
	var raw: Array = cmd.get("options", [])
	var options: Array = []
	for o in raw:
		options.append({"text": String(o.get("text", ""))})
	_pending_choice = raw
	_state = State.WAITING_CHOICE
	choices.emit(options)


func _exec_wait(cmd: Dictionary) -> void:
	var seconds := maxf(0.0, float(cmd.get("duration", 0.0)))
	_wait_end_ms = Time.get_ticks_msec() + int(seconds * 1000.0)
	_state = State.WAITING_TIMER
	set_process(true)


func _exec_minigame(cmd: Dictionary) -> void:
	_pending_minigame_id = String(cmd.get("id", ""))
	_state = State.WAITING_MINIGAME
	minigame_requested.emit(_pending_minigame_id, cmd.get("params", {}))


## 切换到另一个剧本文件。注意 load_script() 会把 _state 重置为 IDLE，
## 所以这里必须手动恢复 RUNNING —— 外层的 _step() 循环才能继续跑新剧本。
func _exec_jump_file(cmd: Dictionary) -> void:
	var path := String(cmd.get("file", ""))
	var label := String(cmd.get("label", ""))
	if not load_script(path):
		push_error("[GVS] 无法跳转到剧本: %s" % path)
		_end_script("", "")
		return
	_ip = int(_labels[label]) if _labels.has(label) else 0
	_call_stack.clear()
	_state = State.RUNNING


func _end_script(ending_id: String, title: String) -> void:
	_state = State.ENDED
	script_ended.emit(ending_id, title)


# ---------------------------------------------------------------------------
# 条件求值
# ---------------------------------------------------------------------------

func _evaluate(cond: Dictionary) -> bool:
	var kind := String(cond.get("kind", "flag"))
	var key := String(cond.get("name", ""))
	var result := false
	match kind:
		"flag":
			result = GameManager.get_flag(key)
		"affection":
			result = _compare(GameManager.get_affection(key), String(cond.get("cmp", "==")), cond.get("value"))
		"var":
			result = _compare(GameManager.get_var(key, null), String(cond.get("cmp", "==")), cond.get("value"))
	if bool(cond.get("negate", false)):
		return not result
	return result


static func _compare(lhs: Variant, op: String, rhs: Variant) -> bool:
	var a: Variant = _as_number(lhs)
	var b: Variant = _as_number(rhs)
	if a != null and b != null:
		return _cmp_float(float(a), float(b), op)
	return _cmp_string(str(lhs), str(rhs), op)


static func _as_number(v: Variant) -> Variant:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_BOOL:
			return 1.0 if bool(v) else 0.0
		TYPE_STRING:
			var s := String(v)
			if s.is_valid_float():
				return s.to_float()
	return null


static func _cmp_float(a: float, b: float, op: String) -> bool:
	match op:
		"==": return is_equal_approx(a, b)
		"!=": return not is_equal_approx(a, b)
		">": return a > b
		"<": return a < b
		">=": return a >= b
		"<=": return a <= b
	return false


static func _cmp_string(a: String, b: String, op: String) -> bool:
	match op:
		"==": return a == b
		"!=": return a != b
		">": return a > b
		"<": return a < b
		">=": return a >= b
		"<=": return a <= b
	return false
