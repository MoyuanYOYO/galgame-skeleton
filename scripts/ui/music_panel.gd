class_name MusicPanel
extends VBoxContainer

## 音乐鉴赏面板
##
## · 左侧曲目列表：未解锁显示 ??? 且不可点；**正在播放的曲目高亮**
## · 右侧播放器：唱片动画 / 频谱可视化 + 上一首 / 播放暂停 / 下一首
## · 外观（配色、唱片尺寸与转速、频谱条数）全部来自 gallery_theme.json
##
## 面板不自己播放音频，只发 track_selected 让 main.gd 去驱动 AudioManager ——
## 这样「鉴赏里试听」和「剧本里播放」走同一条路径，不会出现两套状态。

signal track_selected(id: String)

@onready var _track_list: VBoxContainer = %TrackList
@onready var _visualizer_host: Control = %VisualizerHost
@onready var _now_playing: Label = %NowPlaying
@onready var _artist: Label = %TrackArtist
@onready var _prev: Button = %MusicPrev
@onready var _play: Button = %MusicPlay
@onready var _next: Button = %MusicNext
@onready var _time: Label = %MusicTime

var _buttons: Dictionary = {}
var _disc: RecordDisc = null
var _spectrum: SpectrumBars = null
var _highlighted_id: String = "\u0000"

var _style_normal: StyleBoxFlat
var _style_hover: StyleBoxFlat
var _style_active: StyleBoxFlat
var _style_active_hover: StyleBoxFlat
var _font_normal: Color
var _font_active: Color
var _font_locked: Color


func _ready() -> void:
	_build_styles()
	_build_visualizer()
	_prev.pressed.connect(func() -> void: _step_track(-1))
	_next.pressed.connect(func() -> void: _step_track(1))
	_play.pressed.connect(_on_play_pressed)
	# 曲名 / 艺术家 / 时间是内容，不参与界面翻译
	for n in [_track_list, _now_playing, _artist, _time]:
		(n as Control).set_meta(I18n.META_SKIP, true)
	# 这些标签在场景里没配颜色（旧暗底面板靠默认白字），换浅色主题后
	# 必须跟着 gallery_theme.json 走，否则奶油底上是白字看不见。
	# ListHeader 没有 unique_name_in_owner，只能走直接路径（%ListHeader 会抛
	# Node not found，把整个 _ready 带崩 —— 踩过）。
	var list_header := get_node_or_null("Body/Left/ListHeader") as Label
	if list_header != null:
		list_header.add_theme_color_override(
			"font_color", GalleryTheme.color("text_dim"))
	for n in [_now_playing, _artist, _time]:
		(n as Label).add_theme_color_override(
			"font_color", GalleryTheme.color("text"))
	refresh()


# ---------------------------------------------------------------------------
# 对外
# ---------------------------------------------------------------------------

func refresh() -> void:
	_rebuild_track_list()
	_highlighted_id = "\u0000"
	_update_highlight()
	_update_controls()


func stop_preview() -> void:
	_disc_spin(false)


# ---------------------------------------------------------------------------
# 样式
# ---------------------------------------------------------------------------

func _build_styles() -> void:
	var accent := GalleryTheme.color("accent")
	var bright := GalleryTheme.color("accent_bright")
	var highlight := GalleryTheme.color("highlight")
	var card := GalleryTheme.color("card")
	var card_hover := GalleryTheme.color("card_hover")
	_font_normal = GalleryTheme.color("text")
	_font_active = highlight
	_font_locked = GalleryTheme.color("text_locked")

	_style_normal = UiTheme.stylebox(Color(card.r, card.g, card.b, 0.55), 10,
		GalleryTheme.color("card_border"), 1, 22, 12)
	_style_hover = UiTheme.stylebox(Color(card_hover.r, card_hover.g, card_hover.b, 0.85), 10,
		bright, 1, 22, 12)
	_style_active = UiTheme.stylebox(Color(highlight.r, highlight.g, highlight.b, 0.22), 10,
		highlight, 2, 22, 12)
	_style_active_hover = UiTheme.stylebox(Color(highlight.r, highlight.g, highlight.b, 0.32), 10,
		highlight, 2, 22, 12)


