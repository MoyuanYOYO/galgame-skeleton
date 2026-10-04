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
## 支持的标记（写在剧本对白里即可）：
##   [wait=0.5]        在此处停顿 0.5 秒后**自动**继续
##   [pause=0.3]       同上（别名）
##   [speed=3]...[/speed]   这一段按 3 倍速逐字显示
##   [stop]            在此处**停下等点击**，点了才接着显示（[click] 是别名）
##   [fx=glitch]       在此处触发音频效果器（默认 BGM 总线，0.6 秒后自动清除）
##   [fx=glitch bus=voice dur=0.4 strength=1.5]
##   [fx=off bus=voice]  在此处清除该总线上我们加的效果器
##
## 其他 BBCode（[shake] / [rainbow] / [bounce] …）原样保留，交给
## RichTextLabel 渲染，不占可见字符。
##
## ⚠️ **所有标记都会被从 `display` 里剥掉。** RichTextLabel 对未知标签会
## 连方括号一起漏成正文，所以「节奏 / 停顿 / 效果器」这三类标记一个都不能留。
##
## 三个产出各自的下标口径**都是「可见字符数」**（不是字符串下标）——
## 因为 `display` 里还留着 [shake] 这类 BBCode 标记，字符串长度不等于
## 可见字符数，而 `RichTextLabel.visible_characters` 数的是可见字符。

## 会被剥离、推进时间轴的节奏标记
const TIMING_TAGS := ["wait", "pause", "delay", "speed"]
## 会被剥离、作为「点击门控停顿点」的标记
const STOP_TAGS := ["stop", "click"]
## 会被剥离、作为「音频效果器触发点」的标记
const FX_TAGS := ["fx"]

## 单个字符的最长等待，防止 [speed=0.01] 之类把节奏拖死
const MAX_SECONDS_PER_CHAR := 0.35

## [fx=…] 没写 dur= 时的默认持续时长（秒）。取自 AudioFxSpec，别在这里另写一个数。
const FX_DEFAULT_DURATION := AudioFxSpec.INLINE_DURATION
## [fx=…] 没写 bus= 时作用的音轨。默认 BGM —— 它对白时一定在响。
const FX_DEFAULT_BUS := "bgm"


## 编译结果：
##   display —— 剥离全部标记后的文本（仍含 [shake] 这类渲染用 BBCode）
##   times   —— 每个可见字符的显示时刻（秒），升序
##   stops   —— 停顿点 [{index: 可见字符数, gate: 是否需点击}]，按 index 升序
##   events  —— 效果器触发点 [{index, kind, bus, duration, strength, pitch}]
static func build(text: String, chars_per_second: float) -> Dictionary:
	var display := ""
	var times := PackedFloat64Array()
	var stops: Array = []
	var events: Array = []
	var speeds: Array = [1.0]
	var clock := 0.0
	var base := maxf(1.0, chars_per_second)
	var index := 0
	# 可见字符计数。**不能拿 display.length() 当停顿下标** ——
	# display 里留着 [shake] 这类标记，两者不是一回事。
	var visible := 0
	var length := text.length()

	while index < length:
		if text[index] == "[":
			var close := text.find("]", index)
			if close > index:
				var tag := text.substr(index + 1, close - index - 1)
				var name := _tag_name(tag)
				var closing := tag.strip_edges().begins_with("/")

				# 节奏标记（含闭合写法 `[/speed]`）一律剥离并推进时钟。
				# ⚠️ 闭合写法必须走这条路 —— 放它漏到 display 里的话，
				# RichTextLabel 会把 `[/speed]` 当成未知标签**原样显示**，
				# 玩家就会在对话框里看到方括号。
				if TIMING_TAGS.has(name):
					# wait / pause / delay 会在时间轴上留一个「空档」，
					# 那正是玩家眼里的「停顿点」—— 点击快进时以它为落点。
					# speed 只是改变速率，不是停顿。
					if not closing and name != "speed":
						_add_stop(stops, visible, false)
					clock = _consume_timing(tag, speeds, clock)
					index = close + 1
					continue

				# 点击门控 / 效果器触发点。闭合写法只剥离，不产生事件。
				if STOP_TAGS.has(name) or FX_TAGS.has(name):
					if not closing:
						if STOP_TAGS.has(name):
							_add_stop(stops, visible, true)
						else:
							events.append(_parse_fx(tag, visible))
					index = close + 1
					continue

				# 渲染用的标记（[shake] / [color=…] …）：原样保留
				display += text.substr(index, close - index + 1)
				index = close + 1
				continue

		var speed := base * float(speeds[speeds.size() - 1])
		clock += minf(MAX_SECONDS_PER_CHAR, 1.0 / maxf(0.01, speed))
		times.append(clock)
		display += text[index]
		visible += 1
		index += 1

	return {"display": display, "times": times, "stops": stops, "events": events}


