extends RefCounted

## 指令参数规格表 —— 剧本块「可视化编辑」的数据来源
##
## 这张表决定每条指令在剧本块里渲染成什么控件。表驱动的好处是：
## 加一条新指令只要往这里加一项，不用碰渲染代码。
##
## 字段的两种形态（与 `GvsParser` 的参数模型一一对应）：
##
##   `pos` 存在  → **位置参数**，如 `show alice` 里的 `alice`。
##                 `pos` 是它在位置参数里的下标（0 起）。
##                 位置参数写回时按「第几个词」替换。
##   `pos` 不存在 → **kv 参数**，如 `fade=0.8`。
##                 写回时用正则替换 `key=值`，不存在的就追加到行尾。
##
## 为什么区分这两种：GVS 的位置参数个数因指令而异（`expr alice smile` 有两个），
## 而 kv 参数的顺序无关紧要。混在一起处理会让写回逻辑变得不可靠。
##
## 结构类指令（label / jump / if / choice / end …）**刻意不给规格** ——
## 它们不是「可调参数」，而是剧本骨架。渲染器会把它们显示成只读的原文行，
## 删除时也要额外确认（删掉一个 end 会让后面整段落进块里，后果隐蔽）。

const F_ASSET := "asset"    ## 从素材索引里选（下拉 + 缩略图）
const F_ENUM := "enum"      ## 固定选项下拉
const F_NUM := "num"        ## 数字
const F_BOOL := "bool"      ## 开关
const F_TEXT := "text"      ## 文本
const F_LABEL := "label"    ## 标签引用（渲染成可点击的链接，点了跳过去）

## 位置参数上还能带三个修饰（前两个用在 `F_TEXT` 上）：
##
##   `"quoted": true` → 值写成 `"…"`（解析器会 `unquote`）。
##   `"rest": true`   → 这个字段吃**从它到最后一个位置参数**的整段，
##                      不是一个词。`ending normal "春日的答案"` 的标题、
##                      `chapter 序章 · 新学期` 的章节名都是这种。
##   `"tail": true`   → 这个字段吃**从它往后到行尾**的全部内容（含 kv 参数）。
##                      用于 `call 打招呼 who=alice count=2` 这种「后面是一串
##                      自由形式的参数」—— `rest` 只到最后一个位置参数，
##                      而 `who=alice` 是 kv，会被整段漏掉。
##
## 不加 `rest` / `tail` 时值必须是单个词 —— 按词替换才不会把后面的参数吃掉。

## 转场类型（与 stage.gd 的实现一致）
const TRANSITIONS := ["fade", "dissolve", "wipe", "blinds", "circle", "slide_left", "slide_right"]
## 立绘位置槽
const ANCHORS := ["left", "center", "right", "off_left", "off_right"]
## 缓动
const EASES := ["out_cubic", "in_cubic", "in_out_cubic", "out_back", "out_quad", "linear"]
## 天气
const WEATHERS := ["none", "rain", "snow", "sakura"]
## 视频图层
const VIDEO_LAYERS := ["world", "ui", "top"]
## 结束方式
const MINIGAMES := ["rhythm_qte"]

## 结构类指令：不给可视化控件，删除要确认
const STRUCTURAL := [
	"label", "jump", "goto", "call", "return", "jump_file",
	"if", "elif", "else", "end", "together", "choice",
]

## 结构类指令的**插入模板**。
##
## 它们没有字段规格（不是「可调参数」而是骨架），但「在下边插一条」这个动作
## 需要一个能用的骨架 —— 否则插出来的是个光秃秃的 `label`，作者还得自己补。
const STRUCTURAL_TEMPLATES := {
	"label": "label 新标签",
	"jump": "jump 目标标签",
	"goto": "goto 目标标签",
	"call": "call 子过程",
	"return": "return",
	"jump_file": "jump_file res://data/scripts/chapter1.gvs start",
	# together 是多行块，实际插入走 TablePanel._insert_block 的专门分支；
	# 这里留一份单行兜底，免得别处拿不到模板。
	"together": "together",
}


static func structural_template(op: String) -> String:
	return String(STRUCTURAL_TEMPLATES.get(op, op))

static var _cache: Dictionary = {}


