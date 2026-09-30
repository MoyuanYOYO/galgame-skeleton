class_name UiTheme
extends RefCounted

## 全局界面外观
##
## 所有配色、字体、按钮尺寸与贴图都从 data/ui/ui_theme.json 读，
## 代码里没有写死的视觉常量。缺失的键自动回退到内置默认值。
##
## 三类可替换资源：
##   1. 配色      → palette.*
##   2. 字体      → fonts.*（留空则用 Godot 内置默认字体）
##   3. 按钮贴图  → buttons.<预设>.texture（九宫格），留空则用程序化圆角矩形

const CONFIG_PATH := "res://data/ui/ui_theme.json"

## 挂在按钮上的元数据键，用来避免重复挂音效
const SFX_META := "__ui_theme_sfx"

static var _data: Dictionary = {}

# --- 调色板（reload 时从配置覆盖；这里的初值与 json 默认值一致） ---
static var BG_DEEP: Color = Color(0.078, 0.071, 0.129)
static var PANEL_BG: Color = Color(0.118, 0.106, 0.200)
static var PANEL_BG_SOFT: Color = Color(0.145, 0.130, 0.235)
static var NAME_PLATE: Color = Color(0.208, 0.180, 0.352)
static var BORDER: Color = Color(0.424, 0.388, 0.788)
static var TEXT: Color = Color(0.925, 0.914, 1.0)
static var TEXT_DIM: Color = Color(0.663, 0.639, 0.816)
static var ACCENT: Color = Color(0.498, 0.467, 0.867)
static var ACCENT_BRIGHT: Color = Color(0.604, 0.576, 0.925)
static var SPEAKER: Color = Color(0.945, 0.780, 0.455)
static var DANGER: Color = Color(0.886, 0.427, 0.427)
static var SUCCESS: Color = Color(0.443, 0.784, 0.612)

static var _font_cache: Dictionary = {}


# ---------------------------------------------------------------------------
# 配置加载
# ---------------------------------------------------------------------------

static func _defaults() -> Dictionary:
	return {
		"fonts": {"body": "", "title": "", "dialogue": ""},
		"font_sizes": {
			"title": 78, "subtitle": 24, "heading": 30, "dialogue": 30,
			"speaker": 26, "backlog": 28, "button": 24, "label": 22, "small": 20,
		},
		"palette": {
			"bg_deep": "#141221", "panel_bg": "#1e1b33", "panel_bg_soft": "#252040",
			"name_plate": "#352e5a",
			"border": "#6c63c9", "text": "#ece9ff", "text_dim": "#a9a3d0",
			"accent": "#7f77dd", "accent_bright": "#9a93ec", "speaker": "#f1c774",
			"danger": "#e26d6d", "success": "#71c89c",
		},
		"audio": {
			"click": "ui_click", "hover": "ui_hover",
			"click_volume": 0.7, "hover_volume": 0.3,
		},
		"buttons": {
			"title": {"width": 340, "height": 68, "font_size": 26, "radius": 10,
				"pad_h": 24, "pad_v": 12, "texture": "", "texture_margin": 14},
			"choice": {"width": 760, "height": 68, "font_size": 26, "radius": 10,
				"pad_h": 24, "pad_v": 12, "texture": "", "texture_margin": 14},
			"hud": {"width": 0, "height": 46, "font_size": 20, "radius": 9,
				"pad_h": 20, "pad_v": 10, "texture": "", "texture_margin": 12},
			"track": {"width": 0, "height": 52, "font_size": 20, "radius": 10,
				"pad_h": 22, "pad_v": 12, "texture": "", "texture_margin": 12},
			"default": {"width": 0, "height": 46, "font_size": 22, "radius": 10,
				"pad_h": 24, "pad_v": 12, "texture": "", "texture_margin": 12},
			"small": {"width": 0, "height": 40, "font_size": 20, "radius": 9,
				"pad_h": 20, "pad_v": 10, "texture": "", "texture_margin": 12},
		},
		"panels": {
			"default": {"radius": 16, "border_width": 1},
			"gallery": {"radius": 20, "border_width": 1},
			"viewer": {"radius": 20, "border_width": 1},
		},
		"dialogue": {
			"offset_left": 130, "offset_right": -130,
			"offset_top": -320, "offset_bottom": -70,
			"radius": 18, "border_width": 1,
			"pad_h": 46, "pad_v": 30, "name_pad_h": 24, "name_pad_v": 6,
		},
	}


