class_name ScriptAudit
extends RefCounted

## 剧本静态校验 + 素材清单
##
## 两件事：
##   audit()  —— 查剧本自身的问题（解析错误、悬空跳转、未使用标签、重复结局 id…）
##   assets() —— 列出剧本引用的全部素材 id，标出哪些还没有真实文件
##
## 纯静态，不依赖运行时状态，所以既能挂到调试控制台，也能直接跑成 CI 检查。

const ASSET_DIRS := {
	"bg": "res://assets/bg/",
	"cg": "res://assets/cg/",
	"char": "res://assets/sprites/",
	"se": "res://assets/audio/se/",
	"bgm": "res://assets/audio/bgm/",
	"voice": "res://assets/audio/voice/",
	"video": "res://assets/video/",
}
const AUDIO_EXT: PackedStringArray = ["ogg", "mp3", "wav"]
const IMAGE_EXT: PackedStringArray = ["png", "jpg", "jpeg", "webp"]
## Godot 内置只认 Ogg Theora。这里刻意不引用 VideoScreen —— core 层不许
## 碰表现层的类（架构守卫会拦），所以后缀表在两边各留一份。
const VIDEO_EXT: PackedStringArray = ["ogv"]

## 这些标签是被跳转进来的入口，没人 jump 到它们也不算「未使用」
const ENTRY_LABELS: PackedStringArray = ["start"]


# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------

## 返回 {"errors": [...], "warnings": [...], "files": int, "commands": int}
static func audit() -> Dictionary:
	var errors: Array = []
	var warnings: Array = []
	var total_commands := 0
	var files := ScriptStats.script_files()

	var ending_owner := {}
	var all_labels := {}        # 文件 -> {标签: true}
	var referenced := {}        # 文件 -> {标签: true}（被 jump/call/choice 指向的）
	var referenced_files := {}
	var set_flags := {}         # 剧本里所有被 flag 指令置位过的旗标名

	# 重播片段的起止标签也是「入口」—— 它们由 cg.json 的 replay 字段引用，
	# 剧本里没人跳转过去，但绝不是死代码
	for type in ["cg", "music"]:
		for entry in CollectionRegistry.get_items(type):
			var replay: Variant = (entry as Dictionary).get("replay", {})
			if typeof(replay) != TYPE_DICTIONARY:
				continue
			var replay_file := String((replay as Dictionary).get("file", "")).get_file()
			if replay_file.is_empty():
				continue
			if not referenced.has(replay_file):
				referenced[replay_file] = {}
			for key in ["label", "end_label"]:
				var name := String((replay as Dictionary).get(key, ""))
				if not name.is_empty():
					(referenced[replay_file] as Dictionary)[name] = true

	# 章节入口标签同理 —— 由 chapters.json 引用
	for entry in ScriptStats.chapters():
		var chapter: Dictionary = entry
		var chapter_file := String(chapter.get("file", "")).get_file()
		var chapter_label := String(chapter.get("label", ""))
		if chapter_file.is_empty() or chapter_label.is_empty():
			continue
		if not referenced.has(chapter_file):
			referenced[chapter_file] = {}
		(referenced[chapter_file] as Dictionary)[chapter_label] = true

	for path in files:
		var file_name := path.get_file()
		var text := _read(path)
		if text.is_empty():
			errors.append("%s：读不到内容" % file_name)
			continue

		var result := GvsParser.parse(text, file_name)
		for e in result.get("errors", []):
			errors.append("%s：%s" % [file_name, String(e)])

		var commands: Array = result.get("commands", [])
		total_commands += commands.size()

		var labels: Dictionary = result.get("labels", {})
		var label_set := {}
		for name in labels.keys():
			label_set[String(name)] = true
		all_labels[file_name] = label_set
		if not referenced.has(file_name):
			referenced[file_name] = {}

		for c in commands:
			var cmd: Dictionary = c
			var op := String(cmd.get("op", ""))
			match op:
				"jump", "goto", "call":
					(referenced[file_name] as Dictionary)[String(cmd.get("label", ""))] = true
				"jump_file":
					# jump_file 写的是完整 res:// 路径，统一取文件名再比
					referenced_files[String(cmd.get("file", "")).get_file()] = true
				"choice":
					var opts: Array = cmd.get("options", [])
					if opts.is_empty():
						errors.append("%s：有个 choice 块一个选项都没有" % file_name)
					for opt in opts:
						var target_label := String((opt as Dictionary).get("label", ""))
						if not target_label.is_empty():
							(referenced[file_name] as Dictionary)[target_label] = true
				"ending":
					var id := String(cmd.get("id", ""))
					if ending_owner.has(id):
						errors.append("结局 id 重复：%s（%s 与 %s）"
							% [id, ending_owner[id], file_name])
					else:
						ending_owner[id] = file_name
					if not CollectionRegistry.has_item("endings", id):
						warnings.append("结局 %s 没登记进 endings.json，玩家看不到它" % id)
				"flag":
					set_flags[String(cmd.get("name", ""))] = true
				"say":
					if String(cmd.get("text", "")).strip_edges().is_empty():
						warnings.append("%s：有一句空台词" % file_name)

	# 章节声明了 unlock_flag，却没有任何 flag 指令会设置它 —— 那一章永远选不了。
	# 和「解析器认识、调度器不转发」是同一类问题：配置写好了，但没人执行。
	for entry in ScriptStats.chapters():
		var unlock_flag := String((entry as Dictionary).get("unlock_flag", ""))
		if unlock_flag.is_empty() or set_flags.has(unlock_flag):
			continue
		warnings.append("章节「%s」的 unlock_flag %s 没有任何 flag 指令会设置它，这一章永远解锁不了"
			% [String((entry as Dictionary).get("title", "")), unlock_flag])

	# 跳转目标文件是否存在
	for file_name in referenced_files.keys():
		var found := false
		for path in files:
			if path.get_file() == String(file_name):
				found = true
				break
		if not found:
			errors.append("跳转到了不存在的剧本文件：%s" % file_name)

	# 未使用的标签
	for file_name in all_labels.keys():
		var used: Dictionary = referenced.get(file_name, {})
		for label in (all_labels[file_name] as Dictionary).keys():
			var name := String(label)
			if ENTRY_LABELS.has(name) or used.has(name):
				continue
			warnings.append("%s：标签 %s 没人跳转过来（死代码？）" % [file_name, name])

	return {
		"errors": errors,
		"warnings": warnings,
		"files": files.size(),
		"commands": total_commands,
	}