static func specs() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	_cache = {
		"bg": {
			"label": "背景", "tag": "BG",
			"fields": [
				{"key": "id", "pos": 0, "type": F_ASSET, "kind": "bg", "label": "背景", "wide": true},
				{"key": "type", "type": F_ENUM, "values": TRANSITIONS, "default": "fade", "label": "转场"},
				{"key": "fade", "type": F_NUM, "min": 0.0, "max": 4.0, "step": 0.05, "default": 0.4, "label": "秒"},
			],
		},
		"cg": {
			"label": "CG", "tag": "CG",
			"fields": [
				{"key": "id", "pos": 0, "type": F_ASSET, "kind": "cg", "label": "CG", "wide": true},
				{"key": "type", "type": F_ENUM, "values": TRANSITIONS, "default": "fade", "label": "转场"},
				{"key": "fade", "type": F_NUM, "min": 0.0, "max": 4.0, "step": 0.05, "default": 0.5, "label": "秒"},
			],
		},
		"hide_cg": {
			"label": "收起 CG", "tag": "CG",
			"fields": [
				{"key": "type", "type": F_ENUM, "values": TRANSITIONS, "default": "fade", "label": "转场"},
				{"key": "fade", "type": F_NUM, "min": 0.0, "max": 4.0, "step": 0.05, "default": 0.4, "label": "秒"},
			],
		},
		"bgm": {
			"label": "音乐", "tag": "BGM",
			"fields": [
				{"key": "id", "pos": 0, "type": F_ASSET, "kind": "bgm", "label": "曲目", "wide": true},
				{"key": "volume", "type": F_NUM, "min": 0.0, "max": 1.0, "step": 0.05, "default": 0.8, "label": "音量"},
				{"key": "fade", "type": F_NUM, "min": 0.0, "max": 5.0, "step": 0.1, "default": 1.0, "label": "淡入"},
			],
		},
		"se": {
			"label": "音效", "tag": "SE",
			"fields": [
				{"key": "id", "pos": 0, "type": F_ASSET, "kind": "se", "label": "音效", "wide": true},
				{"key": "volume", "type": F_NUM, "min": 0.0, "max": 1.0, "step": 0.05, "default": 1.0, "label": "音量"},
			],
		},
		"voice": {
			"label": "语音", "tag": "VO",
			"fields": [
				{"key": "id", "pos": 0, "type": F_ASSET, "kind": "voice", "label": "语音", "wide": true},
				{"key": "volume", "type": F_NUM, "min": 0.0, "max": 1.0, "step": 0.05, "default": 1.0, "label": "音量"},
			],
		},
		# 音轨效果器。候选值直接取自 AudioFxSpec（解析器 / 运行时 / 编辑器共用一份）——
		# 手抄一份的后果是「编辑器给了一个运行时拒绝的选项」，不报错、只是没效果。
		"audio_fx": {
			"label": "音频特效", "tag": "AFX",
			"fields": [
				{"key": "track", "pos": 0, "type": F_ENUM, "values": Array(AudioFxSpec.TRACKS),
					"default": "bgm", "label": "音轨"},
				{"key": "kind", "pos": 1, "type": F_ENUM, "values": Array(AudioFxSpec.KINDS),
					"default": "glitch", "label": "效果"},
				{"key": "duration", "type": F_NUM, "min": 0.0, "max": 10.0, "step": 0.1,
					"default": AudioFxSpec.DEFAULT_DURATION, "label": "秒"},
				{"key": "strength", "type": F_NUM, "min": 0.1, "max": 4.0, "step": 0.1,
					"default": 1.0, "label": "强度"},
				{"key": "pitch", "type": F_NUM, "min": 0.25, "max": 4.0, "step": 0.05,
					"default": 1.5, "label": "移调"},
			],
		},
		"show": {
			"label": "立绘入场", "tag": "CHAR",
			"fields": [
				{"key": "char", "pos": 0, "type": F_ASSET, "kind": "char", "label": "角色"},
				{"key": "expr", "type": F_EXPR, "default": "normal", "label": "表情"},
				{"key": "at", "type": F_ENUM, "values": ANCHORS, "default": "center", "label": "位置"},
				{"key": "type", "type": F_ENUM, "values": TRANSITIONS, "default": "fade", "label": "入场"},
				{"key": "fade", "type": F_NUM, "min": 0.0, "max": 3.0, "step": 0.05, "default": 0.3, "label": "秒"},
			],
		},
		"hide": {
			"label": "立绘退场", "tag": "CHAR",
			"fields": [
				{"key": "char", "pos": 0, "type": F_ASSET, "kind": "char", "label": "角色"},
				{"key": "type", "type": F_ENUM, "values": TRANSITIONS, "default": "fade", "label": "退场"},
				{"key": "fade", "type": F_NUM, "min": 0.0, "max": 3.0, "step": 0.05, "default": 0.3, "label": "秒"},
			],
		},
		"move": {
			"label": "立绘移动", "tag": "CHAR",
			"fields": [
				{"key": "char", "pos": 0, "type": F_ASSET, "kind": "char", "label": "角色"},
				{"key": "at", "type": F_ENUM, "values": ANCHORS, "default": "center", "label": "移到"},
				{"key": "fade", "type": F_NUM, "min": 0.0, "max": 4.0, "step": 0.05, "default": 0.35, "label": "秒"},
				{"key": "ease", "type": F_ENUM, "values": EASES, "default": "out_cubic", "label": "缓动"},
			],
		},
		"expr": {
			"label": "换表情", "tag": "CHAR",
			"fields": [
				{"key": "char", "pos": 0, "type": F_ASSET, "kind": "char", "label": "角色"},
				{"key": "expr", "pos": 1, "type": F_EXPR, "default": "normal", "label": "表情"},
				{"key": "fade", "type": F_NUM, "min": 0.0, "max": 2.0, "step": 0.05, "default": 0.18, "label": "秒"},
			],
		},
		"hop": {
			"label": "小跳", "tag": "CHAR",
			"fields": [
				{"key": "char", "pos": 0, "type": F_ASSET, "kind": "char", "label": "角色"},
				{"key": "height", "type": F_NUM, "min": 0.0, "max": 200.0, "step": 1.0, "default": 40.0, "label": "高度"},
				{"key": "times", "type": F_NUM, "min": 1.0, "max": 10.0, "step": 1.0, "default": 2.0, "label": "次数"},
				{"key": "duration", "type": F_NUM, "min": 0.1, "max": 4.0, "step": 0.05, "default": 0.7, "label": "秒"},
			],
		},
		"zoom": {
			"label": "缩放", "tag": "CHAR",
			"fields": [
				{"key": "char", "pos": 0, "type": F_ASSET, "kind": "char", "label": "角色"},
				{"key": "scale", "pos": 1, "type": F_NUM, "min": 0.2, "max": 3.0, "step": 0.05, "default": 1.25, "label": "倍数"},
				{"key": "duration", "type": F_NUM, "min": 0.05, "max": 3.0, "step": 0.05, "default": 0.4, "label": "秒"},
				{"key": "ease", "type": F_ENUM, "values": EASES, "default": "out_back", "label": "缓动"},
			],
		},
		"shake": {
			"label": "抖动", "tag": "CHAR",
			"fields": [
				{"key": "char", "pos": 0, "type": F_ASSET, "kind": "char", "label": "角色"},
				{"key": "strength", "type": F_NUM, "min": 0.0, "max": 120.0, "step": 1.0, "default": 28.0, "label": "强度"},
				{"key": "times", "type": F_NUM, "min": 1.0, "max": 20.0, "step": 1.0, "default": 5.0, "label": "次数"},
				{"key": "duration", "type": F_NUM, "min": 0.05, "max": 3.0, "step": 0.05, "default": 0.45, "label": "秒"},
			],
		},
		"anim": {
			"label": "帧动画", "tag": "CHAR",
			"fields": [
				{"key": "char", "pos": 0, "type": F_ASSET, "kind": "char", "label": "角色"},
				{"key": "speed", "type": F_NUM, "min": 0.1, "max": 4.0, "step": 0.05, "default": 1.0, "label": "速度"},
				{"key": "pause", "type": F_BOOL, "default": false, "label": "定格"},
				{"key": "once", "type": F_BOOL, "default": false, "label": "只播一遍"},
				{"key": "frame", "type": F_NUM, "min": -1.0, "max": 64.0, "step": 1.0, "default": -1.0, "label": "帧"},
			],
		},
		"weather": {
			"label": "天气", "tag": "FX",
			"fields": [
				{"key": "kind", "pos": 0, "type": F_ENUM, "values": WEATHERS, "default": "none", "label": "天气"},
				{"key": "intensity", "type": F_NUM, "min": 0.0, "max": 3.0, "step": 0.05, "default": 1.0, "label": "强度"},
			],
		},
		"screen_fx": {
			"label": "全屏特效", "tag": "FX",
			"fields": [
				{"key": "kind", "pos": 0, "type": F_ENUM, "values": ["none", "glitch", "wave", "swirl",
					"pixelate", "chromatic", "invert", "blur"], "default": "none", "label": "特效"},
				{"key": "strength", "type": F_NUM, "min": 0.0, "max": 4.0, "step": 0.05, "default": 1.0, "label": "强度"},
				{"key": "duration", "type": F_NUM, "min": 0.0, "max": 8.0, "step": 0.1, "default": 0.8, "label": "秒"},
			],
		},
		"screen_flash": {
			"label": "闪光", "tag": "FX",
			"fields": [
				{"key": "color", "type": F_TEXT, "default": "#ffffff", "label": "颜色"},
				{"key": "duration", "type": F_NUM, "min": 0.0, "max": 3.0, "step": 0.05, "default": 0.25, "label": "秒"},
			],
		},
		"screen_shake": {
			"label": "全屏震动", "tag": "FX",
			"fields": [
				{"key": "strength", "type": F_NUM, "min": 0.0, "max": 120.0, "step": 1.0, "default": 36.0, "label": "强度"},
				{"key": "times", "type": F_NUM, "min": 1.0, "max": 20.0, "step": 1.0, "default": 5.0, "label": "次数"},
				{"key": "duration", "type": F_NUM, "min": 0.05, "max": 3.0, "step": 0.05, "default": 0.45, "label": "秒"},
			],
		},
		"bg_motion": {
			"label": "背景运镜", "tag": "FX",
			"fields": [
				{"key": "scale", "type": F_NUM, "min": 0.5, "max": 2.0, "step": 0.01, "default": 1.0, "label": "缩放"},
				{"key": "x", "type": F_NUM, "min": -400.0, "max": 400.0, "step": 1.0, "default": 0.0, "label": "X"},
				{"key": "y", "type": F_NUM, "min": -400.0, "max": 400.0, "step": 1.0, "default": 0.0, "label": "Y"},
				{"key": "duration", "type": F_NUM, "min": 0.5, "max": 30.0, "step": 0.5, "default": 6.0, "label": "秒"},
				{"key": "ease", "type": F_ENUM, "values": EASES, "default": "in_out_cubic", "label": "缓动"},
			],
		},
		"video": {
			"label": "视频", "tag": "VIDEO",
			"fields": [
				{"key": "id", "pos": 0, "type": F_ASSET, "kind": "video", "label": "视频", "wide": true},
				{"key": "layer", "type": F_ENUM, "values": VIDEO_LAYERS, "default": "world", "label": "图层"},
				{"key": "wait", "type": F_BOOL, "default": false, "label": "播完再继续"},
				{"key": "loop", "type": F_BOOL, "default": false, "label": "循环"},
				{"key": "volume", "type": F_NUM, "min": 0.0, "max": 1.0, "step": 0.05, "default": 1.0, "label": "音量"},
			],
		},
		"hide_video": {
			"label": "收起视频", "tag": "VIDEO",
			"fields": [
				{"key": "fade", "type": F_NUM, "min": 0.0, "max": 3.0, "step": 0.05, "default": 0.3, "label": "秒"},
			],
		},
		"wait": {
			"label": "等待", "tag": "FLOW",
			"fields": [
				{"key": "duration", "pos": 0, "type": F_NUM, "min": 0.0, "max": 20.0, "step": 0.1,
					"default": 0.6, "label": "秒", "bare": true},
			],
		},
		"wait_click": {"label": "等点击", "tag": "FLOW", "fields": []},
		"pause": {"label": "等点击", "tag": "FLOW", "fields": []},
		"flag": {
			"label": "置旗标", "tag": "STATE",
			"fields": [
				{"key": "name", "pos": 0, "type": F_TEXT, "label": "旗标名", "wide": true},
				{"key": "value", "pos": 1, "type": F_BOOL, "default": true, "label": "值"},
			],
		},
		"affection": {
			"label": "好感度", "tag": "STATE",
			"fields": [
				{"key": "char", "pos": 0, "type": F_ASSET, "kind": "char", "label": "角色"},
				{"key": "amount", "pos": 1, "type": F_NUM, "min": -100.0, "max": 100.0, "step": 1.0,
					"default": 5.0, "label": "增减"},
			],
		},
		"ending": {
			"label": "结局", "tag": "FLOW",
			"fields": [
				{"key": "id", "pos": 0, "type": F_TEXT, "label": "结局 id"},
				# 标题在剧本里是**位置参数 + 双引号整段**（`ending normal "春日的答案"`），
				# 不是 kv 参数 —— 早先按 kv 处理，于是界面上读不出来、
				# 手输了也会「按回车就消失」（kv 被解析器丢掉）。
				{"key": "title", "pos": 1, "type": F_TEXT, "quoted": true, "rest": true,
					"label": "标题", "wide": true},
			],
		},
		"chapter": {
			"label": "章节名", "tag": "FLOW",
			"fields": [
				{"key": "title", "pos": 0, "type": F_TEXT, "quoted": true, "rest": true,
					"label": "章节名", "wide": true},
			],
		},
		"set": {
			"label": "变量赋值", "tag": "STATE", "skip_if_first": "var",
			"fields": [
				{"key": "name", "pos": 0, "type": F_TEXT, "label": "变量", "wide": true},
				{"key": "value", "pos": 1, "type": F_TEXT, "label": "值", "wide": true},
			],
		},
		"add": {
			"label": "变量加", "tag": "STATE", "skip_if_first": "var",
			"fields": [
				{"key": "name", "pos": 0, "type": F_TEXT, "label": "变量"},
				{"key": "amount", "pos": 1, "type": F_NUM, "min": -100.0, "max": 100.0,
					"step": 1.0, "default": 1.0, "label": "增减"},
			],
		},
		"sub": {
			"label": "变量减", "tag": "STATE", "skip_if_first": "var",
			"fields": [
				{"key": "name", "pos": 0, "type": F_TEXT, "label": "变量"},
				{"key": "amount", "pos": 1, "type": F_NUM, "min": -100.0, "max": 100.0,
					"step": 1.0, "default": 1.0, "label": "增减"},
			],
		},
		# --- 跳转类：给「目标」一个可点击的链接，点了直接跳过去 ---
		# 它们仍在 STRUCTURAL 里（不给类型下拉、删除要确认），
		# 但**渲染成可视行** —— 只读原文的话，跳转目标就没法点。
		"jump": {
			"label": "跳转", "tag": "FLOW",
			"fields": [{"key": "label", "pos": 0, "type": F_LABEL, "label": "目标"}],
		},
		"goto": {
			"label": "跳转", "tag": "FLOW",
			"fields": [{"key": "label", "pos": 0, "type": F_LABEL, "label": "目标"}],
		},
		"call": {
			"label": "调用", "tag": "FLOW",
			"fields": [
				{"key": "label", "pos": 0, "type": F_LABEL, "label": "子过程"},
				# 参数是「标签之后的整段」：`who=alice count=2` 或 `alice 2` 都能写。
				# 必须是 `tail`（吃到行尾）而不是 `rest`（只到最后一个位置参数）——
				# 具名参数是 kv，`rest` 会把它整段漏掉，界面就永远显示不出参数。
				{"key": "args", "pos": 1, "type": F_TEXT, "tail": true,
					"label": "参数", "wide": true},
			],
		},
		"jump_file": {
			"label": "跨文件跳转", "tag": "FLOW",
			"fields": [
				{"key": "file", "pos": 0, "type": F_TEXT, "label": "文件", "wide": true},
				# 目标是**另一个文件里的**标签：file_pos 指明从哪个位置参数取文件名
				{"key": "label", "pos": 1, "type": F_LABEL, "label": "目标", "file_pos": 0},
			],
		},
		"minigame": {
			"label": "小游戏", "tag": "FLOW",
			"fields": [
				{"key": "id", "pos": 0, "type": F_ENUM, "values": MINIGAMES, "default": "rhythm_qte", "label": "类型"},
			],
		},
		"unlock": {
			"label": "解锁", "tag": "FLOW",
			"fields": [
				{"key": "type", "pos": 0, "type": F_ENUM, "values": ["cg", "music", "video", "endings"],
					"default": "cg", "label": "类别"},
				{"key": "id", "pos": 1, "type": F_TEXT, "label": "id", "wide": true},
			],
		},
		"clear": {"label": "清空画面", "tag": "FX", "fields": []},
		"carry": {
			"label": "跨周目继承", "tag": "STATE",
			"fields": [
				{"key": "kind", "pos": 0, "type": F_ENUM, "values": ["flag", "var", "affection"],
					"default": "flag", "label": "类型"},
				{"key": "name", "pos": 1, "type": F_TEXT, "label": "名字", "wide": true},
			],
		},
	}
	return _cache


