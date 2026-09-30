class_name ScriptStats
extends RefCounted

## 剧本统计（只读，带缓存）
##
## 扫一遍 data/scripts/ 下所有剧本，得出：
##   line_count —— 总台词数（算已读率的分母）
##   choices    —— 每个选项点：所在标签 + 选项文本
##   files      —— 剧本文件清单
##
## 章节表单独从 chapters.json 读 —— 「哪一章从哪个标签开始」是人工排的，
## 从剧本里推不出来（一个文件可以包含好几章）。
##
## 文件位置与语言子目录的解析全部交给 ScriptPaths，这里不再自己拼路径。

static var _stats: Dictionary = {}


static func get_stats() -> Dictionary:
	if _stats.is_empty():
		_stats = _collect()
	return _stats


static func total_lines() -> int:
	return int(get_stats().get("line_count", 0))


## 剧本里每一条台词的原文，按出现次序、**不去重** —— 与 total_lines() 完全同口径。
##
## 算「已读率」必须用它，而不是 ReadTracker.read_count()：后者是**全局**去重计数
## （跨存档、跨剧本版本，连测试里随手标的句子也算），和「当前剧本有多少句」
## 不是同一个统计范围，直接相除会显示出「已读 150 / 62 句」。
static func line_texts() -> PackedStringArray:
	return get_stats().get("lines", PackedStringArray())


static func choices() -> Array:
	return get_stats().get("choices", [])


static func script_files() -> PackedStringArray:
	return get_stats().get("files", PackedStringArray())


static func chapters() -> Array:
	var raw: Variant = JsonUtil.load_json(ScriptPaths.chapters_path())
	if typeof(raw) != TYPE_DICTIONARY:
		return []
	var list: Variant = (raw as Dictionary).get("chapters", [])
	return list if typeof(list) == TYPE_ARRAY else []


static func clear_cache() -> void:
	_stats.clear()


static func _collect() -> Dictionary:
	var files := ScriptPaths.list_scripts()
	# 台词原文也一并收下来：已读率要用「当前剧本里读过几句」来算，
	# 只留一个计数就没法做这个交集了
	var lines := PackedStringArray()
	var choices: Array = []

	for path in files:
		# path 是逻辑路径；实际文件可能落在语言子目录里，读的时候再解析
		var file := FileAccess.open(ScriptPaths.resolve(path), FileAccess.READ)
		if file == null:
			continue
		var text := file.get_as_text()
		file.close()

		var result := GvsParser.parse(text, path.get_file())
		var commands: Array = result.get("commands", [])
		var file_name := path.get_file()

		# 反向索引：指令下标 → 它属于哪个标签。
		# 标签在编译结果里不是指令，只是「名字 → 下标」的映射，
		# 所以要先扫一遍所有标签，再给每条指令找「不超过它的最近标签」。
		var label_at := {}
		var sorted_labels: Array = []
		for name in (result.get("labels", {}) as Dictionary).keys():
			sorted_labels.append({"name": String(name), "index": int(result["labels"][name])})
		sorted_labels.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["index"]) < int(b["index"]))
		for idx in commands.size():
			var owner := ""
			for entry in sorted_labels:
				if int(entry["index"]) <= idx:
					owner = String(entry["name"])
				else:
					break
			label_at[idx] = owner

		for idx in commands.size():
			var cmd: Dictionary = commands[idx]
			match String(cmd.get("op", "")):
				"say":
					lines.append(String(cmd.get("text", "")))
				"choice":
					var options: Array = []
					for opt in cmd.get("options", []):
						options.append(String((opt as Dictionary).get("text", "")))
					choices.append({
						"file": file_name,
						"label": String(label_at.get(idx, "")),
						"options": options,
					})

	return {
		"line_count": lines.size(),
		"lines": lines,
		"choices": choices,
		"files": files,
	}
