class_name TypingTimeline
extends RefCounted

## 打字节奏解析
##
## 把带 BBCode 标记的文本编译成「每个可见字符在第几秒出现」的时间轴。
##
## 为什么不用「已流逝时间 × 速度」直接算：那样只能线性推进，
## 没法在某处停顿、某段加速。预编译成时间轴之后，暂停/跳过/变速都只是
## 换个 elapsed 值去查表，不会错乱。
##
## 支持的节奏标记（写在剧本对白里即可）：
##   [wait=0.5]        在此处停顿 0.5 秒
##   [pause=0.3]       同上（别名）
##   [speed=3]...[/speed]   这一段按 3 倍速逐字显示
##
## 其他 BBCode（[shake] / [rainbow] / [bounce] …）原样保留，交给
## RichTextLabel 渲染，不占可见字符。

## 会被剥离、不参与渲染的节奏标记
const TIMING_TAGS := ["wait", "pause", "delay", "speed"]

## 单个字符的最长等待，防止 [speed=0.01] 之类把节奏拖死
const MAX_SECONDS_PER_CHAR := 0.35


## 返回 {"display": 剥离节奏标记后的文本, "times": 每个可见字符的显示时刻}
static func build(text: String, chars_per_second: float) -> Dictionary:
	var display := ""
	var times := PackedFloat64Array()
	var speeds: Array = [1.0]
	var clock := 0.0
	var base := maxf(1.0, chars_per_second)
	var index := 0
	var length := text.length()

	while index < length:
		if text[index] == "[":
			var close := text.find("]", index)
			if close > index:
				var tag := text.substr(index + 1, close - index - 1)
				if _is_timing_tag(tag):
					clock = _consume_timing(tag, speeds, clock)
					index = close + 1
					continue
				# 非节奏标记：原样保留，交给 RichTextLabel
				display += text.substr(index, close - index + 1)
				index = close + 1
				continue

		var speed := base * float(speeds[speeds.size() - 1])
		clock += minf(MAX_SECONDS_PER_CHAR, 1.0 / maxf(0.01, speed))
		times.append(clock)
		display += text[index]
		index += 1

	return {"display": display, "times": times}


## 这个 BBCode 标签是不是节奏控制（是的话要从显示文本里剥掉）
static func _is_timing_tag(tag: String) -> bool:
	var name := _tag_name(tag)
	return TIMING_TAGS.has(name)


static func _tag_name(tag: String) -> String:
	var trimmed := tag.strip_edges()
	if trimmed.begins_with("/"):
		trimmed = trimmed.substr(1)
	var eq := trimmed.find("=")
	if eq >= 0:
		trimmed = trimmed.substr(0, eq)
	return trimmed.strip_edges().to_lower()


## 消耗一个节奏标记，返回新的时间游标
static func _consume_timing(tag: String, speeds: Array, clock: float) -> float:
	var trimmed := tag.strip_edges()
	var closing := trimmed.begins_with("/")
	var name := _tag_name(trimmed)

	match name:
		"wait", "pause", "delay":
			return clock + maxf(0.0, _tag_value(trimmed))
		"speed":
			if closing:
				# [/speed] 出栈；栈底那层是基准速度，不能弹掉
				if speeds.size() > 1:
					speeds.pop_back()
			else:
				var multiplier := _tag_value(trimmed)
				speeds.append(multiplier if multiplier > 0.0 else 1.0)
	return clock


static func _tag_value(tag: String) -> float:
	var eq := tag.find("=")
	if eq < 0:
		return 0.0
	return tag.substr(eq + 1).strip_edges().to_float()


## 二分找出「已经显示到第几个字符」—— times 是升序的
static func revealed_count(times: PackedFloat64Array, elapsed: float) -> int:
	var low := 0
	var high := times.size()
	while low < high:
		var mid := (low + high) / 2
		if times[mid] <= elapsed:
			low = mid + 1
		else:
			high = mid
	return low


## 整段打完需要的总时长（秒）
static func total_seconds(times: PackedFloat64Array) -> float:
	return 0.0 if times.is_empty() else times[times.size() - 1]