# ---------------------------------------------------------------------------
# 素材清单
# ---------------------------------------------------------------------------

## 返回 {"bg": {"id": true/false, ...}, ...}，值表示「有没有真实文件」
static func assets() -> Dictionary:
	var used := {}
	for path in ScriptStats.script_files():
		var text := _read(path)
		if text.is_empty():
			continue
		var result := GvsParser.parse(text, path.get_file())
		for c in result.get("commands", []):
			_collect_assets(c as Dictionary, used)

	var out := {}
	for kind in used.keys():
		var table := {}
		for id in (used[kind] as Dictionary).keys():
			table[String(id)] = has_real_asset(String(kind), String(id))
		out[kind] = table
	return out


## 某个素材 id 在 assets/ 下有没有真实文件
static func has_real_asset(kind: String, id: String) -> bool:
	var dir := String(ASSET_DIRS.get(kind, ""))
	if dir.is_empty() or id.is_empty():
		return false
	# 立绘支持 <角色>/<表情> 的差分目录
	if kind == "char":
		if _exists_any(dir + id):
			return true
		var sub := DirAccess.open(dir + id + "/")
		return sub != null
	if kind == "video":
		for ext in VIDEO_EXT:
			if ResourceLoader.exists("%s%s.%s" % [dir, id, ext]):
				return true
		return false
	return _exists_any(dir + id)


## 缺哪些素材。返回 {"bg": ["classroom", ...], ...} —— 只列缺的。
static func missing_assets() -> Dictionary:
	var out := {}
	for kind in assets().keys():
		var missing: Array = []
		for id in (assets()[kind] as Dictionary).keys():
			if not bool((assets()[kind] as Dictionary)[id]):
				missing.append(String(id))
		if not missing.is_empty():
			out[kind] = missing
	return out


static func _collect_assets(cmd: Dictionary, used: Dictionary) -> void:
	var op := String(cmd.get("op", ""))
	match op:
		"bg":
			_add(used, "bg", String(cmd.get("id", "")))
		"cg":
			_add(used, "cg", String(cmd.get("id", "")))
		"video":
			_add(used, "video", String(cmd.get("id", "")))
		"show", "hide", "move", "expr", "hop", "zoom", "shake":
			_add(used, "char", String(cmd.get("char", "")))
		"se":
			_add(used, "se", String(cmd.get("id", "")))
		"bgm":
			var bgm := String(cmd.get("id", ""))
			if bgm != "stop":
				_add(used, "bgm", bgm)
		"voice":
			_add(used, "voice", String(cmd.get("id", "")))
		"unlock":
			# unlock cg xxx / unlock music xxx —— 这里只关心 cg
			if String(cmd.get("type", "")) == "cg":
				_add(used, "cg", String(cmd.get("id", "")))


static func _add(used: Dictionary, kind: String, id: String) -> void:
	if id.is_empty():
		return
	if not used.has(kind):
		used[kind] = {}
	(used[kind] as Dictionary)[id] = true


static func _exists_any(base: String) -> bool:
	for ext in IMAGE_EXT:
		if ResourceLoader.exists("%s.%s" % [base, ext]):
			return true
	for ext in AUDIO_EXT:
		if ResourceLoader.exists("%s.%s" % [base, ext]):
			return true
	return false


static func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text
