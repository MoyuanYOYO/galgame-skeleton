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
	WAITING_VIDEO,
	ENDED,
}

## 重播片段播完时发出的 ending_id
const ENDING_REPLAY_DONE := "__replay_done__"

const STATE_NAMES: PackedStringArray = [
	"idle", "running", "waiting_say", "waiting_choice",
	"waiting_timer", "waiting_click", "waiting_minigame", "waiting_video", "ended",
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
## 调用栈。每帧是 `{ip: 返回地址, params: {名字: 值}, args: [位置参数…]}`。
##
## ⚠️ **曾经是「int 数组」**，改成字典是为了支持 `call <标签> 名=值`。
## 存档兼容靠 `restore_state()`：读到整数就当成「没有参数的旧帧」。
var _call_stack: Array = []
var _wait_end_ms: int = 0
var _pending_choice: Array = []
var _pending_minigame_id: String = ""
var _stop_ip: int = -1

## 演出指令里表示「要等多久」的键。`bgm` 用 `fade`，其余用 `duration`。
const DURATION_KEYS: PackedStringArray = ["duration", "fade"]


func _ready() -> void:
	set_process(false)


# ---------------------------------------------------------------------------
# 装载与启动
# ---------------------------------------------------------------------------

func load_script(path: String) -> bool:
	# 真正读文件时才解析语言子目录；_current_file 始终记**逻辑路径**，
	# 这样存档、章节匹配、路线图的比较都不会因为换语言而对不上。
	var actual := ScriptPaths.resolve(path)
	if not FileAccess.file_exists(actual):
		push_error("[GVS] 剧本文件不存在: %s" % path)
		parse_errors = ["剧本文件不存在: %s" % path]
		return false
	var file := FileAccess.open(actual, FileAccess.READ)
	if file == null:
		push_error("[GVS] 无法打开剧本: %s" % path)
		parse_errors = ["无法打开剧本: %s" % path]
		return false
	var text := file.get_as_text()
	file.close()
	return load_text(text, path)


## 从**内存里的文本**加载剧本。
##
## 编辑器预览必须走这条：`load_script` 是从磁盘读的，而编辑器是**手动保存**的，
## 手里可能有未保存改动 —— 按磁盘预览会「刚改的那句怎么没生效」，
## 更要命的是行号对不上，`start_at_line()` 会落到别处去。
## `path` 仍记逻辑路径（存档、章节匹配、跳转都用它）。
func load_text(text: String, path: String) -> bool:
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


## 从「源码第 line_no 行」对应的指令开始跑。
##
## 需要 `GvsParser` 给每条指令盖的 `line` 键。返回 false 表示这一行之后没有
## 可执行指令（注释 / 空行 / 文件末尾），调用方应当退回 `start(label)`。
##
## ⚠️ 命中点落在某个 `choice` 的**选项行**上时，从那条 `choice` 开始 ——
## 「从选项中间开始」没有意义，作者想看的是「这个选择点」。
func start_at_line(line_no: int) -> bool:
	if _commands.is_empty() or line_no <= 0:
		return false
	var idx := -1
	for i in _commands.size():
		var c: Dictionary = _commands[i]
		if String(c.get("op", "")) == "choice":
			for opt in c.get("options", []):
				if int((opt as Dictionary).get("line", -1)) == line_no:
					idx = i
					break
		if idx >= 0:
			break
		# 指令按源码顺序发出，所以「第一条 line >= line_no」就是命中点
		if int(c.get("line", -1)) >= line_no:
			idx = i
			break
	if idx < 0:
		return false
	_ip = idx
	_call_stack.clear()
	_stop_ip = -1
	_state = State.RUNNING
	_step()
	return true


## 剧情重播：只跑 [start_label, end_label) 这一段，跑到 end_label 就自动收尾。## 与 start() 的区别是带了「终点」，因此可以安全地重播某个场景而不冲进结局。
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


## 视频播完了（剧本写了 wait=true 时才会进入等待态）。
##
## 和 submit_minigame 同一个套路：阻塞型指令必须由外部显式放行，
## 否则调度器会一路冲过演出，把后面的对白提前弹出来。
func submit_video_finished() -> void:
	if _state != State.WAITING_VIDEO:
		return
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


func is_waiting_video() -> bool:
	return _state == State.WAITING_VIDEO


func is_blocked() -> bool:
	return _state in [
		State.WAITING_SAY, State.WAITING_CHOICE, State.WAITING_TIMER,
		State.WAITING_CLICK, State.WAITING_MINIGAME, State.WAITING_VIDEO,
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
		"call_stack": _call_stack.duplicate(true),
	}


func restore_state(data: Dictionary) -> bool:
	var path := String(data.get("file", ""))
	if path.is_empty() or not load_script(path):
		return false
	_ip = clampi(int(data.get("ip", 0)), 0, maxi(0, _commands.size() - 1))
	_call_stack.clear()
	for v in data.get("call_stack", []):
		# ⚠️ 兼容旧存档：`call` 带参数之前的帧只是一个整数（返回地址）。
		# 读到时补成「没有参数的帧」，否则旧档一读就崩。
		if typeof(v) == TYPE_DICTIONARY:
			_call_stack.append(v)
		elif typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			_call_stack.append({"ip": int(v), "params": {}, "args": []})
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
		"hop", "zoom", "shake", "screen_shake", "screen_flash", "screen_fx", "bg_motion", "weather":
			stage_command.emit(cmd)
		"anim":
			stage_command.emit(cmd)
		"video":
			# 播放的同时解锁收藏 —— 和 `cg` 指令一个道理：
			# 「到达了会播放这段影片的剧情点」就算解锁，素材缺失也照样解锁。
			CollectionManager.unlock("video", String(cmd.get("id", "")))
			# wait=true 表示「播完再继续」——先把状态置成等待，再发指令。
			# 顺序不能反：main.gd 是同步处理这条指令的，若它当场发现素材缺失
			# 会立刻回调 submit_video_finished()，那时状态还没置上的话就漏掉了，
			# 调度器会永远卡在等待态。
			if bool(cmd.get("wait", false)):
				_state = State.WAITING_VIDEO
			stage_command.emit(cmd)
		"hide_video":
			stage_command.emit(cmd)
		"cg":
			# 展示 CG 的同时把它计入收藏
			CollectionManager.unlock("cg", String(cmd.get("id", "")))
			stage_command.emit(cmd)
		"unlock":
			CollectionManager.unlock(String(cmd.get("type", "")), String(cmd.get("id", "")))
		"bgm", "se", "voice", "audio_fx":
			audio_command.emit(cmd)
		"set":
			GameManager.set_var(String(cmd["name"]), cmd.get("value"))
		"add":
			GameManager.add_var(String(cmd["name"]), float(cmd.get("amount", 0.0)))
		"flag":
			GameManager.set_flag(String(cmd["name"]), bool(cmd.get("value", true)))
		"affection":
			GameManager.add_affection(String(cmd["char"]), float(cmd.get("amount", 0.0)))
		"carry":
			# 只是打个「下周目要继承它」的标记，取值发生在抵达结局时
			CycleManager.mark_carry(String(cmd.get("kind", "")), String(cmd.get("name", "")))
		"jump":
			_ip = int(cmd["target"])
		"jump_file":
			_exec_jump_file(cmd)
		"call":
			# 参数随帧压栈 —— 作用域是局部的，`return` 时一并弹掉，
			# 所以嵌套调用里的同名参数不会互相串味。
			_call_stack.append({
				"ip": _ip,
				"params": cmd.get("params", {}),
				"args": cmd.get("args", []),
			})
			_ip = int(cmd["target"])
		"return":
			if _call_stack.is_empty():
				_end_script("", "")
			else:
				_ip = int((_call_stack.pop_back() as Dictionary).get("ip", 0))
		"branch_false":
			if not _evaluate(cmd.get("cond", {})):
				_ip = int(cmd["target"])
		"together":
			_exec_together(cmd)
		"choice":
			_exec_choice(cmd)
		"wait":
			_exec_wait(cmd)
		"wait_click":
			_state = State.WAITING_CLICK
		"minigame":
			_exec_minigame(cmd)
		"ending":
			_end_script(String(cmd.get("id", "")), _resolve_text(String(cmd.get("title", ""))))
		"chapter":
			GameManager.chapter_title = _resolve_text(String(cmd.get("title", "")))
		_:
			last_unknown_op = op
			push_warning("[GVS] 未知指令: %s" % op)


func _exec_say(cmd: Dictionary) -> void:
	var speaker := String(cmd.get("speaker", ""))
	# 插值在这里做（而不是在对话框里）：这样回看记录、存档预览、已读标记
	# 拿到的都是**替换后**的文本，不用各自再实现一遍。
	var text := _resolve_text(String(cmd.get("text", "")))
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


## 演出并行组：块内指令一起启动，然后等**最长的那条**跑完。
##
## 块内指令由解析器保证都是非阻塞的（`GvsParser.TOGETHER_ALLOWED`），
## 所以这里直接复用 `_execute` 分发，不用担心它把状态改成等待态。
##
## 等待时长 = 块内各指令 `duration` / `fade` 的最大值，
## 可用 `together duration=` 覆盖（`duration=0` = 只启动、不等）。
## 等待时长 = `together duration=`（若写了）；否则 = 块内各指令 `duration` / `fade`
## 的最大值。**`duration=0` 是「只启动、不等」**，所以解析器用 -1 表示「没写」，
## 这里必须区分这两者（都当 0 的话 `duration=0` 会变成「等最长的那条」，正好相反）。
func _exec_together(cmd: Dictionary) -> void:
	var explicit := float(cmd.get("duration", -1.0))
	var longest := maxf(0.0, explicit)
	for c in (cmd.get("body", []) as Array):
		var sub: Dictionary = c
		_execute(sub)
		if explicit < 0.0:
			longest = maxf(longest, _cmd_duration(sub))
	if longest <= 0.0:
		return
	_wait_end_ms = Time.get_ticks_msec() + int(longest * 1000.0)
	_state = State.WAITING_TIMER
	set_process(true)


## 一条演出指令「要跑多久」。取 `duration` 与 `fade` 里较大的那个 ——
## 解析器对这两个键的映射不统一（`bg` 把 `fade=` 存成 `duration`，
## 而 `bgm` 直接存 `fade`），这里两种都认，免得漏掉一条就等不到。
static func _cmd_duration(cmd: Dictionary) -> float:
	var best := 0.0
	for key in DURATION_KEYS:
		if cmd.has(key):
			best = maxf(best, float(cmd[key]))
	return best


## 台词 / 章节名 / 结局标题的插值入口。
##
## 查不到的名字**原样保留**（见 `GvsInterp`），不静默变空。
func _resolve_text(text: String) -> String:
	return GvsInterp.resolve(text, _lookup_interp)


## `{$名字}` 的取值顺序：命名空间（好感度 / 旗标）→ call 参数（内层优先）→ 剧本变量。
func _lookup_interp(name: String) -> Variant:
	if name.begins_with("affection."):
		var cid := name.substr("affection.".length())
		return GameManager.get_affection(cid) if not cid.is_empty() else null
	if name.begins_with("flag."):
		var fname := name.substr("flag.".length())
		return GameManager.get_flag(fname) if not fname.is_empty() else null
	# call 参数：从最内层往外找，内层同名参数遮蔽外层的
	for i in range(_call_stack.size() - 1, -1, -1):
		var frame: Dictionary = _call_stack[i]
		var params: Dictionary = frame.get("params", {})
		if params.has(name):
			return params[name]
		if name.is_valid_int():
			var args: Array = frame.get("args", [])
			var idx := name.to_int() - 1
			if idx >= 0 and idx < args.size():
				return args[idx]
	return GameManager.get_var(name, null)


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
		"cycle":
			# 当前周目数（1 起）。多周目剧本用它分岔：if cycle >= 2
			result = _compare(CycleManager.get_cycle(), String(cond.get("cmp", "==")), cond.get("value"))
		"cleared":
			# 某个结局通关过没有。注意这是**跨周目**的记录 ——
			# 二周目读它永远是 true，这正是 NG+ 剧本想要的语义。
			result = CycleManager.has_cleared(key)
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
