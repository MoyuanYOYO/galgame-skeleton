class_name ScreenFxSpec
extends RefCounted

## 全屏特效的种类表
##
## 单独放在 core 里，是因为三个地方都要用它，而它们分属不同层：
##   · `GvsParser`（core）据此校验剧本里写的种类，写错当场报错；
##   · `ScreenFx`（表现层）据此把种类名映射成 shader 的 mode 整数；
##   · 测试据此遍历所有种类，保证「加了一种就一定有样本」。
##
## **顺序就是 shader 里的 mode 值**，不能随意调整 ——
## 要加新种类请追加到末尾，并在 screen_fx.gdshader 里补对应分支。

const KINDS: PackedStringArray = [
	"glitch",      # 0 错乱：横条撕裂 + RGB 分离 + 扫描线
	"wave",        # 1 波纹扭曲
	"swirl",       # 2 漩涡扭曲
	"pixelate",    # 3 马赛克
	"chromatic",   # 4 色差
	"invert",      # 5 反色
	"blur",        # 6 模糊
]

## 关闭。和 `weather none` 一个写法：关也走同一条指令，不额外发明一条 off。
const OFF := "none"

## 不写 duration 时的默认时长。够看清楚，又不至于挡着玩家读字。
const DEFAULT_DURATION := 0.8


static func is_valid(kind: String) -> bool:
	return kind == OFF or KINDS.has(kind)


## 种类名 → shader 的 mode 整数。未知种类返回 -1。
static func mode_of(kind: String) -> int:
	return KINDS.find(kind)


## 给报错信息用的一行清单
static func list_text() -> String:
	return " / ".join(KINDS) + " / " + OFF
