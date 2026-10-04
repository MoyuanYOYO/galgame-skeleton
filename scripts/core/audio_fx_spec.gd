class_name AudioFxSpec
extends RefCounted

## 音频效果器规格 —— 「哪条音轨 / 哪些效果器」的**唯一清单**。
##
## 三处共用这一份，谁都不许另抄一遍：
##   · `GvsParser._do_audio_fx` —— 解析剧本指令时校验
##   · `AudioManager`           —— 运行时校验 + 实际挂载
##   · `tools/editor` 的 OpSpec —— 生成类型下拉
##
## 抄两份的后果是「解析器认识、调度器不认」或「编辑器给了一个运行时拒绝的选项」，
## 两种都是不报错的静默失效 —— 本项目最想避免的那类 bug。
## 与 `ScreenFxSpec`（全屏特效）同一个套路。

## 音轨名。`all` = 三条一起，`master` = 总输出。
const TRACKS: PackedStringArray = ["bgm", "se", "voice", "all", "master"]

## 效果器种类。`none` / `off` / `clear` 都表示「清除这条音轨上我们加的效果器」。
##
## Godot 没有 BitCrusher 类（ClassDB 里查不到），所以「故障 / 错误」是用
## `AudioEffectDistortion` 的 LOFI 模式 + `AudioEffectPitchShift` 的随机抖动
## 拼出来的 —— 见 AudioManager._install_fx。
const KINDS: PackedStringArray = [
	"glitch", "error", "distortion", "pitch", "muffle",
	"radio", "echo", "reverb", "underwater", "amplify",
	"none", "off", "clear",
]

## 剧本 `audio_fx` 没写 duration= 时的默认时长（秒）。
## 0 表示「持续到显式清除」—— 默认给一个有限时长更安全，
## 忘了写 off 也不会让整章音乐一直坏着。
const DEFAULT_DURATION := 0.8

## 内联标签 `[fx=…]` 的默认时长（比指令短，跟着一句话走）
const INLINE_DURATION := 0.6

## 这些值等价于「清除」
const CLEAR_ALIASES: PackedStringArray = ["none", "off", "clear"]


static func is_valid_track(track: String) -> bool:
	return TRACKS.has(track.strip_edges().to_lower())


static func is_valid_kind(kind: String) -> bool:
	return KINDS.has(kind.strip_edges().to_lower())


static func is_clear(kind: String) -> bool:
	return CLEAR_ALIASES.has(kind.strip_edges().to_lower())


static func list_text() -> String:
	return ", ".join(KINDS)


static func tracks_text() -> String:
	return ", ".join(TRACKS)
