class_name VideoViewer
extends Control

## 视频鉴赏的播放器
##
## 与 CgViewer 对称：全屏面板 + 一段影片 + 标题/提示 + 关闭。
##
## **整个界面由代码搭建**，不写进 main.tscn —— 理由和 RecordsPanel 一样：
## 它是一个只在鉴赏里出现的查看器，往场景文件里塞十几个节点会让 tscn 更难读，
## 而它的结构又完全是对称的（面板 / 视频 / 页脚）。
##
## 播放走 Godot 的 `VideoStreamPlayer`，所以素材必须是 **Ogg Theora（.ogv）**；
## 素材缺失时不静默黑屏，直接在提示行里说明（玩家点了没反应是最糟的体验）。
##
## 打开时把 BGM 暂停、关闭时恢复 —— 影片自带音轨，两路声音叠在一起没法听。
## 恢复是有条件的（原来在响才恢复），否则会把玩家自己按下的暂停给顶掉。

signal closed()

## 面板矩形：与 CgViewer 完全一致（同一张整图贴图，尺寸必须逐像素相等）
const PANEL_INSET := Vector2(60.0, 50.0)

var _dim: ColorRect
var _panel: PanelContainer
var _player: VideoStreamPlayer
var _title: Label
var _hint: Label
var _close: Button

var _current_id: String = ""
## 打开查看器之前 BGM 是不是在响 —— 决定关闭时要不要恢复
var _bgm_was_audible: bool = false


func _ready() -> void:
	# ⚠️ 代码创建、直接挂在 CanvasLayer 下的 Control **拿不到视口尺寸** ——
	# `set_anchors_preset(FULL_RECT)` 之后 size 仍由内容撑出来，于是「满屏查看器」
	# 只会占住左上角一小块（截图里一眼看到：面板缩在角上、影片框是个小方块）。
	# 必须显式按视口设 offset，并跟着视口变化。见 DESIGN.md「布局坑」。
	_fit_to_viewport()
	if not get_viewport().size_changed.is_connected(_fit_to_viewport):
		get_viewport().size_changed.connect(_fit_to_viewport)
	# 吃掉点击：查看器盖在鉴赏网格上，不挡的话点视频会把底下的卡片一起点了
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()


## 锚点固定在左上角，矩形完全由 offset 决定 —— 这样不管父级是 CanvasLayer
## 还是普通 Control，尺寸都正好等于视口，也不会触发引擎那条
## 「非等值锚点下 size 会被 offset 反推」的警告。
func _fit_to_viewport() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var rect := viewport.get_visible_rect().size
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	offset_left = 0.0
	offset_top = 0.0
	offset_right = rect.x
	offset_bottom = rect.y


func _build() -> void:
	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim.color = UiTheme.scrim_color(true)
	add_child(_dim)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = PANEL_INSET.x
	_panel.offset_top = PANEL_INSET.y
	_panel.offset_right = -PANEL_INSET.x
	_panel.offset_bottom = -PANEL_INSET.y
	add_child(_panel)
	UiTheme.apply_panel(_panel, "cg_viewer", GalleryTheme.color("panel"))

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 18)
	_panel.add_child(vbox)

	# 用 AspectRatioContainer 兜住 16:9：设计分辨率是 16:9，但面板矩形不是，
	# 直接铺满会把影片横向拉长。STRETCH_FIT = 完整放进框里，留黑边也不变形。
	var holder := AspectRatioContainer.new()
	holder.ratio = 16.0 / 9.0
	holder.stretch_mode = AspectRatioContainer.STRETCH_FIT
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(holder)

	_player = VideoStreamPlayer.new()
	_player.name = "Player"
	_player.set_anchors_preset(Control.PRESET_FULL_RECT)
	_player.expand = true
	_player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 鉴赏里循环播放：玩家可以反复看，不用每次重按
	_player.loop = true
	holder.add_child(_player)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 18)
	vbox.add_child(footer)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 4)
	footer.add_child(info)

	_title = Label.new()
	_title.set_meta(I18n.META_SKIP, true)
	_title.add_theme_font_size_override("font_size", 28)
	_title.add_theme_color_override("font_color", GalleryTheme.color("text"))
	info.add_child(_title)

	_hint = Label.new()
	_hint.set_meta(I18n.META_SKIP, true)
	_hint.add_theme_font_size_override("font_size", 18)
	_hint.add_theme_color_override("font_color", GalleryTheme.color("text_dim"))
	info.add_child(_hint)

	_close = Button.new()
	_close.text = GalleryTheme.label("close_button", "关闭")
	UiTheme.apply_button(_close, "default")
	_close.pressed.connect(hide_panel)
	footer.add_child(_close)


# ---------------------------------------------------------------------------
# 对外
# ---------------------------------------------------------------------------

func present(video_id: String) -> void:
	var item := CollectionRegistry.get_item("video", video_id)
	if item.is_empty():
		return
	_fit_to_viewport()
	_current_id = video_id
	_title.text = String(item.get("title", video_id))

	var path := VideoScreen.resolve(video_id)
	if path.is_empty():
		_hint.text = I18n.t("该视频素材缺失")
		_player.stream = null
		_player.visible = false
	else:
		_hint.text = String(item.get("hint", ""))
		_player.stream = load(path) as VideoStream
		_player.visible = true
		_player.play()

	# 影片自带音轨，跟 BGM 叠着没法听 —— 先按下暂停，关掉时再放回去
	_bgm_was_audible = AudioManager.is_bgm_audible()
	if _bgm_was_audible:
		AudioManager.pause_bgm()

	visible = true


func hide_panel() -> void:
	if _player != null:
		_player.stop()
		_player.visible = false
	if _bgm_was_audible:
		AudioManager.resume_bgm()
	_bgm_was_audible = false
	_current_id = ""
	visible = false
	closed.emit()


func get_current_id() -> String:
	return _current_id


func is_playing() -> bool:
	return visible and _player != null and _player.is_playing()


## 供自动化测试 / 调试
func get_player() -> VideoStreamPlayer:
	return _player