static func reload() -> void:
	_data = _defaults()
	var raw: Variant = JsonUtil.load_json(CONFIG_PATH)
	if typeof(raw) == TYPE_DICTIONARY:
		JsonUtil.deep_merge(_data, raw as Dictionary)
	else:
		push_warning("[UiTheme] 配置读取失败，使用内置默认值")
	_font_cache.clear()
	_refresh_palette()


static func _ensure() -> void:
	if _data.is_empty():
		reload()

static func _refresh_palette() -> void:
	var pal := section("palette")
	BG_DEEP = _color(pal, "bg_deep", BG_DEEP)
	PANEL_BG = _color(pal, "panel_bg", PANEL_BG)
	PANEL_BG_SOFT = _color(pal, "panel_bg_soft", PANEL_BG_SOFT)
	NAME_PLATE = _color(pal, "name_plate", NAME_PLATE)
	BORDER = _color(pal, "border", BORDER)
	TEXT = _color(pal, "text", TEXT)
	TEXT_DIM = _color(pal, "text_dim", TEXT_DIM)
	ACCENT = _color(pal, "accent", ACCENT)
	ACCENT_BRIGHT = _color(pal, "accent_bright", ACCENT_BRIGHT)
	SPEAKER = _color(pal, "speaker", SPEAKER)
	DANGER = _color(pal, "danger", DANGER)
	SUCCESS = _color(pal, "success", SUCCESS)


static func _color(source: Dictionary, key: String, fallback: Color) -> Color:
	var raw := String(source.get(key, ""))
	if raw.is_empty():
		return fallback
	return Color.from_string(raw, fallback)


static func section(name: String) -> Dictionary:
	_ensure()
	var value: Variant = _data.get(name, {})
	if typeof(value) == TYPE_DICTIONARY:
		return value
	return {}


## 按调色板键取色（"accent" / "text" / "text_dim" / "danger" …）
static func color(key: String, fallback: Color = Color.MAGENTA) -> Color:
	_ensure()
	return _color(section("palette"), key, fallback)


## 取某个分组下的子字典，缺失时回退到该分组的 default
static func _sub_preset(group: String, name: String) -> Dictionary:
	var raw: Variant = section(group).get(name, {})
	if typeof(raw) == TYPE_DICTIONARY:
		return raw
	var fallback: Variant = section(group).get("default", {})
	if typeof(fallback) == TYPE_DICTIONARY:
		return fallback
	return {}


static func number(key: String, fallback: float) -> float:
	_ensure()
	var raw: Variant = section("font_sizes").get(key, null)
	return fallback if raw == null else float(raw)


## 对话框的位置与尺寸（offset 相对底边锚点，单位是设计分辨率像素）
static func dialogue_value(key: String, fallback: float) -> float:
	_ensure()
	var raw: Variant = section("dialogue").get(key, null)
	return fallback if raw == null else float(raw)


## 演出层参数（多立绘同框时的压暗程度等）
static func stage_value(key: String, fallback: float) -> float:
	_ensure()
	var raw: Variant = section("stage").get(key, null)
	return fallback if raw == null else float(raw)


static func preset(name: String) -> Dictionary:
	_ensure()
	var raw: Variant = section("buttons").get(name, {})
	if typeof(raw) == TYPE_DICTIONARY:
		return raw
	push_warning("[UiTheme] 未定义的按钮预设: %s，回退到 default" % name)
	return _sub_preset("buttons", "default")


# ---------------------------------------------------------------------------
# 字体
# ---------------------------------------------------------------------------

## 取配置里的字体资源；未配置或文件不存在时返回 null（= 用 Godot 内置默认字体）
static func font(key: String = "body") -> Font:
	_ensure()
	var path := String(section("fonts").get(key, "")).strip_edges()
	if path.is_empty():
		return null
	if _font_cache.has(path):
		return _font_cache[path] as Font
	if not ResourceLoader.exists(path):
		push_warning("[UiTheme] 字体文件不存在，回退到默认字体: %s" % path)
		_font_cache[path] = null
		return null
	var loaded := load(path) as Font
	if loaded == null:
		push_warning("[UiTheme] 字体加载失败: %s" % path)
	_font_cache[path] = loaded
	return loaded


