class_name Stage
extends Control

## 演出层
##
## 负责所有「看得见」的舞台元素：背景、立绘、转场。
## 全部用 Tween 驱动，且每一路动画都保存了 Tween 引用，
## 新指令到来时会先 kill 掉旧动画 —— 这是防止快速连点导致
## 立绘卡在半透明状态的关键。
##
## 坐标基于固定设计分辨率 1920x1080（project.godot 里 stretch 模式为
## canvas_items + keep），因此不需要处理多分辨率适配。

const DESIGN := Vector2(1920.0, 1080.0)
const POSITION_RATIOS := {"left": 0.22, "center": 0.5, "right": 0.78}
const CHAR_WIDTH := 560.0
const CHAR_HEIGHT := 1000.0
const CHAR_BOTTOM_OVERHANG := 50.0

## 位移默认用 out_cubic —— 有减速感的移动比线性自然得多，
## 「溜走」这类动作尤其明显（线性看起来像电梯）。
const DEFAULT_EASE := "out_cubic"

var _world: Control
var _bg_root: Control
var _flash_rect: ColorRect
var _bg_a: TextureRect
var _bg_b: TextureRect
var _cg_rect: TextureRect
var _char_root: Control
var _chars: Dictionary = {}
var _bg_id: String = ""
var _cg_id: String = ""
var _weather_id: String = ""
var _bg_tween: Tween
var _cg_tween: Tween
var _world_tween: Tween
var _flash_tween: Tween
var _bg_motion_tween: Tween
var _weather: GPUParticles2D
var _transition_shader: Shader
var _expr_shader: Shader


func _ready() -> void:
	# 注意：Stage 节点在 main.tscn 里是 full-rect 锚点，尺寸由布局系统接管，
	# 这里不要再设 size / position，否则会被 _ready() 之后的布局覆盖并报警告。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_transition_shader = load("res://shaders/transition.gdshader") as Shader
	_expr_shader = load("res://shaders/char_expr.gdshader") as Shader

	# World 是所有舞台元素的共同父节点。
	# 震它 = 震整个画面，而不用去动 Stage 自己（Stage 是锚点节点，position 会被布局覆盖）。
	_world = Control.new()
	_world.name = "World"
	_world.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world.size = DESIGN
	_world.position = Vector2.ZERO
	add_child(_world)

	# BgRoot 包住两层背景，背景运镜作用在它身上 ——
	# 转场时两层背景在交叉，只动其中一层会露馅。
	_bg_root = Control.new()
	_bg_root.name = "BgRoot"
	_bg_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_root.size = DESIGN
	_bg_root.position = Vector2.ZERO
	# 从画面中心缩放，运镜才不会往一边跑
	_bg_root.pivot_offset = DESIGN * 0.5
	_world.add_child(_bg_root)

	_bg_a = _make_bg_rect("BgA", _bg_root)
	_bg_b = _make_bg_rect("BgB", _bg_root)
	_bg_b.modulate.a = 0.0

	_char_root = Control.new()
	_char_root.name = "CharRoot"
	_char_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_char_root.size = DESIGN
	_char_root.position = Vector2.ZERO
	_world.add_child(_char_root)

	# CG 层最后加，保证盖在背景与立绘之上
	_cg_rect = _make_bg_rect("CgRect", _world)
	_cg_rect.visible = false
	_cg_rect.modulate.a = 0.0

	# 闪光层：加在 World 之后，所以盖在整个画面之上
	_flash_rect = ColorRect.new()
	_flash_rect.name = "Flash"
	_flash_rect.color = Color(1.0, 1.0, 1.0, 0.0)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_rect.position = Vector2.ZERO
	_flash_rect.size = DESIGN
	add_child(_flash_rect)


# ---------------------------------------------------------------------------
# 缓动
# ---------------------------------------------------------------------------

## 把名字映射到 Tween 的 trans/ease 组合。未识别的名字回退到 DEFAULT_EASE。
static func apply_ease(tween: Tween, ease_name: String = DEFAULT_EASE) -> Tween:
	match ease_name:
		"linear":
			tween.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
		"in_quad":
			tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		"out_quad":
			tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		"in_cubic":
			tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		"out_cubic":
			tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		"in_out_cubic":
			tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		"in_quart":
			tween.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)
		"out_quart":
			tween.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		"out_back":
			tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		"out_elastic":
			tween.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
		"out_bounce":
			tween.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
		_:
			tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	return tween


