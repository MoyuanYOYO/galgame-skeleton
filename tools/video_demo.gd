extends Node

## 生成视频功能的演示截图（存到 user://）
##
## 左：全屏过场（at=full，默认 world 图层，在对话框之下）
## 右：小窗视频（at=320,180 size=640,360 layer=ui，压在 UI 之上）
##
##   Godot --path . res://tools/video_demo.tscn

const MAIN_SCENE := "res://scenes/main.tscn"
const FIXTURE_ROOT := "res://tools/fixtures/video/"

var _main: Control


func _ready() -> void:
	await _wait(0.3)
	VideoScreen.video_root_override = FIXTURE_ROOT
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(0.9)
	(_main.get("title") as Control).visible = false

	# 摆一个有内容的舞台，好看出图层关系
	var stage: Stage = _main.get("stage") as Stage
	stage.set_bg("classroom", "none", 0.0)
	stage.show_char("alice", "normal", "left", "none", 0.0)
	stage.show_char("bob", "normal", "right", "none", 0.0)
	(_main.get("dialogue") as DialogueBox).show_line("alice", "视频可以铺满整屏，也可以只占一块。")
	await _wait(0.6)

	# 左：全屏过场
	_send({"op": "video", "id": "motion", "layer": "world", "at": "full",
		"fade": 0.0, "volume": 1.0, "speed": 0.25, "buffer": 120,
		"loop": true, "wait": false, "hide": true})
	await _wait(1.2)
	await _shot("demo_video_full.png")

	# 右：小窗视频 + 压在 UI 之上
	_send({"op": "video", "id": "motion", "layer": "ui",
		"at": "1120,600", "size": "720,405",
		"fade": 0.0, "volume": 1.0, "speed": 0.25, "buffer": 120,
		"loop": true, "wait": false, "hide": true})
	await _wait(1.2)
	await _shot("demo_video_window.png")

	(_main.get("video") as VideoScreen).clear()
	VideoScreen.video_root_override = ""
	print("[demo] 完成")
	get_tree().quit(0)


func _send(cmd: Dictionary) -> void:
	_main.call("_on_stage_command", cmd)


func _shot(fname: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://" + fname)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