## 只剥离标记，不要时间轴。
##
## 回看面板、存档预览这类「把台词显示成一行静态文字」的地方用它 ——
## 它们不走打字机，但同样不能把 [speed=3] / [stop] / [fx=glitch] 原样漏给玩家看。
## 非节奏标记（[bounce] / [color=…] 这些）照旧保留，交给 RichTextLabel 渲染。
static func strip(text: String) -> String:
	return String(build(text, 1.0).get("display", text))


## 整段打完需要的总时长（秒）
static func total_seconds(times: PackedFloat64Array) -> float:
	return 0.0 if times.is_empty() else times[times.size() - 1]


## 二分找出「已经显示到第几个字符」—— times 是升序的
static func revealed_count(times: PackedFloat64Array, elapsed: float) -> int:
	var low := 0
	var high := times.size()
	while low < high:
		# 中点必须向下取整：改成浮点会得到 times[0.5] 这种下标，直接越界。
		# 编辑器会提示「整数除法会丢小数」，但这里丢掉的正是要丢的。
		@warning_ignore("integer_division")
		var mid := (low + high) / 2
		if times[mid] <= elapsed:
			low = mid + 1
		else:
			high = mid
	return low


# ---------------------------------------------------------------------------
# 内部
# ---------------------------------------------------------------------------

## 同一个下标上的多个停顿点合并成一个 —— 否则玩家要连点两次才过得去。
## 门控优先：只要其中有一个是点击门控，合并后就按门控处理。
static func _add_stop(stops: Array, index: int, gate: bool) -> void:
	if not stops.is_empty():
		var last: Dictionary = stops[stops.size() - 1]
		if int(last["index"]) == index:
			last["gate"] = bool(last["gate"]) or gate
			return
	stops.append({"index": index, "gate": gate})


## 解析 [fx=kind bus=… dur=… strength=… pitch=…]
static func _parse_fx(tag: String, index: int) -> Dictionary:
	var eq := tag.find("=")
	var body := tag.substr(eq + 1).strip_edges() if eq >= 0 else ""
	var tokens := body.split(" ", false)
	var ev := {
		"index": index,
		"kind": "glitch",
		"bus": FX_DEFAULT_BUS,
		"duration": FX_DEFAULT_DURATION,
		"strength": 1.0,
		"pitch": 1.0,
	}
	if tokens.size() > 0:
		ev["kind"] = String(tokens[0]).to_lower()
	for i in range(1, tokens.size()):
		var t := String(tokens[i])
		var e := t.find("=")
		if e <= 0:
			continue
		var key := t.substr(0, e).to_lower()
		var value := t.substr(e + 1)
		match key:
			"bus", "track":
				ev["bus"] = value.strip_edges().to_lower()
			"dur", "duration":
				ev["duration"] = maxf(0.0, value.to_float())
			"strength":
				ev["strength"] = value.to_float()
			"pitch":
				ev["pitch"] = maxf(0.01, value.to_float())
	return ev


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
