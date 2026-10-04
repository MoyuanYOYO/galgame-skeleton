class_name GvsInterp
extends RefCounted

## 台词插值 —— 把 `{$名字}` 换成当前值
##
## 支持的写法（都写在台词 / 章节名 / 结局标题里）：
##
##     {$名字}                先查 call 参数（内层优先），再查剧本变量
##     {$1} / {$2}            call 的**位置参数**（`call 打招呼 alice 5`）
##     {$affection.角色id}    好感度
##     {$flag.旗标名}         旗标（true / false）
##
## **查不到时原样保留 `{$名字}`，不换成空串。** 静默变空是最难查的一类问题
## （作者只看到「那句话怎么少了半句」），留着原文一眼就能看出是名字写错了；
## `ScriptAudit` 也会把「没有任何 set/add 写过的插值名」报成 warning。
##
## 数字格式化：整数不显示小数点。存档 JSON 会把整数读回成 float，
## 直接 `str()` 会让玩家看到 `好感度 17.0` —— 这是插值最容易踩的坑。

## 插值名：`{$` 之后到第一个 `}` 之间的全部内容（不能含空白）。
##
## ⚠️ **不能只允许 `[A-Za-z0-9_]`** —— 剧本里的变量名 / call 参数名完全可能是
## 中文（`set 好感度 5`、`{$好感度}`）。限制成 ASCII 的后果是中文插值
## **完全不生效**，而且查不出原因（正则不匹配 → 原样保留 → 看起来像「没写」）。
const PATTERN := "\\{\\$([^}\\s]+)\\}"

## 值的最大小数位（非整数时）
const MAX_DECIMALS := 3

static var _re: RegEx = null


static func _regex() -> RegEx:
	if _re == null:
		_re = RegEx.new()
		_re.compile(PATTERN)
	return _re


## 把 text 里的插值全部替换掉。
##
## `resolver` 是 `Callable(name: String) -> Variant`，返回 `null` 表示「没有这个名字」。
static func resolve(text: String, resolver: Callable) -> String:
	if text.is_empty() or not text.contains("{$"):
		return text
	var matches := _regex().search_all(text)
	if matches.is_empty():
		return text
	var out := text
	# **从后往前替换**：前面的替换会改变后面匹配的下标，倒着做就不受影响。
	for i in range(matches.size() - 1, -1, -1):
		var m := matches[i]
		var value: Variant = resolver.call(m.get_string(1))
		if value == null:
			continue
		out = out.substr(0, m.get_start()) + format_value(value) + out.substr(m.get_end())
	return out


## 值 → 显示文本。整数不显示 `.0`；bool 显示 true / false；字典 / 数组退化成 str()。
static func format_value(value: Variant) -> String:
	match typeof(value):
		TYPE_BOOL:
			return "true" if bool(value) else "false"
		TYPE_INT:
			return str(int(value))
		TYPE_FLOAT:
			var f := float(value)
			if is_equal_approx(f, roundf(f)):
				return str(int(roundf(f)))
			return String.num(f, MAX_DECIMALS)
	return str(value)


## 文本里出现的全部插值名（去重、保持出现顺序）。供 ScriptAudit 与编辑器用。
static func names_in(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	if text.is_empty() or not text.contains("{$"):
		return out
	for m in _regex().search_all(text):
		var key := m.get_string(1)
		if not out.has(key):
			out.append(key)
	return out


## 这个插值名是不是「带命名空间」的（`affection.x` / `flag.x`）——
## 它们不需要剧本 set 过，静态校验要跳过。
static func is_namespaced(name: String) -> bool:
	return name.begins_with("affection.") or name.begins_with("flag.")


## 位置参数形式（`{$1}`）—— 由 call 的参数提供，也不需要 set
static func is_positional(name: String) -> bool:
	return name.is_valid_int()
