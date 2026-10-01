extends Node

## 定点核对：女主「挂表情材质前后」到底有没有变暗
##
## 跑到 alice 的第 1 句和第 3 句，各存一张；第 3 句再额外存一张
## 「临时摘掉材质」的对照图 —— 有材质/无材质两张一样就说明材质无关。
##
##   Godot --path . res://tools/alice_check.tscn

const MAIN_SCENE := "res://scenes/main.tscn"
const ALICE_RECT := Rect2i(230, 130, 384, 560)   # 立绘绘制区（对话框以上）

var _main: Control


func _ready() -> void:
	await _wait(0.3)
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(0.8)
	_main.call("_on_start_requested")
	await _wait(1.5)

	var runner: ScriptRunner = _main.get("runner") as ScriptRunner
	var stage: Stage = _main.get("stage") as Stage
	var last := ""
	var line := 0
	var alice_lines := 0
	var guard := 200
	while guard > 0:
		guard -= 1
		if runner.is_waiting_choice():
			(_main.get("choices") as ChoicePanel).call("_on_pressed", 0)
			await _wait(0.4)
			last = ""
			continue
		_main.call("_on_advance_requested")
		await _wait(0.05)
		var text := String(_main.get("_last_text"))
		if text == last or text.is_empty() or not runner.is_waiting_say():
			continue
		last = text
		line += 1
		var speaker := String(_main.get("_last_speaker"))
		if speaker != "alice":
			continue
		alice_lines += 1
		await _wait(0.6)          # 等淡入 / 压暗 / 交叉混合全部走完
		var rect := stage.get_char_position("alice")
		var mat := stage.get_char_material("alice") as ShaderMaterial
		print("[alice] 第%d次 alice 说话 | modulate=%s | 材质=%s | progress=%s has_from=%s | pos=%s"
			% [alice_lines, _fmt(stage.get_char_brightness("alice")),
				"有" if mat != null else "无",
				"-" if mat == null else str(mat.get_shader_parameter("progress")),
				"-" if mat == null else str(mat.get_shader_parameter("has_from")),
				str(rect)])
		await _save("ac_%d_with.png" % alice_lines)

		if mat != null:
			# 临时摘掉材质再拍一张：两张一样 = 材质没改色
			var saved := rect_node_material(stage)
			rect_node_material_set(stage, null)
			await _wait(0.2)
			await _save("ac_%d_nomat.png" % alice_lines)
			rect_node_material_set(stage, saved)
			await _wait(0.15)

		if alice_lines >= 3:
			break

	print("[alice] 完成")
	get_tree().quit(0)


func rect_node_material(stage: Stage) -> Material:
	return stage.get_char_material("alice")


func rect_node_material_set(stage: Stage, mat: Material) -> void:
	var root := stage.get_node("World/CharRoot")
	var node := root.get_node_or_null("Char_alice") as CanvasItem
	if node != null:
		node.material = mat


func _fmt(v: float) -> String:
	return "%.2f" % v


func _save(fname: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)
	var pos := Vector2(ALICE_RECT.position) * vp
	var size := Vector2(ALICE_RECT.size) * vp
	var r := Rect2i(Vector2i(pos), Vector2i(size))
	var full := Rect2i(Vector2i.ZERO, img.get_size())
	r = r.intersection(full)
	img.get_region(r).save_png("user://" + fname)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