## 把 body 字体装成全局默认字体。放在启动最早处调用（Autoload 的 _ready）。
## 各处的 add_theme_font_size_override 仍然生效 —— 这里只统一字体族。
static func install_global_font(node: Node) -> void:
	_ensure()
	var body := font("body")
	if body == null:
		return
	var window := node.get_window()
	if window == null:
		return
	if window.theme == null:
		window.theme = Theme.new()
	window.theme.default_font = body


## 给单个控件指定字体（用于标题、对白这类与正文不同的字体）
static func apply_font(node: Control, key: String) -> void:
	var f := font(key)
	if f != null:
		node.add_theme_font_override("font", f)


# ---------------------------------------------------------------------------
# 样式工厂
# ---------------------------------------------------------------------------

static func stylebox(bg: Color, radius: int = 10,
		border_color: Color = Color(0, 0, 0, 0), border_width: int = 0,
		pad_h: int = 20, pad_v: int = 12) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	if border_width > 0:
		sb.set_border_width_all(border_width)
		sb.border_color = border_color
	sb.content_margin_left = float(pad_h)
	sb.content_margin_right = float(pad_h)
	sb.content_margin_top = float(pad_v)
	sb.content_margin_bottom = float(pad_v)
	return sb


## 给 Panel / PanelContainer 套上统一面板样式
static func apply_panel(node: Control, preset_name: String = "default",
		bg: Color = PANEL_BG) -> void:
	_ensure()
	var d := _sub_preset("panels", preset_name)
	var radius := int(d.get("radius", 16))
	var border := int(d.get("border_width", 1))
	node.add_theme_stylebox_override("panel", stylebox(bg, radius, BORDER, border))


# ---------------------------------------------------------------------------
# 按钮
# ---------------------------------------------------------------------------

## 预设配置的尺寸（宽 0 表示宽度自适应内容）
static func button_min_size(preset_name: String) -> Vector2:
	var p := preset(preset_name)
	return Vector2(float(p.get("width", 0)), float(p.get("height", 0)))


## 从预设里取颜色（十六进制字符串），缺省时用 fallback
static func _preset_color(p: Dictionary, key: String, fallback: Color) -> Color:
	var raw := String(p.get(key, "")).strip_edges()
	if raw.is_empty():
		return fallback
	return Color.from_string(raw, fallback)


static func apply_button(btn: Button, preset_name: String = "default") -> void:
	_ensure()
	var p := preset(preset_name)

	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		btn.add_theme_stylebox_override(state, _button_stylebox(p, state))

	btn.add_theme_color_override("font_color", _preset_color(p, "font_color", TEXT))
	btn.add_theme_color_override("font_hover_color", _preset_color(p, "font_hover_color", Color.WHITE))
	btn.add_theme_color_override("font_pressed_color", _preset_color(p, "font_pressed_color", Color.WHITE))
	btn.add_theme_color_override("font_disabled_color", _preset_color(p, "font_disabled_color", TEXT_DIM))
	btn.add_theme_font_size_override("font_size", int(p.get("font_size", 24)))

	var f := font("body")
	if f != null:
		btn.add_theme_font_override("font", f)

	var size := button_min_size(preset_name)
	if size.y > 0.0:
		btn.custom_minimum_size = size

	attach_button_sfx(btn, preset_name)


## 给按钮挂上 UI 音效（点击 / 悬停）。
##
## apply_button 会自动调用；自己搭样式盒的按钮（比如曲目列表）可以手动调。
## 音效 id 与音量来自 ui_theme.json 的 audio 段，按钮预设可用
## sfx_click / sfx_hover 覆盖，或写 "sfx": false 让这一类按钮静音。
##
## 找不到音效文件时 AudioManager 会静默跳过 —— 删掉素材不会让按钮报错。
static func attach_button_sfx(btn: Button, preset_name: String = "default") -> void:
	if Engine.is_editor_hint():
		return
	if btn.has_meta(SFX_META):
		return
	var p := preset(preset_name)
	if not bool(p.get("sfx", true)):
		return
	btn.set_meta(SFX_META, true)
	# 用 button_down 而不是 pressed：按下的瞬间出声更跟手
	btn.button_down.connect(_play_ui_sfx.bind(btn, preset_name, "click"))
	btn.mouse_entered.connect(_play_ui_sfx.bind(btn, preset_name, "hover"))


