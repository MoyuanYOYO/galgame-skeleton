class_name MusicPanel
extends VBoxContainer

## 音乐鉴赏面板
##
## · 左侧曲目列表：未解锁显示 ??? 且不可点；**正在播放的曲目高亮并带 ♪ 前缀**
## · 右侧播放器卡片：曲名 / 艺术家 / 进度条（可拖拽跳转）/ 播放控制 / 播放模式
## · 外观（配色、字号）来自 gallery_theme.json
##
## 面板不自己播放音频，只发 track_selected 让 main.gd 去驱动 AudioManager ——
## 这样「鉴赏里试听」和「剧本里播放」走同一条路径，不会出现两套状态。
##
## 播放模式（单曲循环 / 列表循环 …）需要知道「这一首放完了」，靠 AudioManager
## 的 `bgm_finished`。那条信号**只在流不循环时才触发**，所以鉴赏试听必须显式
## `play_bgm(..., loop = false)` —— 见 `main._on_music_track_selected`。

signal track_selected(id: String)

## 播放模式。点一下模式按钮顺时针切下一个。
enum PlayMode {
	LIST_LOOP,
	SINGLE_LOOP,
	SHUFFLE,
	ONCE,
}

## 各模式在 gallery_theme.json 的 text 段里的键与兜底文案。下标 = 枚举值。
const MODE_KEYS: Array[String] = [
	"mode_list_loop", "mode_single_loop", "mode_shuffle", "mode_once",
]
const MODE_FALLBACKS: Array[String] = ["列表循环", "单曲循环", "随机播放", "顺序播放"]

## 曲名前面那个「正在播」标记。唱片拿掉之后，高亮是唯一的线索，
## 加个符号让它在长列表里也一眼能找到。
const NOW_MARK := "♪  "

@onready var _track_list: VBoxContainer = %TrackList
@onready var _status: Label = %MusicStatus
@onready var _now_playing: Label = %NowPlaying
@onready var _artist: Label = %TrackArtist
@onready var _progress: HSlider = %Progress
@onready var _time: Label = %MusicTime
@onready var _length: Label = %MusicLength
@onready var _prev: Button = %MusicPrev
@onready var _play: Button = %MusicPlay
@onready var _stop: Button = %MusicStop
@onready var _next: Button = %MusicNext
@onready var _mode_button: Button = %MusicMode

var _buttons: Dictionary = {}
## 曲目 id → 原始标题。加 / 去 ♪ 前缀时要拿它还原，不能从按钮文字反推。
var _titles: Dictionary = {}
var _highlighted_id: String = "\u0000"
var _mode: int = PlayMode.LIST_LOOP

## 用户正按着进度条手柄。此时 _process 不许回写 value ——
## 否则手柄会被拽回上一帧的位置，拖不动。
var _seeking: bool = false
## 我们自己回写 value 时置起，用来忽略随之而来的 value_changed。
## 没有这道闸门的话「刷新进度条」会被当成「用户跳转」，一路递归下去。
var _syncing: bool = false

var _style_normal: StyleBoxFlat
var _style_hover: StyleBoxFlat
var _style_active: StyleBoxFlat
var _style_active_hover: StyleBoxFlat
var _font_normal: Color
var _font_active: Color
var _font_locked: Color


func _ready() -> void:
	_build_styles()
	_prev.pressed.connect(func() -> void: _step_track(-1))
	_next.pressed.connect(func() -> void: _step_track(1))
	_play.pressed.connect(_on_play_pressed)
	_stop.pressed.connect(_on_stop_pressed)
	_mode_button.pressed.connect(_cycle_mode)
	_progress.drag_started.connect(func() -> void: _seeking = true)
	_progress.drag_ended.connect(_on_progress_drag_ended)
	_progress.value_changed.connect(_on_progress_changed)
	# 一首放完 → 按当前模式决定下一首。剧本 BGM 一律循环，走不到这里。
	AudioManager.bgm_finished.connect(_on_track_finished)

	# 曲名 / 艺术家 / 时间刻度是内容或运行时拼的字符串，不参与界面翻译
	for n in [_track_list, _now_playing, _artist, _time, _length]:
		(n as Control).set_meta(I18n.META_SKIP, true)
	# 这些标签在场景里没配颜色（旧暗底面板靠默认白字），换浅色主题后
	# 必须跟着 gallery_theme.json 走，否则奶油底上是白字看不见。
	# ListHeader 没有 unique_name_in_owner，只能走直接路径（%ListHeader 会抛
	# Node not found，把整个 _ready 带崩 —— 踩过）。
	var list_header := get_node_or_null("Body/Left/ListHeader") as Label
	if list_header != null:
		list_header.add_theme_color_override(
			"font_color", GalleryTheme.color("text_dim"))
	UiTheme.apply_panel(get_node("Body/Right") as PanelContainer, "player")
	UiTheme.apply_label(_status, GalleryTheme.color("text_dim"), 18)
	UiTheme.apply_label(_now_playing, GalleryTheme.color("text"), 36)
	UiTheme.apply_label(_artist, GalleryTheme.color("text_dim"), 20)
	UiTheme.apply_label(_time, GalleryTheme.color("text_dim"), 18)
	UiTheme.apply_label(_length, GalleryTheme.color("text_dim"), 18)
	UiTheme.apply_slider(_progress)
	for btn in [_prev, _play, _stop, _next, _mode_button]:
		UiTheme.apply_button(btn as Button, "default")
	refresh()