## 表情字段需要按角色动态取选项，所以单列一个类型
const F_EXPR := "expr"


static func has_spec(op: String) -> bool:
	return specs().has(op)


static func get_spec(op: String) -> Dictionary:
	return specs().get(op, {})


static func is_structural(op: String) -> bool:
	return STRUCTURAL.has(op)


## 一条指令的字段默认值（用于「新建一条指令」时填模板）
static func default_text(op: String) -> String:
	var spec := get_spec(op)
	if spec.is_empty():
		return op
	var parts: Array = [op]
	var pos_fields: Array = []
	for f in (spec.get("fields", []) as Array):
		var fd: Dictionary = f
		if fd.has("pos"):
			pos_fields.append(fd)
	pos_fields.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["pos"]) < int(b["pos"]))
	for fd in pos_fields:
		parts.append(_placeholder(fd))
	for f2 in (spec.get("fields", []) as Array):
		var fd2: Dictionary = f2
		if fd2.has("pos"):
			continue
		if fd2.get("type", "") == F_BOOL:
			if bool(fd2.get("default", false)):
				parts.append("%s=true" % fd2["key"])
			continue
		parts.append("%s=%s" % [fd2["key"], _placeholder(fd2)])
	return " ".join(parts)


static func _placeholder(fd: Dictionary) -> String:
	match String(fd.get("type", "")):
		F_ASSET:
			return "<%s>" % String(fd.get("label", "id"))
		F_EXPR:
			return String(fd.get("default", "normal"))
		F_ENUM:
			return String(fd.get("default", ""))
		F_NUM:
			return _fmt_num(float(fd.get("default", 0.0)))
		F_BOOL:
			return "true" if bool(fd.get("default", false)) else "false"
	return String(fd.get("default", ""))