static func _play_ui_sfx(btn: Button, preset_name: String, kind: String) -> void:
	if not is_instance_valid(btn) or btn.disabled:
		return
	var p := preset(preset_name)
	var audio := section("audio")
	var id := String(p.get("sfx_" + kind, "")).strip_edges()
	if id.is_empty():
		id = String(audio.get(kind, "")).strip_edges()
	if id.is_empty():
		return
	AudioManager.play_se(id, float(audio.get(kind + "_volume", 0.7)))


## 有九宫格贴图就用 StyleBoxTexture，否则用程序化圆角矩形
static func _button_stylebox(p: Dictionary, state: String) -> StyleBox:
	var own := String(p.get("texture_" + state, "")).strip_edges()
	var base := String(p.get("texture", "")).strip_edges()
	var path := own if not own.is_empty() else base

	if not path.is_empty() and ResourceLoader.exists(path):
		var texture := load(path) as Texture2D
		if texture != null:
			return _texture_stylebox(texture, p, state, own.is_empty())

	return _flat_stylebox(p, state)


static func _texture_stylebox(texture: Texture2D, p: Dictionary, state: String,
		tinted: bool) -> StyleBoxTexture:
	var margin := int(p.get("texture_margin", 12))
	var pad_h := int(p.get("pad_h", 24))
	var pad_v := int(p.get("pad_v", 12))

	var sb := StyleBoxTexture.new()
	sb.texture = texture
	sb.texture_margin_left = float(margin)
	sb.texture_margin_right = float(margin)
	sb.texture_margin_top = float(margin)
	sb.texture_margin_bottom = float(margin)
	sb.content_margin_left = float(pad_h)
	sb.content_margin_right = float(pad_h)
	sb.content_margin_top = float(pad_v)
	sb.content_margin_bottom = float(pad_v)

	# 只配了一张贴图时，用色调区分交互状态
	if tinted:
		match state:
			"hover":
				sb.modulate_color = Color(1.22, 1.20, 1.30)
			"pressed":
				sb.modulate_color = Color(0.78, 0.76, 0.90)
			"disabled":
				sb.modulate_color = Color(0.45, 0.45, 0.52, 0.65)
	return sb


static func _flat_stylebox(p: Dictionary, state: String) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	match state:
		"normal":
			sb.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.16)
			sb.set_border_width_all(1)
			sb.border_color = ACCENT
		"hover":
			sb.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.32)
			sb.set_border_width_all(1)
			sb.border_color = ACCENT_BRIGHT
		"pressed":
			sb.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.48)
			sb.set_border_width_all(1)
			sb.border_color = ACCENT_BRIGHT
		"disabled":
			sb.bg_color = Color(0.30, 0.30, 0.36, 0.14)
			sb.set_border_width_all(1)
			sb.border_color = Color(0.40, 0.40, 0.46)
		"focus":
			sb.bg_color = Color(0, 0, 0, 0)
			sb.set_border_width_all(2)
			sb.border_color = ACCENT_BRIGHT

	sb.set_corner_radius_all(int(p.get("radius", 10)))
	var pad_h := int(p.get("pad_h", 24))
	var pad_v := int(p.get("pad_v", 12))
	sb.content_margin_left = float(pad_h)
	sb.content_margin_right = float(pad_h)
	sb.content_margin_top = float(pad_v)
	sb.content_margin_bottom = float(pad_v)
	return sb


# ---------------------------------------------------------------------------
# 标签
# ---------------------------------------------------------------------------

static func apply_label(label: Label, color: Color = TEXT, font_size: int = 22,
		font_key: String = "") -> void:
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", font_size)
	if not font_key.is_empty():
		apply_font(label, font_key)


static func apply_rich_text(label: RichTextLabel, color: Color = TEXT,
		font_size: int = 28, font_key: String = "") -> void:
	label.add_theme_color_override("default_color", color)
	label.add_theme_font_size_override("normal_font_size", font_size)
	if not font_key.is_empty():
		apply_font(label, font_key)


## 生成一个三角形指示器（默认字体不含 ▼ 字形，所以用图形代替）
static func make_triangle(size: float, color: Color = TEXT) -> Polygon2D:
	var poly := Polygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(size, 0.0),
		Vector2(size * 0.5, size * 0.72),
	])
	poly.color = color
	return poly
