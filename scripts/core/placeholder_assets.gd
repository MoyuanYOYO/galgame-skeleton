class_name PlaceholderAssets
extends RefCounted

## 程序化占位素材生成器
##
## 骨架阶段 assets/ 目录里没有任何图片。为了让工程「开箱即跑」且
## 一眼能看出是谁在说话，这里在运行时按 id 生成占位贴图：
##   - 背景：按 id 派生的双色渐变
##   - 立绘：按 id 派生的色相 + 简单人形剪影，表情用胸前色块区分
##
## 一旦 assets/bg/<id>.png 或 assets/sprites/<char>.png 存在，
## 就会优先使用真实素材，代码无需任何改动。

const BG_DIR := "res://assets/bg/"
const CG_DIR := "res://assets/cg/"
const SPRITE_DIR := "res://assets/sprites/"
const IMAGE_EXTENSIONS: PackedStringArray = ["png", "jpg", "jpeg", "webp"]

const CHAR_TEX_SIZE := Vector2i(384, 768)
const CG_TEX_SIZE := Vector2i(960, 540)
const CHAR_CACHE_LIMIT := 24

static var _bg_cache: Dictionary = {}
static var _char_cache: Dictionary = {}
static var _cg_cache: Dictionary = {}
static var _weather_cache: Dictionary = {}


# ---------------------------------------------------------------------------
# 天气粒子
# ---------------------------------------------------------------------------

## 天气用的小粒子贴图。尺寸都很小（3×22 ~ 14×10），
## 一屏几百个粒子也不占显存，而且不需要外部素材。
static func get_weather_particle(kind: String) -> Texture2D:
	var key := "weather:" + kind
	if _weather_cache.has(key):
		return _weather_cache[key]
	var tex := _make_weather_texture(kind)
	_weather_cache[key] = tex
	return tex


static func _make_weather_texture(kind: String) -> Texture2D:
	match kind:
		"snow":
			return _make_soft_dot(14, Color(1.0, 1.0, 1.0), 0.95)
		"sakura":
			return _make_petal()
		_:
			return _make_rain_drop()


## 雨丝：一条两端淡出的细长条。不做渐变的话落下来像一根根棍子。
static func _make_rain_drop() -> Texture2D:
	var w := 3
	var h := 22
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in h:
		var t := float(y) / float(h - 1)
		var alpha := sin(t * PI) * 0.75
		for x in w:
			var edge := 1.0 - absf(float(x) - float(w - 1) * 0.5) / (float(w) * 0.5)
			img.set_pixel(x, y, Color(0.78, 0.86, 1.0, alpha * edge))
	return ImageTexture.create_from_image(img)


## 软边圆点：雪花用。中心实、边缘按距离平方衰减。
static func _make_soft_dot(size: int, color: Color, alpha: float) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var center := float(size - 1) * 0.5
	var radius := float(size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(float(x) - center, float(y) - center).length() / radius
			if d >= 1.0:
				continue
			var falloff := (1.0 - d) * (1.0 - d)
			img.set_pixel(x, y, Color(color.r, color.g, color.b, alpha * falloff))
	return ImageTexture.create_from_image(img)


## 花瓣：一个带缺口的椭圆
static func _make_petal() -> Texture2D:
	var w := 14
	var h := 10
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := float(w - 1) * 0.5
	var cy := float(h - 1) * 0.5
	for y in h:
		for x in w:
			var dx := (float(x) - cx) / (float(w) * 0.5)
			var dy := (float(y) - cy) / (float(h) * 0.5)
			var d := dx * dx + dy * dy
			if d > 1.0:
				continue
			var notch := 1.0 - 0.35 * maxf(0.0, -dy)
			img.set_pixel(x, y, Color(1.0, 0.72, 0.82, (1.0 - d) * notch))
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------------
# CG（全屏事件图）
# ---------------------------------------------------------------------------

static func get_cg(id: String) -> Texture2D:
	if id.is_empty():
		id = "void"
	if _cg_cache.has(id):
		return _cg_cache[id] as Texture2D
	var real := _load_real(CG_DIR, id)
	var tex: Texture2D = real if real != null else _make_cg_texture(id)
	_cg_cache[id] = tex
	return tex


static func has_real_cg(id: String) -> bool:
	return _load_real(CG_DIR, id) != null


## 占位 CG：渐变天空 + 一轮日/月 + 地平线，让它读起来像一张「场景图」而不是纯色块
static func _make_cg_texture(id: String) -> Texture2D:
	var w := CG_TEX_SIZE.x
	var h := CG_TEX_SIZE.y
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)

	var hue := hue_of(id)
	var sky_top := Color.from_hsv(hue, 0.45, 0.36)
	var sky_bottom := Color.from_hsv(fposmod(hue + 0.10, 1.0), 0.55, 0.13)
	var horizon := h * 0.72

	# 天空渐变
	var y := 0
	while y < int(horizon):
		var t := float(y) / horizon
		img.fill_rect(Rect2i(0, y, w, 1), sky_top.lerp(sky_bottom, t))
		y += 1

	# 天体：偏心圆
	var disc := Color.from_hsv(fposmod(hue + 0.06, 1.0), 0.28, 0.94)
	var cx := w * 0.68
	var cy := horizon * 0.52
	var radius := w * 0.09
	var dy := -radius
	while dy <= radius:
		var span := sqrt(maxf(0.0, radius * radius - dy * dy))
		img.fill_rect(Rect2i(int(cx - span), int(cy + dy), int(span * 2.0), 1), disc)
		dy += 1.0

	# 地平线与地面
	img.fill_rect(Rect2i(0, int(horizon), w, 3), Color.from_hsv(hue, 0.30, 0.80, 0.85))
	img.fill_rect(Rect2i(0, int(horizon) + 3, w, h - int(horizon) - 3),
		Color.from_hsv(fposmod(hue + 0.02, 1.0), 0.40, 0.09))

	# 地面上的几条横向剪影，制造纵深
	var band := Color.from_hsv(hue, 0.45, 0.05, 0.75)
	var band_y := int(horizon) + int(h * 0.06)
	while band_y < h:
		img.fill_rect(Rect2i(int(w * 0.06), band_y, int(w * 0.88), 2), band)
		band_y += int(h * 0.055)

	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------------
