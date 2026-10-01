class_name ScreenFx
extends ColorRect

## 全屏后处理特效（错乱 / 扭曲 / 马赛克 / 色差 / 反色 / 模糊）
##
## 「全屏」是字面意思：这一层（FxLayer = 30）在 UILayer(10) 与
## MinigameLayer(20) 之上，所以对话框、HUD、小游戏会跟着一起变形。
## 这正是这类演出想要的效果 —— 是「整个世界不对劲」，而不只是背景不对劲。
## 只糊舞台是看得出来的：UI 纹丝不动地浮在扭曲的背景上，像贴纸。
##
## 实现是「一个铺满屏幕的 ColorRect + screen_fx.gdshader」。
## 关键在同层前面那个 BackBufferCopy（VIEWPORT 模式）：它把「到那一刻为止
## 画好的整屏」copy 进 back buffer，shader 再用 hint_screen_texture 读它。
## 没有它就读不到 UI —— 我们用到的屏幕内容比自己画得早，
## 没有 back buffer 就只有一片空白。
##
## 不生效时整层 visible = false，BackBufferCopy 也跟着停：没有特效的时候
## 不该每帧白白做一次全屏拷贝 + 一次全屏采样。

const SHADER_PATH := "res://shaders/screen_fx.gdshader"

## 强度低于这个值就当是关（浮点插值收不到精确的 0）
const EPSILON := 0.0001

var _shader: Shader
var _copy: BackBufferCopy
var _kind: String = ScreenFxSpec.OFF
var _strength: float = 0.0
var _suspended: bool = false
var _tween: Tween