static func known_eases() -> PackedStringArray:
	return PackedStringArray([
		"linear", "in_quad", "out_quad", "in_cubic", "out_cubic", "in_out_cubic",
		"in_quart", "out_quart", "out_back", "out_elastic", "out_bounce",
	])


# ---------------------------------------------------------------------------
# CG（全屏事件图）
# ---------------------------------------------------------------------------

func show_cg(id: String, fade: float = 0.5, transition: String = "fade") -> void:
	if id.is_empty():
		return
	_cg_id = id
	_cg_rect.texture = PlaceholderAssets.get_cg(id)
	_kill_cg_tween()

	if fade <= 0.0:
		_cg_rect.visible = true
		_cg_rect.modulate.a = 1.0
		return

	if not _cg_rect.visible:
		_cg_rect.visible = true
		var mode := transition_mode(transition)
		if mode < 0:
			_cg_rect.modulate.a = 0.0
			_cg_tween = create_tween()
			_cg_tween.tween_property(_cg_rect, "modulate:a", 1.0, fade)
		else:
			_cg_rect.modulate.a = 1.0
			_cg_tween = _run_mask_transition(_cg_rect, mode, fade)


func hide_cg(fade: float = 0.4, transition: String = "fade") -> void:
	if not _cg_rect.visible:
		_cg_id = ""
		return
	_cg_id = ""
	_kill_cg_tween()

	if fade <= 0.0:
		_cg_rect.visible = false
		_cg_rect.modulate.a = 0.0
		return

	# 退出时遮罩要反向走：progress 从 1 推回 0
	var mode := transition_mode(transition)
	if mode < 0:
		_cg_tween = create_tween()
		_cg_tween.tween_property(_cg_rect, "modulate:a", 0.0, fade)
	else:
		var mat := _transition_material(_cg_rect)
		if mat != null:
			mat.set_shader_parameter("mode", mode)
			mat.set_shader_parameter("progress", 1.0)
			_cg_tween = create_tween()
			_cg_tween.tween_method(
				func(value: float) -> void: mat.set_shader_parameter("progress", value),
				1.0, 0.0, fade)
		else:
			_cg_tween = create_tween()
			_cg_tween.tween_property(_cg_rect, "modulate:a", 0.0, fade)
	_cg_tween.tween_callback(func() -> void: _cg_rect.visible = false)


func get_cg_id() -> String:
	return _cg_id


func _kill_cg_tween() -> void:
	if _cg_tween != null and _cg_tween.is_valid():
		_cg_tween.kill()
	_cg_tween = null


# ---------------------------------------------------------------------------
# 转场遮罩
# ---------------------------------------------------------------------------

## 转场名 → shader 模式。返回 -1 表示「不用遮罩，走普通的 alpha 淡入」。
##
## 为什么要 shader：fade 只是两张图交叉透明度，做不出「溶解」「擦除」这类
## 有形状的过渡。shader 遮罩把 progress 从 0 推到 1，上层图按不同图案显现。
static func transition_mode(name: String) -> int:
	match name:
		"dissolve":
			return 0
		"wipe":
			return 1
		"blinds":
			return 2
		"circle":
			return 3
	return -1


static func transition_names() -> PackedStringArray:
	return PackedStringArray(["fade", "dissolve", "wipe", "blinds", "circle", "none"])


func _transition_material(node: CanvasItem) -> ShaderMaterial:
	if _transition_shader == null:
		return null
	var mat := node.material as ShaderMaterial
	if mat == null or mat.shader != _transition_shader:
		mat = ShaderMaterial.new()
		mat.shader = _transition_shader
		node.material = mat
	return mat


## 把 node 的遮罩 progress 从 0 推到 1。
## 返回 Tween，调用方负责保存引用以便打断。
func _run_mask_transition(node: CanvasItem, mode: int, duration: float) -> Tween:
	var mat := _transition_material(node)
	if mat == null:
		return null
	mat.set_shader_parameter("mode", mode)
	mat.set_shader_parameter("progress", 0.0)
	var tw := create_tween()
	tw.tween_method(
		func(value: float) -> void: mat.set_shader_parameter("progress", value),
		0.0, 1.0, duration)
	return tw


