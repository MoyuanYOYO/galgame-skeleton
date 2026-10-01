extends Node

## 生成「修复前 / 修复后」的对比截图（两处画面变暗问题）
##
##   1. 设置面板背后的压暗遮罩：alpha 0.88（旧） vs 0.55（新）
##   2. 转场中段：* COLOR（旧，把颜色自乘一遍） vs 修好的写法
##
##   Godot --path . res://tools/fix_compare.tscn

const MAIN_SCENE := "res://scenes/main.tscn"
const BG_OLD := "res://assets/bg/classroom.png"
const BG_NEW := "res://assets/bg/rooftop.png"

## 旧版 transition.gdshader 的 COLOR 写法（多乘了一遍进来的 COLOR）
const BUGGY_SHADER := """shader_type canvas_item;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform int mode : hint_range(0, 3) = 0;
uniform float softness : hint_range(0.005, 0.5) = 0.06;
uniform float density : hint_range(2.0, 80.0) = 30.0;
void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float mask = smoothstep(UV.x - softness, UV.x + softness, progress);
	COLOR = vec4(tex.rgb, tex.a * mask) * COLOR;
}
"""

var _main: Control


func _ready() -> void:
	await _wait(0.3)
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(1.0)
	(_main.get("title") as Control).visible = false
	await _wait(0.2)

	await _shots_scrim()
	await _shots_transition()

	print("[cmp] 完成")
	get_tree().quit(0)


func _shots_scrim() -> void:
	var stage: Stage = _main.get("stage") as Stage
	stage.set_bg("classroom", "none", 0.0)
	_main.call("_open_settings")
	await _wait(0.6)
	var dim := (_main.get("settings") as Node).get_node_or_null("Dim") as ColorRect
	if dim == null:
		return
	for item in [["cmp_scrim_before.png", 0.88], ["cmp_scrim_after.png", 0.55]]:
		dim.color = Color(0.031, 0.027, 0.055, float(item[1]))
		await _wait(0.3)
		await _save(String(item[0]))
	_main.call("_close_modals")
	await _wait(0.3)


func _shots_transition() -> void:
	var stage: Stage = _main.get("stage") as Stage
	stage.set_bg("classroom", "none", 0.0)
	await _wait(0.4)

	var bg_b := stage.get_node("World/BgRoot/BgB") as TextureRect
	bg_b.texture = load(BG_NEW)
	bg_b.modulate = Color(1, 1, 1, 1)

	# 旧写法
	var bad := Shader.new()
	bad.code = BUGGY_SHADER
	var m_bad := ShaderMaterial.new()
	m_bad.shader = bad
	m_bad.set_shader_parameter("mode", 1)
	m_bad.set_shader_parameter("softness", 0.06)
	bg_b.material = m_bad
	for item in [["cmp_trans_before.png", 0.45], ["cmp_trans_before2.png", 0.75]]:
		m_bad.set_shader_parameter("progress", float(item[1]))
		await _wait(0.3)
		await _save(String(item[0]))

	# 修好的写法（项目里那份）
	var m_ok := ShaderMaterial.new()
	m_ok.shader = load("res://shaders/transition.gdshader")
	m_ok.set_shader_parameter("mode", 1)
	m_ok.set_shader_parameter("softness", 0.06)
	bg_b.material = m_ok
	for item in [["cmp_trans_after.png", 0.45], ["cmp_trans_after2.png", 0.75]]:
		m_ok.set_shader_parameter("progress", float(item[1]))
		await _wait(0.3)
		await _save(String(item[0]))


func _save(fname: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://" + fname)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
