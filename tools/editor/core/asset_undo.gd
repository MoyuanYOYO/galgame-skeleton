extends RefCounted

## 素材操作的撤销栈
##
## 素材的重命名 / 删除**动的是文件系统**，而且顺手改了剧本引用 ——
## 这是编辑器里唯一会「弄丢东西」的操作（剧本编辑有 `ScriptDoc` 的快照栈兜底，
## 素材这边原来什么都没有，误删只能去回收站或 git 里捞）。
##
## 做法：每一步都记成「怎么反过来做」，撤销时**倒着**执行一遍。
## 三种可逆步骤：
##
##   move     A → B        撤销 = 把 B 挪回 A
##   content  P（旧字节）   撤销 = 把旧字节写回 P（父目录不存在就补出来）
##   dir      D            撤销 = 把 D 建回来（空目录也要能恢复）
##
## ⚠️ 「删除」和「改写」在撤销层是**同一件事**：都是「记下旧内容、撤销时写回」。
## 分成两种只会多一份要维护的代码。

## 最多记多少次操作。素材改动不会很频繁，30 步足够覆盖「手滑」这个场景。
const MAX_DEPTH := 30

var _stack: Array = []
var _pending: Dictionary = {}


## 开始记录一次操作（同一时刻只有一次在进行）
func begin(label: String) -> void:
	_pending = {"label": label, "steps": []}


func is_recording() -> bool:
	return not _pending.is_empty()


## 记一步「文件从 from 挪到了 to」
func record_move(from_path: String, to_path: String) -> void:
	_step({"kind": "move", "from": from_path, "to": to_path})


## 记一步「这个文件的内容即将被改写 / 删除」—— 先把当前字节存下来
func record_content(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	_step({"kind": "content", "path": path,
		"bytes": FileAccess.get_file_as_bytes(path)})


## 记一步「这个目录在操作前就存在」（撤销时建回来，空目录也能恢复）
func record_dir(path: String) -> void:
	_step({"kind": "dir", "path": path})


## 记下这一批文本文件的内容。
##
## **故意记多不记少**：剧本才几 KB，而漏记一个文件 = 撤销之后剧本引用还是断的，
## 那种「撤销了但没完全撤销」的状态比不能撤销更糟。
func record_texts(paths: PackedStringArray) -> void:
	for p in paths:
		record_content(String(p))


## 收尾：有步骤才入栈
func commit() -> void:
	if _pending.is_empty():
		return
	var steps: Array = _pending.get("steps", [])
	_pending = {}
	if steps.is_empty():
		return
	_stack.append({"label": _label_of(steps), "steps": steps})
	while _stack.size() > MAX_DEPTH:
		_stack.pop_front()


## 中途失败时放弃记录
func cancel() -> void:
	_pending = {}


func can_undo() -> bool:
	return not _stack.is_empty()


func peek_label() -> String:
	if _stack.is_empty():
		return ""
	return String((_stack.back() as Dictionary).get("label", ""))


## 撤销最近一次。返回被撤销的操作名；没有可撤销的返回空串。
func undo() -> String:
	if _stack.is_empty():
		return ""
	var entry: Dictionary = _stack.pop_back()
	var steps: Array = entry.get("steps", [])
	for i in range(steps.size() - 1, -1, -1):
		_undo_step(steps[i] as Dictionary)
	return String(entry.get("label", ""))


func clear() -> void:
	_stack.clear()
	_pending = {}


# ---------------------------------------------------------------------------

func _step(d: Dictionary) -> void:
	if _pending.is_empty():
		return
	(_pending["steps"] as Array).append(d)


## 操作名由步骤推出来，省得每个调用方自己写一遍
static func _label_of(steps: Array) -> String:
	var moves := 0
	var contents := 0
	for s in steps:
		match String((s as Dictionary).get("kind", "")):
			"move":
				moves += 1
			"content":
				contents += 1
	if moves > 0:
		var first: Dictionary = steps[0]
		if String(first.get("kind", "")) == "move":
			return "重命名 %s" % String(first.get("from", "")).get_file()
		return "文件改动（%d 个）" % moves
	if contents > 0:
		return "删除 / 改写（%d 个文件）" % contents
	return "素材操作"


static func _undo_step(s: Dictionary) -> void:
	var kind := String(s.get("kind", ""))
	match kind:
		"move":
			var from_path := String(s.get("from", ""))
			var to_path := String(s.get("to", ""))
			if from_path.is_empty() or to_path.is_empty():
				return
			var abs_from := ProjectSettings.globalize_path(from_path)
			var abs_to := ProjectSettings.globalize_path(to_path)
			# 目标父目录可能被一起删掉了，先补出来
			DirAccess.make_dir_recursive_absolute(abs_from.get_base_dir())
			DirAccess.rename_absolute(abs_to, abs_from)
		"content":
			var p := String(s.get("path", ""))
			if p.is_empty():
				return
			DirAccess.make_dir_recursive_absolute(
				ProjectSettings.globalize_path(p).get_base_dir())
			var f := FileAccess.open(p, FileAccess.WRITE)
			if f == null:
				return
			f.store_buffer(s.get("bytes", PackedByteArray()))
			f.close()
		"dir":
			var d := String(s.get("path", ""))
			if not d.is_empty():
				DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))
