class_name VideoScreen
extends Control

## 视频播放层
##
## 关于格式：Godot 内置**只能播 Ogg Theora**（`.ogv`）——`VideoStreamTheora`
## 是唯一的 VideoStream 子类，`ResourceLoader` 认得的后缀只有 `ogv`。
## Godot 不内置 H.264/H.265（授权原因），素材必须先用 ffmpeg / HandBrake
## 转成 `.ogv`。带 alpha 的视频内置**不支持**（Theora 是 YUV 4:2:0，没有
## alpha 平面）；想要透明视频请走帧序列动画（见 PlaceholderAssets）。
##
## 关于位置与图层：`VideoStreamPlayer` 继承 `Control`（不是 Node2D），
## 所以位置 / 尺寸随便定；**图层由宿主 CanvasLayer 的 `layer` 决定**，
## 本节点只负责「在给定矩形里把视频放好」。main.gd 把 video 指令的
## `layer=` 映射成 CanvasLayer.layer，所以剧本能精确控制视频压在 UI 之下还是之上。
##
## 适配策略：`expand = true` —— 视频拉伸到控件矩形。设计分辨率是 1920×1080
## （16:9），视频也基本都是 16:9，所以默认全屏时不存在变形；要放非 16:9 的
## 视频，请让 `size=` 与视频宽高比一致（Godot 不暴露 Theora 的原始尺寸，
## 无法替调用方自动算 contain，所以这里不做「猜」）。
##
## 素材约定：`assets/video/<id>.ogv`

signal finished(id: String)

const VIDEO_DIR := "res://assets/video/"
const VIDEO_EXTENSIONS: PackedStringArray = ["ogv"]
const DESIGN := Vector2(1920.0, 1080.0)

## 视频能放的三个图层。main.gd 把它们映射成宿主 CanvasLayer 的 `layer`：
##   world —— 舞台层，在对话框 / HUD 之下（默认）
##   ui    —— 在 UI 层之上，压住对话框
##   top   —— 最上层，连全屏特效一起压住
const LAYERS: PackedStringArray = ["world", "ui", "top"]
## 起播前的缓冲时长（毫秒）。Godot 默认 500ms —— 本地过场视频不需要缓冲这么久，
## 实测那 0.5 秒里画面是空的（黑/透明），过场开头会「先黑一下」。
## 120ms 对本地文件足够，起播几乎即时；卡顿的移动端可以调大。
const DEFAULT_BUFFER_MS := 120
## 图层名 → CanvasLayer.layer 的值。ui 取 15（UILayer 是 10、小游戏层是 20），
## top 取 40（FxLayer 是 30）。
const LAYER_VALUES := {"world": 0, "ui": 15, "top": 40}

var _player: VideoStreamPlayer
var _id: String = ""
var _hide_when_done: bool = true
var _fade_tween: Tween


func _ready() -> void:
	# 锚点在这里只是形式：本节点挂在 CanvasLayer 下，拿不到视口尺寸，
	# 而播放器用的是**显式设计像素坐标**（见 play / resolve_rect），
	# 所以父节点多大都无所谓 —— 前提是别打开 clip_contents。
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	_player = VideoStreamPlayer.new()
	_player.name = "Player"
	_player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player.expand = true
	_player.visible = false
	add_child(_player)
	_player.finished.connect(_on_stream_finished)


# ---------------------------------------------------------------------------
# 对外接口
# ---------------------------------------------------------------------------

## 播放一段视频。opts 由 main.gd 从剧本指令翻译而来：
##   at / size / fade / volume / loop / speed / hide
## 返回 false 表示素材缺失或不是可播放的流（push_warning，不静默降级）。
func play(id: String, opts: Dictionary = {}) -> bool:
	var path := resolve(id)
	if path.is_empty():
		push_warning("[Video] 找不到素材 %s（支持：%s）"
			% [id, ", ".join(VIDEO_EXTENSIONS)])
		return false
	var stream := load(path) as VideoStream
	if stream == null:
		push_warning("[Video] %s 不是可播放的视频流（Godot 只认 Ogg Theora .ogv）" % path)
		return false

	stop(0.0)
	_id = id
	_hide_when_done = bool(opts.get("hide", true))

	var rect := resolve_rect(opts)
	_player.position = rect.position
	_player.size = rect.size
	_player.stream = stream
	_player.buffering_msec = maxi(0, int(opts.get("buffer", DEFAULT_BUFFER_MS)))
	_player.loop = bool(opts.get("loop", false))
	_player.speed_scale = maxf(0.01, float(opts.get("speed", 1.0)))
	_player.volume_db = _volume_to_db(float(opts.get("volume", 1.0)))
	_player.visible = true
	visible = true

	var fade := float(opts.get("fade", 0.0))
	modulate.a = 0.0 if fade > 0.0 else 1.0
	if fade > 0.0:
		_fade_tween = create_tween()
		_fade_tween.tween_property(self, "modulate:a", 1.0, fade)

	_player.play()
	return true


