class_name BlinkEffect
extends RichTextEffect

## [blink] —— 闪烁
##
## 用法：
##   [blink]默认闪烁[/blink]
##   [blink speed=9 min_alpha=0.05]闪得更快更彻底[/blink]
##
## 只改 alpha，不动位置 —— 位置变化交给 [bounce] / [shake]。
## 相邻字符错开相位，避免整段同时亮灭（那样看着像闪屏）。

var bbcode := "blink"


func _process_custom_fx(char_fx: CharFXTransform) -> bool:
	var speed := float(char_fx.env.get("speed", 5.0))
	var min_alpha := clampf(float(char_fx.env.get("min_alpha", 0.15)), 0.0, 1.0)

	var phase := char_fx.relative_index * 0.3
	var wave := 0.5 + 0.5 * sin(char_fx.elapsed_time * speed + phase)

	var color := char_fx.color
	color.a = color.a * lerpf(min_alpha, 1.0, wave)
	char_fx.color = color
	return true
