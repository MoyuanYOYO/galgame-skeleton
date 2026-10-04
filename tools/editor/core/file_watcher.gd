extends RefCounted

## 文件变化监听（轮询式）
##
## 为什么是轮询：Godot **运行时没有内建的文件系统监听** ——
## `EditorFileSystem` 的 `filesystem_changed` 信号只在编辑器插件里可用，
## 运行中的工具进程拿不到 inotify / ReadDirectoryChangesW。
##
## 好在代价可以忽略：一次 `stat` 是系统调用，几百微秒；
## 500ms 一轮，人感知不到延迟，CPU 占用约等于零。
## 剧本才几 KB，检测到变化后读全文也无所谓。
##
## 变化判定用 mtime + size 双条件：只比 mtime 的话，
## 同一秒内的两次写入会漏掉；只比 size 的话，等长替换会漏掉。

## 轮询间隔（毫秒）
var poll_ms: int = 500

var _watched: Dictionary = {}      ## path → {"mtime": int, "size": int}
var _next_poll: int = 0


## 开始监听一个文件（记录当前指纹作为基线）
func watch(path: String) -> void:
	if path.is_empty():
		return
	_watched[path] = _fingerprint(path)


func unwatch(path: String) -> void:
	_watched.erase(path)


func clear() -> void:
	_watched.clear()


func is_watching(path: String) -> bool:
	return _watched.has(path)


## 强制刷新某个文件的基线（自己写盘之后调用，免得把自己的写入当成外部改动）
func resync(path: String) -> void:
	if _watched.has(path):
		_watched[path] = _fingerprint(path)


func watched_paths() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _watched.keys():
		out.append(String(k))
	return out


## 由调用方每帧驱动。返回**发生变化**的路径列表。
##
## 变化后会自动把基线更新为当前指纹 —— 所以同一个改动只会被报告一次，
## 不会因为调用方没处理而反复触发。
func poll(now_ms: int = -1) -> PackedStringArray:
	var now := now_ms if now_ms >= 0 else Time.get_ticks_msec()
	if now < _next_poll:
		return PackedStringArray()
	_next_poll = now + poll_ms

	var changed := PackedStringArray()
	for path in _watched.keys():
		var p := String(path)
		var current := _fingerprint(p)
		var previous: Dictionary = _watched[p]
		if int(current["mtime"]) != int(previous["mtime"]) \
				or int(current["size"]) != int(previous["size"]):
			changed.append(p)
			_watched[p] = current
	return changed


## 立即检查（不等轮询间隔）。用于「切换文件」「手动刷新」等场景。
func poll_now() -> PackedStringArray:
	_next_poll = 0
	return poll()


static func _fingerprint(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"mtime": -1, "size": -1}
	var f := FileAccess.open(path, FileAccess.READ)
	var size := -1
	if f != null:
		size = f.get_length()
		f.close()
	return {"mtime": FileAccess.get_modified_time(path), "size": size}