# 背景
# ---------------------------------------------------------------------------

static func get_bg(id: String) -> Texture2D:
	if id.is_empty():
		id = "void"
	if _bg_cache.has(id):
		return _bg_cache[id] as Texture2D
	var real := _load_real(BG_DIR, id)
	var tex: Texture2D = real if real != null else _make_gradient_bg(id)
	_bg_cache[id] = tex
	return tex


static func has_real_bg(id: String) -> bool:
	return _load_real(BG_DIR, id) != null


static func _make_gradient_bg(id: String) -> Texture2D:
	var hue := hue_of(id)
	var top := Color.from_hsv(hue, 0.38, 0.32)
	var bottom := Color.from_hsv(fposmod(hue + 0.09, 1.0), 0.5, 0.11)
	var gradient := Gradient.new()
	gradient.set_color(0, top)
	gradient.set_color(1, bottom)
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 1920
	tex.height = 1080
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.0, 1.0)
	return tex


# ---------------------------------------------------------------------------
# 立绘
# ---------------------------------------------------------------------------

static func get_char(char_id: String, expr: String) -> Texture2D:
	if char_id.is_empty():
		char_id = "unknown"
	if expr.is_empty():
		expr = "normal"
	var real := _load_real(SPRITE_DIR, char_id)
	if real != null:
		return real
	var real_expr := _load_real(SPRITE_DIR + char_id + "/", expr)
	if real_expr != null:
		return real_expr

	var key := "%s/%s" % [char_id, expr]
	if _char_cache.has(key):
		return _char_cache[key] as Texture2D
	if _char_cache.size() >= CHAR_CACHE_LIMIT:
		_char_cache.clear()
	var tex := _make_char_texture(char_id, expr)
	_char_cache[key] = tex
	return tex


static func has_real_char(char_id: String) -> bool:
	return _load_real(SPRITE_DIR, char_id) != null


static func _make_char_texture(char_id: String, expr: String) -> Texture2D:
	var w := CHAR_TEX_SIZE.x
	var h := CHAR_TEX_SIZE.y
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	var hue := hue_of(char_id)
	var body := Color.from_hsv(hue, 0.40, 0.68)
	var trim := Color.from_hsv(fposmod(hue + 0.5, 1.0), 0.45, 0.86)
	var skin := Color.from_hsv(0.08, 0.20, 0.92)

	# 脖子（先画，随后被躯干盖住下半段）
	var neck_top := int(h * 0.30)
	var neck_bottom := int(h * 0.43)
	img.fill_rect(Rect2i(int(w * 0.5 - w * 0.06), neck_top, int(w * 0.12), neck_bottom - neck_top), skin)

	# 躯干：逐扫描线画一个下宽上窄的梯形
	var body_top := int(h * 0.40)
	var body_bottom := h
	var half_top := w * 0.21
	var half_bottom := w * 0.34
	var y := body_top
	while y < body_bottom:
		var t := float(y - body_top) / float(body_bottom - body_top)
		var half := lerpf(half_top, half_bottom, t)
		var x0 := int(w * 0.5 - half)
		img.fill_rect(Rect2i(x0, y, int(half * 2.0), 2), body)
		y += 2

	# 领口
	img.fill_rect(Rect2i(int(w * 0.5 - w * 0.17), body_top, int(w * 0.34), int(h * 0.020)), trim)

	# 表情标记：胸前一块小色带，颜色由 (角色, 表情) 共同决定
	var expr_color := Color.from_hsv(hue_of("%s/%s" % [char_id, expr]), 0.62, 0.95)
	img.fill_rect(Rect2i(int(w * 0.5 - w * 0.10), body_top + int(h * 0.070), int(w * 0.20), int(h * 0.018)), expr_color)

	# 头部：圆形
	var cx := w * 0.5
	var cy := h * 0.235
	var radius := w * 0.275
	var head_y := int(cy - radius)
	while head_y < int(cy + radius):
		var dy := float(head_y) - cy
		var span := sqrt(maxf(0.0, radius * radius - dy * dy))
		img.fill_rect(Rect2i(int(cx - span), head_y, int(span * 2.0), 1), skin)
		head_y += 1

	# 头发：盖住头顶三分之一
	var hair := Color.from_hsv(fposmod(hue + 0.02, 1.0), 0.35, 0.35)
	var hair_y := int(cy - radius)
	while hair_y < int(cy - radius * 0.15):
		var dy2 := float(hair_y) - cy
		var span2 := sqrt(maxf(0.0, radius * radius - dy2 * dy2))
		img.fill_rect(Rect2i(int(cx - span2), hair_y, int(span2 * 2.0), 1), hair)
		hair_y += 1

	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

static func hue_of(key: String) -> float:
	if key.is_empty():
		return 0.0
	return float(absi(key.hash()) % 360) / 360.0


static func _load_real(dir: String, id: String) -> Texture2D:
	if id.is_empty():
		return null
	for ext in IMAGE_EXTENSIONS:
		var path := dir + id + "." + ext
		if ResourceLoader.exists(path):
			var tex := load(path) as Texture2D
			if tex != null:
				return tex
	return null