func _build_visualizer() -> void:
	var mode := GalleryTheme.visualizer_mode()
	if mode == "none":
		return

	var disc_radius := GalleryTheme.number("disc_radius", 104.0)
	var disc_size := disc_radius * 2.0

	if mode == "spectrum" or mode == "both":
		_spectrum = SpectrumBars.new()
		_spectrum.name = "Spectrum"
		_spectrum.bar_count = GalleryTheme.count("spectrum_bars", 32)
		_spectrum.gap = GalleryTheme.number("spectrum_gap", 4.0)
		_spectrum.scale_factor = GalleryTheme.number("spectrum_scale", 6.0)
		_spectrum.idle_wave = GalleryTheme.number("spectrum_idle_wave", 0.07)
		_spectrum.bar_color = GalleryTheme.color("accent")
		_spectrum.peak_color = GalleryTheme.color("text")
		_fill(_spectrum)
		_visualizer_host.add_child(_spectrum)

	if mode == "disc" or mode == "both":
		_disc = RecordDisc.new()
		_disc.name = "Disc"
		_disc.spin_speed = GalleryTheme.number("disc_speed", 0.85)
		_disc.hole_ratio = GalleryTheme.number("disc_hole_ratio", 0.17)
		_disc.label_ratio = GalleryTheme.number("disc_label_ratio", 0.44)
		_disc.label_color = GalleryTheme.color("accent")
		_disc.marker_color = GalleryTheme.color("text")
		_disc.vinyl_color = GalleryTheme.color("background").darkened(0.25)
		_disc.groove_color = GalleryTheme.color("card_border").darkened(0.35)
		_disc.hole_color = GalleryTheme.color("background")
		_visualizer_host.add_child(_disc)
		_disc.set_anchors_preset(Control.PRESET_CENTER)
		_disc.offset_left = -disc_size * 0.5
		_disc.offset_top = -disc_size * 0.5
		_disc.offset_right = disc_size * 0.5
		_disc.offset_bottom = disc_size * 0.5


static func _fill(node: Control) -> void:
	node.set_anchors_preset(Control.PRESET_FULL_RECT)
	node.offset_left = 0.0
	node.offset_top = 0.0
	node.offset_right = 0.0
	node.offset_bottom = 0.0


# ---------------------------------------------------------------------------
# 曲目列表
# ---------------------------------------------------------------------------

func _rebuild_track_list() -> void:
	for child in _track_list.get_children():
		_track_list.remove_child(child)
		child.queue_free()
	_buttons.clear()

	var locked_label := GalleryTheme.label("locked_label", "???")
	# 尺寸与字号取自 UiTheme 的 track 预设；高亮态需要额外的样式盒，
	# 所以这里不直接用 apply_button，只复用它的配置。
	var track_preset := UiTheme.preset("track")
	var track_size := UiTheme.button_min_size("track")
	var font_size := int(track_preset.get("font_size", 20))

	for item in CollectionRegistry.get_items("music"):
		var id := String((item as Dictionary).get("id", ""))
		var unlocked := CollectionManager.is_unlocked("music", id)

		var btn := Button.new()
		btn.custom_minimum_size = track_size
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.focus_mode = Control.FOCUS_NONE
		btn.disabled = not unlocked
		btn.text = String(item.get("title", id)) if unlocked else locked_label
		btn.add_theme_font_size_override("font_size", font_size)
		btn.add_theme_stylebox_override("normal", _style_normal)
		btn.add_theme_stylebox_override("hover", _style_hover)
		btn.add_theme_stylebox_override("pressed", _style_active)
		btn.add_theme_stylebox_override("disabled", UiTheme.stylebox(
			Color(0, 0, 0, 0.18), 10, GalleryTheme.color("card_border").darkened(0.5), 1, 22, 12))
		btn.add_theme_stylebox_override("focus", _style_hover)
		btn.add_theme_color_override("font_color", _font_normal)
		btn.add_theme_color_override("font_hover_color", Color.WHITE)
		btn.add_theme_color_override("font_disabled_color", _font_locked)
		btn.pressed.connect(_on_track_pressed.bind(id))
		# 曲目按钮自己搭样式盒，没走 apply_button，所以音效要手动挂
		UiTheme.attach_button_sfx(btn, "track")

		_track_list.add_child(btn)
		_buttons[id] = btn


