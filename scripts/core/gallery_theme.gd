class_name GalleryTheme
extends RefCounted

## 鉴赏界面外观配置
##
## 所有配色、尺寸、文案都从 data/ui/gallery_theme.json 读，代码里没有任何
## 写死的视觉常量。改 json 就能换皮；只写关心的键也能工作（会与默认值深合并）。

const CONFIG_PATH := "res://data/ui/gallery_theme.json"

static var _data: Dictionary = {}


# ---------------------------------------------------------------------------
# 默认值（配置文件缺项时的兜底）
# ---------------------------------------------------------------------------

static func _defaults() -> Dictionary:
	return {
		"palette": {
			"background": "#0b0a14",
			"panel": "#16132b",
			"panel_border": "#6c63c9",
			"card": "#1c1932",
			"card_border": "#3d3768",
			"card_hover": "#2a2450",
			"card_locked": "#131124",
			"accent": "#7f77dd",
			"accent_bright": "#9a93ec",
			"text": "#ece9ff",
			"text_dim": "#a9a3d0",
			"text_locked": "#5d5878",
			"highlight": "#f1c774",
			"success": "#71c89c",
		},
		"layout": {
			"card_width": 350,
			"card_ratio": 0.5625,
			"card_radius": 14,
			"columns": 3,
			"grid_spacing": 22,
			"panel_margin": 70,
			"title_font_size": 34,
			"tab_font_size": 24,
			"card_title_font_size": 20,
			"track_font_size": 20,
			"button_font_size": 22,
		},
		"text": {
			"title": "鉴 赏",
			"tab_cg": "CG 鉴赏",
			"tab_music": "音乐鉴赏",
			"locked_label": "???",
			"locked_hint": "尚未解锁",
			"empty_hint": "还没有解锁任何内容，去游戏里探索吧。",
			"replay_button": "重播剧情",
			"replay_unavailable": "该 CG 没有关联剧情",
			"close_button": "关闭",
			"prev_button": "上一首",
			"next_button": "下一首",
			"play_button": "播放",
			"pause_button": "暂停",
			"now_playing": "正在播放",
			"not_playing": "未在播放",
			"paused_label": "已暂停",
			"progress_label": "CG 收集进度",
			"music_progress_label": "乐曲收集进度",
		},
		"locked_icon": {
			"style": "lock",
			"size": 58,
		},
		"visualizer": {
			"mode": "both",
			"disc_radius": 104,
			"disc_speed": 0.85,
			"disc_hole_ratio": 0.17,
			"disc_label_ratio": 0.44,
			"spectrum_bars": 32,
			"spectrum_height": 86,
			"spectrum_gap": 4,
			"spectrum_scale": 6.0,
			"spectrum_idle_wave": 0.07,
		},
	}


# ---------------------------------------------------------------------------
# 读取接口
# ---------------------------------------------------------------------------

static func reload() -> void:
	_data = _defaults()
	var raw: Variant = JsonUtil.load_json(CONFIG_PATH)
	if typeof(raw) == TYPE_DICTIONARY:
		JsonUtil.deep_merge(_data, raw)
	else:
		push_warning("[GalleryTheme] 配置读取失败，使用内置默认值")


static func _ensure() -> void:
	if _data.is_empty():
		reload()


static func section(name: String) -> Dictionary:
	_ensure()
	var value: Variant = _data.get(name, {})
	return value if typeof(value) == TYPE_DICTIONARY else {}


static func color(key: String, fallback: Color = Color.MAGENTA) -> Color:
	_ensure()
	var raw := String(section("palette").get(key, ""))
	if raw.is_empty():
		return fallback
	return Color.from_string(raw, fallback)


static func number(key: String, fallback: float) -> float:
	_ensure()
	var raw: Variant = section("layout").get(key, null)
	if raw == null:
		return fallback
	return float(raw)


static func count(key: String, fallback: int) -> int:
	return int(number(key, float(fallback)))


static func label(key: String, fallback: String = "") -> String:
	_ensure()
	var raw: Variant = section("text").get(key, null)
	if raw == null:
		return fallback
	return String(raw)


static func visual(key: String, fallback: Variant = null) -> Variant:
	_ensure()
	return section("visualizer").get(key, fallback)


static func visualizer_mode() -> String:
	return String(visual("mode", "both")).to_lower()


## 把所有调色板导出成字典，方便一次性传给子控件
static func palette_snapshot() -> Dictionary:
	_ensure()
	var out: Dictionary = {}
	for key in section("palette").keys():
		out[String(key)] = color(String(key))
	return out