static func _fmt_num(v: float) -> String:
	if is_equal_approx(v, roundf(v)):
		return str(int(roundf(v)))
	return String.num(v, 2)


## 可以在表格里「新增」的指令类型（按用途分组，供插入菜单用）
##
## 「结构 / 跳转」那一组是**只能插入、不能转换**的：把一行现成的台词
## 转成 `end` 会让块结构整体变化，后果隐蔽。选它们时界面会改成「在下面插一条」。
static func insert_menu() -> Array:
	return [
		["对白", ["__say"]],
		["背景与 CG", ["bg", "cg", "hide_cg", "bg_motion"]],
		["立绘", ["show", "hide", "move", "expr", "hop", "zoom", "shake", "anim"]],
		["音频", ["bgm", "se", "voice"]],
		["音频特效", ["audio_fx"]],
		["画面特效", ["weather", "screen_fx", "screen_flash", "screen_shake", "clear"]],
		["流程", ["wait", "wait_click", "choice", "if", "end", "chapter", "minigame"]],
		["状态与变量", ["flag", "affection", "set", "add", "sub", "carry", "unlock"]],
		["结局", ["ending"]],
		["媒体", ["video", "hide_video"]],
		["结构 / 跳转（插入）", ["label", "jump", "goto", "call", "return", "jump_file", "together"]],
	]
