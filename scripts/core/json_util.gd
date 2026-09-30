class_name JsonUtil
extends RefCounted

## JSON 读写工具
##
## 同时兼容两种读取路径：
##   1. FileAccess 直读源文件（编辑器内、以及未被导入器接管的文件）
##   2. 回退到 Godot 的 JSON 资源导入结果（导出后的 pck 里源文件不在，
##      只剩导入产物）
## 这样不管在编辑器还是导出版里都能拿到数据。


static func load_json(path: String) -> Variant:
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		if not text.is_empty():
			var parsed: Variant = JSON.parse_string(text)
			if parsed != null:
				return parsed

	if ResourceLoader.exists(path):
		var res := load(path)
		if res is JSON:
			return (res as JSON).data

	push_warning("[JsonUtil] 无法读取 JSON: %s" % path)
	return null


static func save_json(path: String, data: Variant, pretty: bool = true) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[JsonUtil] 无法写入 JSON: %s" % path)
		return false
	file.store_string(JSON.stringify(data, "\t" if pretty else ""))
	file.close()
	return true


## 递归合并：让配置文件可以只写关心的那几个键
static func deep_merge(base: Dictionary, override: Dictionary) -> Dictionary:
	for key in override.keys():
		var value: Variant = override[key]
		if typeof(value) == TYPE_DICTIONARY and base.has(key) \
				and typeof(base[key]) == TYPE_DICTIONARY:
			deep_merge(base[key], value)
		else:
			base[key] = value
	return base