func _ready() -> void:
	# alpha 给 0 是防御性的：万一 shader 加载失败，这一层最多是「透明」，
	# 而不是糊一块白色把整个游戏盖死。
	color = Color(1.0, 1.0, 1.0, 0.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 铺满屏幕。用 FULL_RECT 锚点、offset 保持 0 —— 注意**不要**再给 offset
	# 赋视口尺寸：FULL_RECT 的左右锚点非等值，会把矩形加成两倍宽
	# （记录面板与调试控制台都在这里栽过一次）。
	set_anchors_preset(Control.PRESET_FULL_RECT)

	_shader = load(SHADER_PATH) as Shader
	if _shader == null:
		push_error("[ScreenFx] 着色器加载失败：%s" % SHADER_PATH)
	else:
		var mat := ShaderMaterial.new()
		mat.shader = _shader
		material = mat

	# BackBufferCopy 不在这里建，见 _ensure_copy()。
	_sync_visibility()


# ---------------------------------------------------------------------------
# 对外接口
# ---------------------------------------------------------------------------

## 播放一个特效。返回 false 表示种类不认识（忽略，且不会悄悄变成别的效果）。
##
## duration > 0：脉冲 —— 先快速冲到 strength，再在剩余时长里收回 0。
## duration <= 0：持续 —— 一直挂着，直到 stop() / `screen_fx none` / 新特效 /
##                clear()。想演「整段都在扭曲」就用它。
func play(kind: String, strength: float = 1.0,
		duration: float = ScreenFxSpec.DEFAULT_DURATION) -> bool:
	if kind.is_empty() or kind == ScreenFxSpec.OFF:
		stop()
		return true
	var mode := ScreenFxSpec.mode_of(kind)
	if mode < 0:
		push_warning("[ScreenFx] 未知特效 %s（可用：%s）"
			% [kind, ScreenFxSpec.list_text()])
		return false

	_kill_tween()
	_kind = kind
	var peak := maxf(0.0, strength)

	if duration <= 0.0:
		_apply(mode, peak)
		return true

	# 脉冲：开头 15% 冲上去（错乱要「啪」地一下才有冲击力），剩下 85% 收干净。
	# 收尾用 EASE_IN：越到后面收得越快，不会在最后一刻还挂着明显变形。
	var attack := maxf(0.05, duration * 0.15)
	var release := maxf(0.05, duration - attack)
	_apply(mode, 0.0)
	_tween = create_tween()
	_tween.tween_method(_set_strength.bind(mode), 0.0, peak, attack)
	_tween.tween_method(_set_strength.bind(mode), peak, 0.0, release) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.tween_callback(_on_tween_finished)
	return true


## 直接落到某个状态，不做任何过渡。回滚还原用。
##
## 回滚是「回到那一刻」，那一刻特效本来就是完全体 —— 再播一遍淡入反而是错的
## （会看到一次不该存在的闪烁）。
func restore_fx(kind: String, strength: float) -> void:
	clear()
	var mode := ScreenFxSpec.mode_of(kind)
	if mode < 0 or strength <= EPSILON:
		return
	_kind = kind
	_apply(mode, strength)


## 淡出并关闭。duration <= 0 则立刻关。
func stop(duration: float = 0.25) -> void:
	_kill_tween()
	var mode := ScreenFxSpec.mode_of(_kind)
	if mode < 0 or _strength <= EPSILON or duration <= 0.0:
		clear()
		return
	_tween = create_tween()
	_tween.tween_method(_set_strength.bind(mode), _strength, 0.0, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(_on_tween_finished)


## 立刻归零。新游戏 / 读档 / 回标题 / 重播用 —— 那些都是「跳到别处」，
## 残留一层扭曲会一直糊在新画面上。
func clear() -> void:
	_kill_tween()
	_kind = ScreenFxSpec.OFF
	_strength = 0.0
	_sync_visibility()


## 模态面板（设置 / 存档 / 回看 / 鉴赏…）打开时临时收起。
##
## 特效在 UI 之上，不收起的话面板会跟着一起扭曲，字都看不清 —— 玩家正在
## 读的那一屏，恰恰是最不该被糊掉的。收起只是不显示，强度保留，
## 面板关掉后原样接着演。
func set_suspended(on: bool) -> void:
	if _suspended == on:
		return
	_suspended = on
	_sync_visibility()


# ---------------------------------------------------------------------------
# 供自动化测试 / 调试使用
# ---------------------------------------------------------------------------

func get_kind() -> String:
	return _kind


func get_strength() -> float:
	return _strength


## 特效开着（有强度）。注意这和「此刻画在屏幕上」是两回事 ——
## 被模态面板压住时强度还在，只是不显示，见 is_rendering()。
func is_active() -> bool:
	return _strength > EPSILON


## 此刻真的画在屏幕上（开着，且没被模态面板压住）
func is_rendering() -> bool:
	return visible


func is_suspended() -> bool:
	return _suspended


## 当前种类对应的 shader mode 整数；关闭或未知时返回 -1
func get_mode() -> int:
	return ScreenFxSpec.mode_of(_kind)


## BackBufferCopy 是否开着。不开就读不到 UI 层。
func is_capture_enabled() -> bool:
	return _copy != null and _copy.copy_mode != BackBufferCopy.COPY_MODE_DISABLED


static func known_kinds() -> PackedStringArray:
	return ScreenFxSpec.KINDS.duplicate()


# ---------------------------------------------------------------------------
# 内部
# ---------------------------------------------------------------------------

## 注意参数顺序：这个函数通过 Callable.bind(mode) 传给 Tween.tween_method，
## 而 bind 的参数是**追加在调用参数之后**的，所以 value 在前、mode 在后。
func _set_strength(value: float, mode: int) -> void:
	_apply(mode, value)


func _apply(mode: int, value: float) -> void:
	_strength = maxf(0.0, value)
	_sync_visibility()
	if _strength <= EPSILON:
		return
	var mat := material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("mode", mode)
	mat.set_shader_parameter("strength", _strength)


## 可见性由「有没有强度」和「是不是被模态面板收起」共同决定。
## 两处都要过这里，避免某条路径上 visible 和 BackBufferCopy 不同步 ——
## 那会留下一个「看不见但每帧都在全屏拷贝」的层。
func _sync_visibility() -> void:
	var active := _strength > EPSILON and not _suspended and material != null
	if active:
		# 真要显示时才把 BackBufferCopy 建出来。没特效的时候连这个节点都不存在，
		# 自然也就没有每帧一次的全屏拷贝开销。
		active = _ensure_copy()
	visible = active
	if _copy != null and is_instance_valid(_copy):
		_copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT if active \
			else BackBufferCopy.COPY_MODE_DISABLED


## 惰性建出 BackBufferCopy，放在**同层紧挨着自己的前一个兄弟**位置上。
##
## 两个约束：
##   1. 必须是同层的前一个兄弟 —— 画在它后面的东西才能通过 hint_screen_texture
##      读到「到那时为止画好的整屏」。放在自己后面（或做成子节点）就太晚了，
##      界面读不到自己。
##   2. 不能在 _ready() 里建。场景实例化时父节点正忙着装配子节点，
##      这时候 add_child() 会被拒（"Parent node is busy setting up children"），
##      紧接着 move_child() 也会因为「不是它的子节点」再报一次。
##      改成首次播放时建就避开了整个时序问题。
func _ensure_copy() -> bool:
	if _copy != null and is_instance_valid(_copy):
		return true
	var parent := get_parent()
	if parent == null:
		return false
	_copy = BackBufferCopy.new()
	_copy.name = "ScreenFxCopy"
	_copy.copy_mode = BackBufferCopy.COPY_MODE_DISABLED
	parent.add_child(_copy)
	parent.move_child(_copy, get_index())
	return true


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


func _on_tween_finished() -> void:
	_kind = ScreenFxSpec.OFF
	_tween = null