## 淡出并停止。duration <= 0 立刻收掉。
func stop(duration: float = 0.3) -> void:
	_kill_fade()
	if _player != null and _player.is_playing():
		_player.stop()
	if _player != null:
		_player.visible = false
	_id = ""

	if not visible or duration <= 0.0:
		visible = false
		modulate.a = 1.0
		return
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", 0.0, duration)
	_fade_tween.tween_callback(func() -> void: visible = false)


func is_playing() -> bool:
	return visible and _player != null and _player.is_playing()


## 立刻归零。读档 / 回标题 / 重播 / 回滚用 —— 那些都是「跳到别处」，
## 残留一段视频会一直压在画面上。
func clear() -> void:
	stop(0.0)


func get_video_id() -> String:
	return _id


## 供自动化测试 / 调试使用：当前播放位置（秒）。
## 名字不能叫 get_position —— Control 已经有同名方法，覆盖会编译失败。
func get_playback_position() -> float:
	return 0.0 if _player == null else _player.stream_position


func get_player() -> VideoStreamPlayer:
	return _player


func get_target_rect() -> Rect2:
	if _player == null:
		return Rect2()
	return Rect2(_player.position, _player.size)


# ---------------------------------------------------------------------------
# 素材解析（也供剧本审计用）
# ---------------------------------------------------------------------------

## 返回可用的视频路径，找不到返回空串。
static func resolve(id: String) -> String:
	if id.is_empty():
		return ""
	for ext in VIDEO_EXTENSIONS:
		var path := video_root() + id + "." + ext
		if ResourceLoader.exists(path):
			return path
	return ""


## 供自动化测试注入的视频根目录。留空 = VIDEO_DIR。
##
## 和 PlaceholderAssets.sprite_root_override 同一个用意：验证「真机播 .ogv」
## 需要一段测试视频，指向 tools/fixtures/video/ 就不必往 assets/video/ 里
## 塞演示素材。
static var video_root_override: String = ""


static func video_root() -> String:
	return VIDEO_DIR if video_root_override.is_empty() else video_root_override


static func has_video(id: String) -> bool:
	return not resolve(id).is_empty()


static func known_extensions() -> PackedStringArray:
	return VIDEO_EXTENSIONS.duplicate()


## 把 at / size 解析成设计分辨率下的矩形。
##
##   at=full       铺满整屏（默认）
##   at=center     按目标尺寸居中；没写 size 时按整屏居中
##   at=320,180    左上角坐标
##   size=640,360  显式尺寸
##
## 静态函数：便于单测，不需要实例。
static func resolve_rect(opts: Dictionary) -> Rect2:
	var pos := Vector2.ZERO
	var size := DESIGN
	var at := String(opts.get("at", "full")).strip_edges().to_lower()
	if at == "center":
		pos = DESIGN * 0.5
		size = DESIGN
	elif at != "full" and not at.is_empty():
		var parts := at.split(",")
		if parts.size() >= 2:
			pos = Vector2(float(parts[0]), float(parts[1]))
		else:
			push_warning("[Video] at=%s 看不懂，按 at=full 处理（可用 full / center / x,y）" % at)
	if opts.has("size"):
		var sp := String(opts["size"]).split(",")
		if sp.size() >= 2:
			size = Vector2(float(sp[0]), float(sp[1]))
	if at == "center":
		pos -= size * 0.5
	return Rect2(pos, size)


# ---------------------------------------------------------------------------
# 内部
# ---------------------------------------------------------------------------

func _on_stream_finished() -> void:
	var done := _id
	if _hide_when_done:
		stop(0.0)
	finished.emit(done)


func _kill_fade() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null


## 线性音量 0~1 → dB。0 视作静音。
static func _volume_to_db(volume: float) -> float:
	var v := clampf(volume, 0.0, 1.0)
	return -80.0 if v <= 0.0001 else linear_to_db(v)