# ---------------------------------------------------------------------------
# 对外
# ---------------------------------------------------------------------------

func refresh() -> void:
	_seeking = false
	_rebuild_track_list()
	_highlighted_id = "\u0000"
	_update_highlight()
	_update_mode_label()
	_update_controls()
	_update_progress()


func get_play_mode() -> int:
	return _mode


## 直接指定播放模式。供自动化测试 / 调试使用 ——
## 走按钮那条路只能「切下一个」，测试想复现某个特定模式就得点好几次。
func set_play_mode(mode: int) -> void:
	_mode = clampi(mode, 0, PlayMode.size() - 1)
	_update_mode_label()


# ---------------------------------------------------------------------------
# 样式
# ---------------------------------------------------------------------------

func _build_styles() -> void:
	var card := GalleryTheme.color("card")
	var card_hover := GalleryTheme.color("card_hover")
	var highlight := GalleryTheme.color("highlight")
	var bright := GalleryTheme.color("accent_bright")
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


# ---------------------------------------------------------------------------
# 曲目列表
# ---------------------------------------------------------------------------

func _rebuild_track_list() -> void:
	for child in _track_list.get_children():
		_track_list.remove_child(child)
		child.queue_free()
	_buttons.clear()
	_titles.clear()

	var locked_label := GalleryTheme.label("locked_label", "???")
	# 尺寸与字号取自 UiTheme 的 track 预设；高亮态需要额外的样式盒，
	# 所以这里不直接用 apply_button，只复用它的配置。
	var track_preset := UiTheme.preset("track")
	var track_size := UiTheme.button_min_size("track")
	var font_size := int(track_preset.get("font_size", 20))

	for item in CollectionRegistry.get_items("music"):
		var id := String((item as Dictionary).get("id", ""))
		var title := String(item.get("title", id))
		var unlocked := CollectionManager.is_unlocked("music", id)

		var btn := Button.new()
		btn.custom_minimum_size = track_size
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.focus_mode = Control.FOCUS_NONE
		btn.disabled = not unlocked
		btn.text = title if unlocked else locked_label
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
		_titles[id] = title


func _on_track_pressed(id: String) -> void:
	track_selected.emit(id)


func _apply_button_style(id: String, active: bool) -> void:
	var btn := _buttons.get(id) as Button
	if btn == null or btn.disabled:
		return
	btn.add_theme_stylebox_override("normal", _style_active if active else _style_normal)
	btn.add_theme_stylebox_override("hover", _style_active_hover if active else _style_hover)
	btn.add_theme_color_override("font_color", _font_active if active else _font_normal)
	var title := String(_titles.get(id, id))
	btn.text = (NOW_MARK + title) if active else title


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


## 切上一首 / 下一首。`wrap = false` 时走到列表尽头返回 false、不切歌 ——
## 顺序播放模式靠它判断「整张列表放完了」。
## 按钮走默认的 `wrap = true`：手动点「下一首」在末尾绕回第一首，
## 比「什么都不发生」更符合预期。
func _step_track(step: int, wrap: bool = true) -> bool:
	# 随机模式下「下一首」也随机 —— 按钮写着随机、行为却是顺序，比不实现更让人困惑
	if _mode == PlayMode.SHUFFLE and step > 0:
		_play_random()
		return true
	var ids := _playable_ids()
	if ids.is_empty():
		return false
	var current := AudioManager.get_bgm_id()
	var index := ids.find(current)
	if index < 0:
		# 当前曲目不在可播放列表里（比如播的是未解锁的隐藏曲）→ 从头 / 从尾开始
		index = 0 if step > 0 else ids.size() - 1
	else:
		index += step
		if index < 0 or index >= ids.size():
			if not wrap:
				return false
			index = wrapi(index, 0, ids.size())
	track_selected.emit(ids[index])
	return true


func _play_random() -> void:
	var ids := _playable_ids()
	if ids.is_empty():
		return
	if ids.size() == 1:
		track_selected.emit(ids[0])
		return
	var current := AudioManager.get_bgm_id()
	var pool: Array[String] = []
	for id in ids:
		if id != current:
			pool.append(id)
	track_selected.emit(pool[randi() % pool.size()])


## 播放键是个开关键：暂停中 → 恢复；正在响 → 暂停；有曲目但没在响 → 从头来。
##
## 顺序不能反：`is_bgm_paused()` 必须在最前面。暂停时 `is_bgm_audible()` 也返回
## false（它同样以 playing 起头），先判它就会掉进「重新起播」那条路 ——
## 这正是「点暂停变成从头播」这个 bug 的界面侧成因。
func _on_play_pressed() -> void:
	var current := AudioManager.get_bgm_id()
	if AudioManager.is_bgm_paused():
		AudioManager.resume_bgm()
	elif AudioManager.is_bgm_audible():
		AudioManager.pause_bgm()
	elif not current.is_empty():
		track_selected.emit(current)
	else:
		var ids := _playable_ids()
		if not ids.is_empty():
			track_selected.emit(ids[0])
	_update_controls()


