class_name CgViewer
extends Control

## CG 全屏查看器
##
## 展示一张已解锁的 CG，并提供「重播剧情」入口。
## 重播能否使用取决于注册表里该条目有没有 replay 配置 —— 没有就把按钮置灰
## 并给出说明，而不是让玩家点了没反应。

signal replay_requested(cg_id: String)
signal closed()

@onready var _image: TextureRect = %CgImage
@onready var _title: Label = %CgViewerTitle
@onready var _hint: Label = %CgViewerHint
@onready var _replay: Button = %CgReplay
@onready var _close: Button = %CgViewerClose
@onready var _panel: PanelContainer = $Panel

var _current_id: String = ""


func _ready() -> void:
	visible = false

	var font_size := GalleryTheme.count("button_font_size", 22)
	# 走 panel_stylebox，别再手写 stylebox —— 这里原来是 UiTheme.stylebox(程序化)，
	# 后果有两层：一是面板贴图被挡在门外（cg_viewer 的整图一直没生效，只能画圆角矩形），
	# 二是内边距的来源跟其它功能窗口分了家。现在统一由 panels.cg_viewer 给。
	# 历史教训：更早那版 pad_h / pad_v 都传 0，CG 图、标题、按钮全顶到边框上。
	UiTheme.apply_panel(_panel, "cg_viewer", GalleryTheme.color("panel"))
	_title.add_theme_font_size_override("font_size", 28)
	_title.add_theme_color_override("font_color", GalleryTheme.color("text"))
	_hint.add_theme_font_size_override("font_size", font_size - 4)
	_hint.add_theme_color_override("font_color", GalleryTheme.color("text_dim"))

	UiTheme.apply_button(_replay, "default")
	UiTheme.apply_button(_close, "default")
	_replay.text = GalleryTheme.label("replay_button", "重播剧情")
	_close.text = GalleryTheme.label("close_button", "关闭")

	_replay.pressed.connect(func() -> void: replay_requested.emit(_current_id))
	_close.pressed.connect(hide_panel)


# ---------------------------------------------------------------------------
# 对外
# ---------------------------------------------------------------------------

func present(cg_id: String) -> void:
	var item := CollectionRegistry.get_item("cg", cg_id)
	if item.is_empty():
		return

	_current_id = cg_id
	_image.texture = CollectionRegistry.resolve_texture(item)
	_title.text = String(item.get("title", cg_id))

	var can_replay := has_replay()
	_replay.disabled = not can_replay
	_hint.text = "" if can_replay else GalleryTheme.label("replay_unavailable", "该 CG 没有关联剧情")

	visible = true


func hide_panel() -> void:
	visible = false
	closed.emit()


func get_current_id() -> String:
	return _current_id


func has_replay() -> bool:
	var item := CollectionRegistry.get_item("cg", _current_id)
	if item.is_empty():
		return false
	var replay: Variant = item.get("replay", {})
	if typeof(replay) != TYPE_DICTIONARY:
		return false
	return not String((replay as Dictionary).get("file", "")).is_empty() \
		and not String((replay as Dictionary).get("label", "")).is_empty()
