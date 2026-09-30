class_name GlitchEffect
extends RichTextEffect

## [glitch] —— 错乱 / 故障感
##
## 用法：
##   [glitch]默认错乱[/glitch]
##   [glitch rate=20 strength=6 tint=0.7]抖得更凶并偏色[/glitch]
##
## 关键点：用「确定性伪随机 + 时间片」而不是每帧 randf()。
## 逐帧随机会让字抖到完全没法阅读；按 rate 分片跳变才像数字故障。

var bbcode := "glitch"


func _process_custom_fx(char_fx: CharFXTransform) -> bool:
	var rate := maxf(1.0, float(char_fx.env.get("rate", 16.0)))
	var strength := float(char_fx.env.get("strength", 4.0))
	var tint := clampf(float(char_fx.env.get("tint", 0.0)), 0.0, 1.0)

	# 每 1/rate 秒换一次偏移量 —— 是「跳」不是「抖」
	var tick := floorf(char_fx.elapsed_time * rate)
	# 注意：Godot 4.7 的 CharFXTransform 只有 relative_index，
	# 旧版文档里的 absolute_index / character 已经不存在了。
	var seed := float(char_fx.relative_index) * 7.13

	var jitter_x := _noise(seed + tick) * 2.0 - 1.0
	var jitter_y := _noise(seed + tick + 91.7) * 2.0 - 1.0
	char_fx.offset = Vector2(jitter_x, jitter_y) * strength

	if tint > 0.0:
		var shift := _noise(seed + tick + 313.7)
		var target := Color(1.0, 0.25, 0.35) if shift < 0.5 else Color(0.35, 0.85, 1.0)
		char_fx.color = char_fx.color.lerp(target, tint)
	return true


## 确定性哈希噪声（GLSL 里那条经典的 sin-fract）
static func _noise(value: float) -> float:
	var v := sin(value * 12.9898) * 43758.5453
	return v - floorf(v)