# ---------------------------------------------------------------------------
# 背景
# ---------------------------------------------------------------------------

func set_bg(id: String, transition: String = "fade", duration: float = 0.4) -> void:
	if id == _bg_id and _bg_a.texture != null:
		return
	_bg_id = id
	var tex := PlaceholderAssets.get_bg(id)
	_kill_bg_tween()

	if transition == "none" or duration <= 0.0 or _bg_a.texture == null:
		_bg_a.texture = tex
		_bg_a.modulate.a = 1.0
		_bg_b.modulate.a = 0.0
		return

	_bg_b.texture = tex
	var mode := transition_mode(transition)
	if mode < 0:
		# fade：两层交叉淡入
		_bg_b.modulate.a = 0.0
		_bg_tween = create_tween()
		_bg_tween.tween_property(_bg_b, "modulate:a", 1.0, duration)
	else:
		# 遮罩转场：alpha 直接给满，显现与否交给 shader 的 mask
		_bg_b.modulate.a = 1.0
		_bg_tween = _run_mask_transition(_bg_b, mode, duration)
		if _bg_tween == null:
			_bg_b.modulate.a = 1.0
			_commit_bg()
			return
	_bg_tween.tween_callback(_commit_bg)


func _commit_bg() -> void:
	_bg_a.texture = _bg_b.texture
	_bg_a.modulate.a = 1.0
	_bg_b.modulate.a = 0.0


func get_bg_id() -> String:
	return _bg_id


## 供自动化测试 / 调试使用：取某个立绘当前的横坐标
func get_char_x(char_id: String) -> float:
	if not _chars.has(char_id):
		return -1.0
	return (_chars[char_id]["rect"] as TextureRect).position.x


## 某个位置关键字对应的横坐标（未减去半个身位）
static func anchor_x(at: String) -> float:
	return DESIGN.x * float(POSITION_RATIOS.get(at, 0.5))


# ---------------------------------------------------------------------------
# 立绘
# ---------------------------------------------------------------------------

## 入场 / 出场方式的位移起点。返回 ZERO 表示走普通的淡入淡出。
##
## slide_left  = 从屏幕左侧外滑进来
## slide_right = 从屏幕右侧外滑进来
## slide_up    = 从画面下方滑进来
static func _entry_offset(transition: String) -> Vector2:
	match transition:
		"slide_left":
			return Vector2(-CHAR_WIDTH, 0.0)
		"slide_right":
			return Vector2(DESIGN.x, 0.0)
		"slide_up":
			return Vector2(0.0, DESIGN.y)
	return Vector2.ZERO


static func is_slide(transition: String) -> bool:
	return not _entry_offset(transition).is_zero_approx()


