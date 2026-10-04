extends Node

## 立绘材质语义实验（需要非 headless 运行）
##
##   Godot --path . res://tools/char_shader_probe.tscn
##
## 目的：确认「自定义 canvas_item 着色器给 COLOR 赋值之后，节点 modulate 还生不生效」。
##
## 为什么必须量渲染像素：modulate 改的是节点属性，逻辑测试读属性永远读得到 0.55，
## 一路全绿；但 shader 若把进来的顶点色丢掉，画面根本不变暗。这类问题只有逐像素
## 量渲染色才看得见。
##
## 背景：`focus_speaker()`（非说话人压暗）与淡入淡出都靠 modulate。一旦表情材质
## （char_expr）把它丢掉，就会出现「换过表情的角色之后再也不变暗」——正是女主
## 只在最初两句会被压暗的原因。

const SPRITE := "res://assets/sprites/alice/normal.png"
const RECT_SIZE := Vector2(400.0, 900.0)
const SAMPLE_BOX := Rect2i(60, 60, 280, 700)
## 与 ui_theme.json 的 stage.dim_inactive 一致
const DIM := 0.55

const VARIANTS := {
	"无材质": "",
	"COLOR = texture": "shader_type canvas_item;\nvoid fragment(){ COLOR = texture(TEXTURE, UV); }\n",
	"COLOR = tex * COLOR": "shader_type canvas_item;\nvoid fragment(){ COLOR = texture(TEXTURE, UV) * COLOR; }\n",
	"顶点色 varying": "shader_type canvas_item;\nvarying flat vec4 vcol;\nvoid vertex(){ vcol = COLOR; }\nvoid fragment(){ COLOR = texture(TEXTURE, UV) * vcol; }\n",
	"项目 char_expr": "FILE",
}

var _layer: CanvasLayer
var _results: Dictionary = {}


func _ready() -> void:
	await _wait(0.3)
	_layer = CanvasLayer.new()
	_layer.layer = 5
	get_tree().root.add_child(_layer)

	print("[probe] 立绘区平均亮度（1920×1080 设计坐标下的固定采样框）")
	print("[probe] %-22s %8s %8s %10s" % ["变体", "mod=1.0", "mod=0.55", "压暗比"])

	for label in VARIANTS.keys():
		var full := await _measure(String(VARIANTS[label]), 1.0)
		var dim := await _measure(String(VARIANTS[label]), DIM)
		_results[label] = {"full": full, "dim": dim}
		var ratio := dim / maxf(0.0001, full)
		print("[probe] %-22s %8.3f %8.3f %9.2f%s"
			% [label, full, dim, ratio,
				"   ← modulate 生效" if absf(ratio - DIM) < 0.08 else ""])

	_verdict()
	get_tree().quit(0)


## 量一种写法在一个 modulate 下的平均亮度。每次都用新节点，避免材质残留。
func _measure(code: String, mod_value: float) -> float:
	var rect := TextureRect.new()
	rect.texture = load(SPRITE)
	rect.size = RECT_SIZE
	rect.position = Vector2.ZERO
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.modulate = Color(mod_value, mod_value, mod_value, 1.0)

	if code == "FILE":
		var m := ShaderMaterial.new()
		m.shader = load("res://shaders/char_expr.gdshader")
		m.set_shader_parameter("has_from", false)
		m.set_shader_parameter("progress", 1.0)
		rect.material = m
	elif not code.is_empty():
		var s := Shader.new()
		s.code = code
		var m := ShaderMaterial.new()
		m.shader = s
		rect.material = m

	_layer.add_child(rect)
	await _wait(0.25)
	var mean := await _mean_in(SAMPLE_BOX)
	_layer.remove_child(rect)
	rect.queue_free()
	await _wait(0.1)
	return mean


## 把结论打成明确的 PASS / FAIL，而不是留一堆数字让人自己看。
func _verdict() -> void:
	if not _results.has("无材质"):
		return
	var base := float((_results["无材质"] as Dictionary)["full"])
	print("[probe] 基准（无材质、modulate=1.0）= %.3f，压暗到 %.2f 应约为 %.3f"
		% [base, DIM, base * DIM])

	var keepers: Array = []
	for label in _results.keys():
		var full: float = float((_results[label] as Dictionary)["full"])
		var dim: float = float((_results[label] as Dictionary)["dim"])
		var same_color := absf(full - base) < 0.02
		var dims := absf(dim - base * DIM) < 0.03
		if same_color and dims:
			keepers.append(label)
		print("[probe] %-22s 颜色一致=%s 会变暗=%s"
			% [label, "是" if same_color else "否", "是" if dims else "否"])
	print("[probe] 同时满足「颜色不变 + modulate 生效」的写法：%s"
		% ("、".join(keepers) if not keepers.is_empty() else "无"))
	var project_ok: bool = _results.has("项目 char_expr") \
		and absf(float((_results["项目 char_expr"] as Dictionary)["dim"]) - base * DIM) < 0.03
	print("[probe] 结论：项目 char_expr %s"
		% ("保留 modulate（正确）" if project_ok else "丢掉了 modulate（表情材质一挂上，说话人压暗就失效）"))


func _mean_in(box: Rect2i) -> float:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var vp := Vector2(img.get_width(), img.get_height()) / Vector2(1920.0, 1080.0)
	var total := 0.0
	var n := 0
	for y in range(box.position.y, box.position.y + box.size.y, 3):
		for x in range(box.position.x, box.position.x + box.size.x, 3):
			var p := Vector2i(int(x * vp.x), int(y * vp.y))
			if p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c := img.get_pixel(p.x, p.y)
			total += c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			n += 1
	return total / maxf(1.0, float(n))


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