func _on_stop_pressed() -> void:
	_finish_playback()


func _cycle_mode() -> void:
	_mode = (int(_mode) + 1) % PlayMode.size()
	_update_mode_label()


func _update_mode_label() -> void:
	I18n.set_text(_mode_button,
		GalleryTheme.label(MODE_KEYS[_mode], MODE_FALLBACKS[_mode]))


## 一首放完。只有「鉴赏界面正开着」才接管 ——
## 剧本 BGM 一律循环、压根不会触发这条信号，但仍要防：面板关掉之后
## 放完的曲子不该由这里决定下一首。
func _on_track_finished() -> void:
	if not is_visible_in_tree():
		return
	match _mode:
		PlayMode.SINGLE_LOOP:
			_replay_current()
		PlayMode.LIST_LOOP:
			_step_track(1)
		PlayMode.SHUFFLE:
			_play_random()
		PlayMode.ONCE:
			# 「顺序播放」= 顺着列表一首首往下放，放到最后一首才停。
			# 之前写成「放完这一首就停」是错的 —— 那样这个模式和「只播一首」
			# 没区别；不循环的播放器里，它指的是「走得完整张列表，只是不回头」。
			if not _step_track(1, false):
				_finish_playback()


## 整张列表放完（顺序播放模式）。收摊，回到「未在播放」。
func _finish_playback() -> void:
	AudioManager.stop_bgm(0.3)
	_update_highlight()
	_update_controls()
	_update_progress()


## 从头重播当前曲目。
## 能穿透 play_bgm 的防重入守卫：它要求「playing 或 暂停」，而「刚放完」
## 两个都不是，所以请求正常落地，由 _swap_bgm_stream 的 play() 从 0 秒起。
func _replay_current() -> void:
	var current := AudioManager.get_bgm_id()
	if not current.is_empty():
		track_selected.emit(current)


func _update_controls() -> void:
	var current := AudioManager.get_bgm_id()
	var playable := _playable_ids()
	_prev.disabled = playable.size() <= 1
	_next.disabled = playable.size() <= 1
	_play.disabled = playable.is_empty()
	_stop.disabled = current.is_empty()
	_progress.editable = not current.is_empty()

	if AudioManager.is_bgm_paused():
		I18n.set_text(_play, GalleryTheme.label("play_button", "播放"))
		I18n.set_text(_status, GalleryTheme.label("paused_label", "已暂停"))
	elif AudioManager.is_bgm_audible():
		I18n.set_text(_play, GalleryTheme.label("pause_button", "暂停"))
		I18n.set_text(_status, GalleryTheme.label("now_playing", "正在播放"))
	else:
		I18n.set_text(_play, GalleryTheme.label("play_button", "播放"))
		I18n.set_text(_status, GalleryTheme.label("not_playing", "未在播放"))

	if current.is_empty():
		_now_playing.text = GalleryTheme.label("no_track", "—")
		_artist.text = " "
		return
	var item := CollectionRegistry.get_item("music", current)
	_now_playing.text = String(item.get("title", current))
	var artist := String(item.get("artist", ""))
	# 空字符串会让这一行塌掉、标题跟着跳位，用空格占住
	_artist.text = artist if not artist.is_empty() else " "


func _update_highlight() -> void:
	var current := AudioManager.get_bgm_id()
	if current == _highlighted_id:
		return
	_highlighted_id = current
	for id in _buttons.keys():
		_apply_button_style(String(id), String(id) == current)


# ---------------------------------------------------------------------------
# 进度条
# ---------------------------------------------------------------------------

func _update_progress() -> void:
	var loaded := not AudioManager.get_bgm_id().is_empty()
	var length := AudioManager.get_bgm_length() if loaded else 0.0
	var pos := AudioManager.get_bgm_position()
	_progress.max_value = maxf(length, 1.0)
	_syncing = true
	_progress.value = pos
	_syncing = false
	_time.text = _format_time(pos)
	_length.text = _format_time(length) if length > 0.0 else "--:--"


func _on_progress_changed(value: float) -> void:
	# 自己回写触发的，不算用户操作
	if _syncing:
		return
	AudioManager.seek_bgm(value)
	_time.text = _format_time(value)


func _on_progress_drag_ended(_value_changed: bool) -> void:
	_seeking = false
	# 松手后跟引擎对一次账。拖动期间 _process 是让位的，位置以 AudioManager 为准。
	_update_progress()


static func _format_time(seconds: float) -> String:
	var total := int(maxf(0.0, seconds))
	return "%02d:%02d" % [floori(float(total) / 60.0), total % 60]


func _process(_delta: float) -> void:
	if not visible:
		return
	_update_highlight()
	_update_controls()
	# 拖手柄时别回写 value，否则手柄被拽回去、拖不动
	if not _seeking:
		_update_progress()