func show_char(char_id: String, expr: String = "normal", at: String = "center",
		transition: String = "fade", duration: float = 0.3) -> void:
	if char_id.is_empty():
		return
	var entry := _ensure_char(char_id)
	var rect := entry["rect"] as TextureRect
	var was_visible := bool(entry["visible"])

	rect.texture = PlaceholderAssets.get_char(char_id, expr)
	entry["expr"] = expr
	entry["at"] = at
	entry["visible"] = true

	var target := _char_position(at)
	_kill_char_tween(entry)

	if transition == "none" or duration <= 0.0:
		rect.visible = true
		rect.position = target
		rect.modulate.a = 1.0
		return

	rect.visible = true
	var offset := _entry_offset(transition)
	if offset.is_zero_approx():
		if not was_visible:
			rect.modulate.a = 0.0
	else:
		# 滑入时 alpha 直接给满。边滑边淡入会显得拖泥带水，
		# 而且起点在屏幕外，玩家本来就看不到「突然出现」。
		rect.position = target + offset
		rect.modulate.a = 1.0

	var tw := create_tween()
	tw.set_parallel(true)
	if offset.is_zero_approx():
		tw.tween_property(rect, "modulate:a", 1.0, duration)
	tw.tween_property(rect, "position", target, duration).set_trans(
		Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	entry["tween"] = tw


func hide_char(char_id: String, transition: String = "fade", duration: float = 0.3) -> void:
	if not _chars.has(char_id):
		return
	var entry: Dictionary = _chars[char_id]
	var rect := entry["rect"] as TextureRect
	entry["visible"] = false
	_kill_char_tween(entry)

	# 角色离场后状态归零 —— 否则放大过 / 压暗过的角色再次出场还是那个样子
	var reset := func() -> void:
		rect.visible = false
		rect.scale = Vector2.ONE
		rect.modulate = Color.WHITE
		rect.modulate.a = 0.0
		entry["scale"] = 1.0

	if transition == "none" or duration <= 0.0:
		reset.call()
		return

	var offset := _entry_offset(transition)
	var tw := create_tween()
	if offset.is_zero_approx():
		tw.tween_property(rect, "modulate:a", 0.0, duration)
	else:
		# 滑出：朝屏幕外滑走，alpha 保持不透明，出画后再隐藏
		tw.tween_property(rect, "position",
			_char_position(String(entry["at"])) + offset, duration).set_trans(
			Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_callback(reset)
	entry["tween"] = tw


## 让说话人保持明亮、其他人压暗 —— 多立绘同框时的基本礼仪。
##
## 传空字符串（旁白）时所有人恢复明亮。
## 只改 modulate 的 rgb，不动 alpha —— alpha 归淡入淡出管，两者不能互相踩。
func focus_speaker(speaker: String, dim: float = -1.0, duration: float = -1.0) -> void:
	if _chars.is_empty():
		return
	var target_dim := dim if dim >= 0.0 else UiTheme.stage_value("dim_inactive", 0.55)
	var fade := duration if duration >= 0.0 else UiTheme.stage_value("dim_duration", 0.22)

	for char_id in _chars.keys():
		var entry: Dictionary = _chars[char_id]
		if not bool(entry["visible"]):
			continue
		var rect := entry["rect"] as TextureRect
		var is_speaker := String(char_id) == speaker
		# 旁白时不做区分，全部保持明亮
		var level := 1.0 if (is_speaker or speaker.is_empty()) else target_dim

		var old := entry.get("dim_tween") as Tween
		if old != null and old.is_valid():
			old.kill()
		if fade <= 0.0:
			rect.modulate.r = level
			rect.modulate.g = level
			rect.modulate.b = level
			continue
		var tw := create_tween().set_parallel(true)
		tw.tween_property(rect, "modulate:r", level, fade)
		tw.tween_property(rect, "modulate:g", level, fade)
		tw.tween_property(rect, "modulate:b", level, fade)
		entry["dim_tween"] = tw


## 供自动化测试 / 调试使用：取某个立绘当前的亮度（1.0 = 未被压暗）
func get_char_brightness(char_id: String) -> float:
	if not _chars.has(char_id):
		return -1.0
	return (_chars[char_id]["rect"] as TextureRect).modulate.r


## 供自动化测试 / 调试使用：某个立绘当前是否可见
func is_char_visible(char_id: String) -> bool:
	if not _chars.has(char_id):
		return false
	return (_chars[char_id]["rect"] as TextureRect).visible


func move_char(char_id: String, at: String, duration: float = 0.35,
		ease_name: String = DEFAULT_EASE) -> void:
	if not _chars.has(char_id):
		return
	var entry: Dictionary = _chars[char_id]
	var rect := entry["rect"] as TextureRect
	entry["at"] = at
	_kill_char_tween(entry)

	var target := _char_position(at)
	if duration <= 0.0:
		rect.position = target
		return
	var tw := create_tween()
	apply_ease(tw, ease_name)
	tw.tween_property(rect, "position", target, duration)
	entry["tween"] = tw


# ---------------------------------------------------------------------------
# 立绘动效
# ---------------------------------------------------------------------------

## 兴奋小跳。上升段用 EASE_OUT（减速）、下落段用 EASE_IN（加速）——
## 这正是抛物线的物理感；用 linear 会像坐电梯。
func char_jump(char_id: String, height: float = 40.0, times: int = 2,
		duration: float = 0.7) -> void:
	if not _chars.has(char_id):
		return
	var entry: Dictionary = _chars[char_id]
	var rect := entry["rect"] as TextureRect
	_kill_char_tween(entry)

	# 从基准位起跳，避免上一次动画被打断后停在半空
	var base := _char_position(String(entry["at"]))
	rect.position = base
	if duration <= 0.0 or times <= 0:
		return

	var leg := maxf(0.05, duration / float(times * 2))
	var tw := create_tween()
	for i in times:
		tw.tween_property(rect, "position:y", base.y - height, leg) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(rect, "position:y", base.y, leg) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	entry["tween"] = tw


## 靠近 / 远离（缩放）。倍数 > 1 放大（靠近），< 1 缩小（后退）。
func char_zoom(char_id: String, scale_factor: float, duration: float = 0.4,
		ease_name: String = "out_back") -> void:
	if not _chars.has(char_id):
		return
	var entry: Dictionary = _chars[char_id]
	var rect := entry["rect"] as TextureRect
	_kill_char_tween(entry)

	entry["scale"] = maxf(0.05, scale_factor)
	var target := Vector2.ONE * float(entry["scale"])
	if duration <= 0.0:
		rect.scale = target
		return
	var tw := create_tween()
	apply_ease(tw, ease_name)
	tw.tween_property(rect, "scale", target, duration)
	entry["tween"] = tw


## 抖动。幅度逐次衰减，收尾自然，最后必定回到原位。
func char_shake(char_id: String, strength: float = 28.0, times: int = 5,
		duration: float = 0.45) -> void:
	if not _chars.has(char_id):
		return
	var entry: Dictionary = _chars[char_id]
	var rect := entry["rect"] as TextureRect
	_kill_char_tween(entry)

	var base := _char_position(String(entry["at"]))
	rect.position = base
	if duration <= 0.0 or times <= 0:
		return

	var step := maxf(0.02, duration / float(times))
	var tw := create_tween()
	for i in times:
		var decay := 1.0 - float(i) / float(times)
		tw.tween_property(rect, "position", base + shake_offset(strength * decay),
			step).set_trans(Tween.TRANS_SINE)
	tw.tween_property(rect, "position", base, step).set_trans(Tween.TRANS_SINE)
	entry["tween"] = tw


## 生成一个抖动偏移。
##
## 用极坐标而不是「各轴独立随机」—— 后者经常抽出接近零的向量（两个分量
## 恰好都很小），看起来就像根本没动。极坐标保证幅度始终在 65%~100% 之间，
## 只是方向随机。
static func shake_offset(magnitude: float) -> Vector2:
	var angle := randf() * TAU
	var scaled := magnitude * randf_range(0.65, 1.0)
	# 纵向压到 55%：横向抖动更像「哆嗦」，纯随机方向会显得乱甩
	return Vector2(cos(angle), sin(angle) * 0.55) * scaled


# ---------------------------------------------------------------------------
# 画面动效
# ---------------------------------------------------------------------------

## 全屏震动 —— 「吓一跳」用。震的是 World，所以背景 / 立绘 / CG 一起动。
##
## 注意：只靠这个是不够的。背景是铺满画面的渐变，整体平移没有参照物，
## 玩家看不出在动。真正让震动「可见」的是 main.gd 里同时震 UI 层
## （对话框 / HUD 跟着抖）。
func screen_shake(strength: float = 36.0, times: int = 5, duration: float = 0.45) -> void:
	if _world == null:
		return
	_kill_world_tween()
	_world.position = Vector2.ZERO
	if duration <= 0.0 or times <= 0:
		return

	var step := maxf(0.02, duration / float(times))
	var tw := create_tween()
	for i in times:
		var decay := 1.0 - float(i) / float(times)
		tw.tween_property(_world, "position", shake_offset(strength * decay),
			step).set_trans(Tween.TRANS_SINE)
	tw.tween_property(_world, "position", Vector2.ZERO, step).set_trans(Tween.TRANS_SINE)
	_world_tween = tw


## 全屏闪光。颜色 alpha 从给定值淡到 0。
func screen_flash(color: Color = Color.WHITE, duration: float = 0.25) -> void:
	if _flash_rect == null:
		return
	_kill_flash_tween()
	var peak := color.a if color.a > 0.0 else 1.0
	if duration <= 0.0:
		_flash_rect.color = Color(color.r, color.g, color.b, 0.0)
		return
	_flash_rect.color = Color(color.r, color.g, color.b, peak)
	_flash_tween = create_tween()
	_flash_tween.tween_property(_flash_rect, "color:a", 0.0, duration)


func set_expr(char_id: String, expr: String, duration: float = 0.0) -> void:
	if not _chars.has(char_id):
		return
	var entry: Dictionary = _chars[char_id]
	if String(entry["expr"]) == expr:
		return
	var rect := entry["rect"] as TextureRect
	var next_tex := PlaceholderAssets.get_char(char_id, expr)

	# 硬切换：没指定时长、或者本来就没图
	if duration <= 0.0 or rect.texture == null or _expr_shader == null:
		rect.texture = next_tex
		entry["expr"] = expr
		return

	# 交叉混合：把「当前这张」塞进 from_tex，节点自己的 texture 换成新图，
	# 再让 shader 的 progress 从 0 推到 1。这样不用额外的叠层节点，
	# 也不会因为缩放 / 位移导致两层错位。
	var mat := rect.material as ShaderMaterial
	if mat == null or mat.shader != _expr_shader:
		mat = ShaderMaterial.new()
		mat.shader = _expr_shader
		rect.material = mat
	mat.set_shader_parameter("from_tex", rect.texture)
	mat.set_shader_parameter("has_from", true)
	mat.set_shader_parameter("progress", 0.0)
	rect.texture = next_tex
	entry["expr"] = expr

	var old := entry.get("expr_tween") as Tween
	if old != null and old.is_valid():
		old.kill()
	var tw := create_tween()
	tw.tween_method(
		func(value: float) -> void: mat.set_shader_parameter("progress", value),
		0.0, 1.0, duration)
	tw.tween_callback(func() -> void: mat.set_shader_parameter("has_from", false))
	entry["expr_tween"] = tw


# ---------------------------------------------------------------------------
# 背景运镜（Ken Burns）
# ---------------------------------------------------------------------------

## 缓慢缩放 / 平移背景。静止不动的背景看久了很闷，
## 让镜头一直有一点点动，画面就「活」了。
##
## 作用于 BgRoot 而不是单个背景层 —— 转场时有两层背景在交叉，
## 只动其中一层会露馅。
func bg_motion(scale_to: float = 1.0, offset_to: Vector2 = Vector2.ZERO,
		duration: float = 6.0, ease_name: String = "in_out_cubic") -> void:
	if _bg_root == null:
		return
	var target_scale := maxf(0.2, scale_to)
	var old := _bg_motion_tween
	if old != null and old.is_valid():
		old.kill()
	if duration <= 0.0:
		_bg_root.scale = Vector2.ONE * target_scale
		_bg_root.position = offset_to
		return
	var tw := create_tween()
	tw.set_parallel(true)
	apply_ease(tw, ease_name)
	tw.tween_property(_bg_root, "scale", Vector2.ONE * target_scale, duration)
	tw.tween_property(_bg_root, "position", offset_to, duration)
	_bg_motion_tween = tw


func stop_bg_motion() -> void:
	if _bg_motion_tween != null and _bg_motion_tween.is_valid():
		_bg_motion_tween.kill()
	_bg_motion_tween = null
	if _bg_root != null:
		_bg_root.scale = Vector2.ONE
		_bg_root.position = Vector2.ZERO


# ---------------------------------------------------------------------------
# 天气
# ---------------------------------------------------------------------------

## 切换天气。kind 取 "none" / "rain" / "snow" / "sakura"。
##
## 粒子用一个常驻的 GPUParticles2D，切换时只改贴图和参数，不反复建节点。
## 发射器放在画面正上方，靠重力往下落。
func set_weather(kind: String, intensity: float = 1.0) -> void:
	# 先判合法性再建节点 —— 未知类型要干净地降级成「无天气」，
	# 而不是留着个无效的 _weather_id 让人以为天气开着
	var valid := kind == "rain" or kind == "snow" or kind == "sakura"
	_weather_id = kind if valid else ""

	if _weather == null:
		_weather = GPUParticles2D.new()
		_weather.name = "Weather"
		_weather.emitting = false
		_weather.local_coords = false
		_world.add_child(_weather)
		# 天气盖在背景 / 立绘 / CG 之上
		_world.move_child(_weather, -1)

	if not valid:
		_weather.emitting = false
		return

	var amount := 0
	var velocity := 0.0
	var spread := 0.0
	var gravity := Vector3.ZERO
	var scale_range := Vector2.ONE
	var color := Color.WHITE
	var lifetime := 1.0

	match kind:
		"rain":
			amount = int(1200.0 * intensity)
			velocity = 1250.0
			spread = 3.0
			gravity = Vector3(0.0, 420.0, 0.0)
			scale_range = Vector2(0.7, 1.1)
			color = Color(0.80, 0.88, 1.0, 0.55)
			lifetime = 1.2
		"snow":
			# 粒子数按「一屏能看到多少」定：240 个铺在 1920×1080 上只有几十个入镜，
			# 看着像掉帧漏粒子；800 才像下雪
			amount = int(800.0 * intensity)
			velocity = 90.0
			spread = 35.0
			gravity = Vector3(0.0, 26.0, 0.0)
			scale_range = Vector2(0.5, 1.3)
			color = Color(1.0, 1.0, 1.0, 0.85)
			lifetime = 9.0
		_:  # sakura
			amount = int(420.0 * intensity)
			velocity = 70.0
			spread = 45.0
			gravity = Vector3(0.0, 18.0, 0.0)
			scale_range = Vector2(0.8, 1.6)
			color = Color(1.0, 0.86, 0.90, 0.95)
			lifetime = 11.0

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(DESIGN.x * 0.6, 8.0, 0.0)
	mat.direction = Vector3(0.0, 1.0, 0.0)
	mat.spread = spread
	mat.initial_velocity_min = velocity * 0.85
	mat.initial_velocity_max = velocity * 1.15
	mat.gravity = gravity
	# 雪花 / 花瓣左右飘，雨丝几乎不晃
	mat.angular_velocity_min = -60.0 if kind != "rain" else 0.0
	mat.angular_velocity_max = 60.0 if kind != "rain" else 0.0
	mat.scale_min = scale_range.x
	mat.scale_max = scale_range.y
	mat.color = color

	_weather.texture = PlaceholderAssets.get_weather_particle(kind)
	_weather.process_material = mat
	_weather.amount = maxi(1, amount)
	_weather.lifetime = lifetime
	_weather.preprocess = lifetime * 0.6   # 切换瞬间就铺满屏，而不是慢慢落下来
	_weather.position = Vector2(DESIGN.x * 0.5, -40.0)
	_weather.emitting = true


func get_weather() -> String:
	return _weather_id


## 供自动化测试 / 调试使用：取背景运镜当前状态
func get_bg_motion() -> Dictionary:
	if _bg_root == null:
		return {"scale": 1.0, "position": Vector2.ZERO}
	return {"scale": _bg_root.scale.x, "position": _bg_root.position}


## 供自动化测试 / 调试使用：表情过渡是否正在进行
func is_expr_transitioning(char_id: String) -> bool:
	if not _chars.has(char_id):
		return false
	var tw := _chars[char_id].get("expr_tween") as Tween
	return tw != null and tw.is_valid() and tw.is_running()


func clear() -> void:
	# 动效状态也要复位 —— 否则读档 / 重播后会残留画面偏移和立绘缩放
	_kill_world_tween()
	if _world != null:
		_world.position = Vector2.ZERO
	_kill_flash_tween()
	if _flash_rect != null:
		_flash_rect.color.a = 0.0
	stop_bg_motion()
	set_weather("none")

	for char_id in _chars.keys():
		var entry: Dictionary = _chars[char_id]
		_kill_char_tween(entry)
		var dim_tween := entry.get("dim_tween") as Tween
		if dim_tween != null and dim_tween.is_valid():
			dim_tween.kill()
		var rect := entry["rect"] as TextureRect
		rect.visible = false
		rect.scale = Vector2.ONE
		rect.modulate = Color.WHITE
		rect.modulate.a = 0.0
		entry["visible"] = false
		entry["scale"] = 1.0
	_bg_id = ""
	_bg_a.texture = null
	_bg_b.texture = null
	_bg_b.modulate.a = 0.0
	_kill_cg_tween()
	_cg_id = ""
	_cg_rect.texture = null
	_cg_rect.visible = false
	_cg_rect.modulate.a = 0.0


# ---------------------------------------------------------------------------
# 存档支持
# ---------------------------------------------------------------------------

func get_state() -> Dictionary:
	var chars: Array = []
	for char_id in _chars.keys():
		var entry: Dictionary = _chars[char_id]
		if not bool(entry["visible"]):
			continue
		chars.append({
			"char": String(char_id),
			"expr": String(entry["expr"]),
			"at": String(entry["at"]),
		})
	return {"bg": _bg_id, "cg": _cg_id, "chars": chars, "weather": _weather_id}


func restore_state(data: Dictionary) -> void:
	clear()
	var bg := String(data.get("bg", ""))
	if not bg.is_empty():
		set_bg(bg, "none", 0.0)
	var cg := String(data.get("cg", ""))
	if not cg.is_empty():
		show_cg(cg, 0.0)
	for item in data.get("chars", []):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		show_char(
			String((item as Dictionary).get("char", "")),
			String((item as Dictionary).get("expr", "normal")),
			String((item as Dictionary).get("at", "center")),
			"none", 0.0)
	# 天气：clear() 会先把它关掉，这里再按存档还原。
	# 老存档没有这个字段 → 空串 → 保持无天气；强度不存，回滚不追求逐帧一致。
	var weather := String(data.get("weather", ""))
	if not weather.is_empty():
		set_weather(weather, 1.0)


# ---------------------------------------------------------------------------
# 内部
# ---------------------------------------------------------------------------

func _make_bg_rect(node_name: String, parent: Control) -> TextureRect:
	var rect := TextureRect.new()
	rect.name = node_name
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.position = Vector2.ZERO
	rect.size = DESIGN
	parent.add_child(rect)
	return rect


func _ensure_char(char_id: String) -> Dictionary:
	if _chars.has(char_id):
		return _chars[char_id] as Dictionary
	var rect := TextureRect.new()
	rect.name = "Char_" + char_id
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.size = Vector2(CHAR_WIDTH, CHAR_HEIGHT)
	# pivot 放在脚底中心：放大时脚不动、往上长，这才是「靠近」的感觉。
	# 放在左上角的话，放大会整体往右下漂。
	rect.pivot_offset = Vector2(CHAR_WIDTH * 0.5, CHAR_HEIGHT)
	rect.position = _char_position("center")
	rect.visible = false
	rect.modulate.a = 0.0
	_char_root.add_child(rect)

	var entry := {
		"rect": rect,
		"expr": "normal",
		"at": "center",
		"visible": false,
		"tween": null,
		"scale": 1.0,
	}
	_chars[char_id] = entry
	return entry


func _char_position(at: String) -> Vector2:
	var ratio := float(POSITION_RATIOS.get(at, 0.5))
	return Vector2(
		DESIGN.x * ratio - CHAR_WIDTH * 0.5,
		DESIGN.y - CHAR_HEIGHT + CHAR_BOTTOM_OVERHANG)


func _kill_char_tween(entry: Dictionary) -> void:
	var tw := entry.get("tween") as Tween
	if tw != null and tw.is_valid():
		tw.kill()
	entry["tween"] = null


func _kill_bg_tween() -> void:
	if _bg_tween != null and _bg_tween.is_valid():
		_bg_tween.kill()


func _kill_world_tween() -> void:
	if _world_tween != null and _world_tween.is_valid():
		_world_tween.kill()
	_world_tween = null


func _kill_flash_tween() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = null


## 供自动化测试 / 调试使用：取当前画面偏移（震动时非零）
func get_world_offset() -> Vector2:
	return Vector2.ZERO if _world == null else _world.position


## 供自动化测试 / 调试使用：取某个立绘当前的缩放倍数
func get_char_scale(char_id: String) -> float:
	if not _chars.has(char_id):
		return -1.0
	return (_chars[char_id]["rect"] as TextureRect).scale.x


## 供自动化测试 / 调试使用：取闪光层当前 alpha
func get_flash_alpha() -> float:
	return 0.0 if _flash_rect == null else _flash_rect.color.a


## 供自动化测试 / 调试使用：取某个立绘当前坐标
func get_char_position(char_id: String) -> Vector2:
	if not _chars.has(char_id):
		return Vector2(-1.0, -1.0)
	return (_chars[char_id]["rect"] as TextureRect).position