func _on_track_pressed(id: String) -> void:
	track_selected.emit(id)


func _apply_button_style(id: String, active: bool) -> void:
	var btn := _buttons.get(id) as Button
	if btn == null or btn.disabled:
		return
	btn.add_theme_stylebox_override("normal", _style_active if active else _style_normal)
	btn.add_theme_stylebox_override("hover", _style_active_hover if active else _style_hover)
	btn.add_theme_color_override("font_color", _font_active if active else _font_normal)


# ---------------------------------------------------------------------------
# 播放控制
# ---------------------------------------------------------------------------

func _playable_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for item in CollectionRegistry.get_items("music"):
		var id := String((item as Dictionary).get("id", ""))
		if CollectionManager.is_unlocked("music", id):
			out.append(id)
	return out


func _step_track(step: int) -> void:
	var ids := _playable_ids()
	if ids.is_empty():
		return
	var current := AudioManager.get_bgm_id()
	var index := ids.find(current)
	if index < 0:
		index = 0 if step > 0 else ids.size() - 1
	else:
		index = wrapi(index + step, 0, ids.size())
	track_selected.emit(ids[index])


func _on_play_pressed() -> void:
	var current := AudioManager.get_bgm_id()
	if current.is_empty():
		var ids := _playable_ids()
		if not ids.is_empty():
			track_selected.emit(ids[0])
		return
	if AudioManager.is_bgm_paused():
		AudioManager.resume_bgm()
	elif AudioManager.is_bgm_audible():
		AudioManager.pause_bgm()
	else:
		track_selected.emit(current)
	_update_controls()


func _update_controls() -> void:
	var current := AudioManager.get_bgm_id()
	var has_track := not current.is_empty()
	var playable := _playable_ids()
	_prev.disabled = playable.size() <= 1
	_next.disabled = playable.size() <= 1
	_play.disabled = playable.is_empty()

	if not has_track:
		I18n.set_text(_play, GalleryTheme.label("play_button", "播放"))
		_disc_spin(false)
		return

	var paused := AudioManager.is_bgm_paused()
	I18n.set_text(_play, GalleryTheme.label("play_button", "播放") if paused \
		else GalleryTheme.label("pause_button", "暂停"))
	# 只要选中了曲目且没暂停就让唱片转 —— 即使当前没有对应音频文件
	# （骨架阶段），唱片静止会让人以为播放器坏了。
	_disc_spin(not paused)

	var item := CollectionRegistry.get_item("music", current)
	_now_playing.text = String(item.get("title", current))
	_artist.text = String(item.get("artist", ""))


func _disc_spin(on: bool) -> void:
	if _disc != null:
		_disc.set_spinning(on)


func _update_highlight() -> void:
	var current := AudioManager.get_bgm_id()
	if current == _highlighted_id:
		return
	_highlighted_id = current
	for id in _buttons.keys():
		_apply_button_style(String(id), String(id) == current)


func _update_time() -> void:
	var current := AudioManager.get_bgm_id()
	if current.is_empty():
		_time.text = GalleryTheme.label("not_playing", "未在播放")
		return
	var prefix := GalleryTheme.label("paused_label", "已暂停") if AudioManager.is_bgm_paused() \
		else GalleryTheme.label("now_playing", "正在播放")
	var length := AudioManager.get_bgm_length()
	if length > 0.0:
		_time.text = "%s   %s / %s" % [
			prefix, _format_time(AudioManager.get_bgm_position()), _format_time(length)]
	else:
		_time.text = prefix


static func _format_time(seconds: float) -> String:
	var total := int(maxf(0.0, seconds))
	return "%02d:%02d" % [floori(float(total) / 60.0), total % 60]


func _process(_delta: float) -> void:
	if not visible:
		return
	_update_highlight()
	_update_controls()
	_update_time()
