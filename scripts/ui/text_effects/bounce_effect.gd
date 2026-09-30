class_name BounceEffect
extends RichTextEffect

## [bounce] —— 逐字弹跳
##
## 用法：
##   [bounce]默认弹跳[/bounce]
##   [bounce speed=9 height=14]弹得更快更高[/bounce]
##
## 相邻字符错开相位，形成波浪式弹跳；只做垂直位移，不左右晃。

var bbcode := "bounce"


func _process_custom_fx(char_fx: CharFXTransform) -> bool:
	var speed := float(char_fx.env.get("speed", 7.0))
	var height := float(char_fx.env.get("height", 9.0))

	var phase := char_fx.relative_index * 0.55
	# abs(sin) 让它像真的在弹——触底后立刻回弹，而不是正弦上下摆
	var wave := absf(sin(char_fx.elapsed_time * speed + phase))
	char_fx.offset = Vector2(0.0, -wave * height)
	return true
