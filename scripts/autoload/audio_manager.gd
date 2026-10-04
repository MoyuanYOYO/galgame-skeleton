extends Node

## 音频管理器（Autoload）
##
## 统一调度 BGM / SE / 语音。核心设计：**素材缺失时静默降级**。
## 骨架阶段 assets/audio/ 下没有任何音频文件，此时所有播放请求
## 都会被安全忽略并只在控制台提示一次，不会中断游戏流程。
## 把同名文件（ogg / mp3 / wav 任一）丢进对应目录即可自动生效。
##
## 三条音轨各自一条独立总线（`BGM` / `SE` / `Voice`），都汇入 `Master`。
## 分开的理由有两条：一是三类音量本来就该分开调；二是**效果器要能按轨施加**
## ——「这句台词的时候音乐出故障」不该把音效一起弄坏。
## 总线由 `_setup_buses()` 在启动时建好（幂等），效果器由 `apply_audio_fx()` 挂载。

## 当前 BGM 放完一遍时发出。**只在不循环的流上才会触发** ——
## 剧本 BGM 一律循环（放完就静音是 bug），所以这条信号实际专供音乐鉴赏，
## 用来决定「该单曲重播还是切下一首」。
signal bgm_finished()

const BGM_DIR := "res://assets/audio/bgm/"
const SE_DIR := "res://assets/audio/se/"
const VOICE_DIR := "res://assets/audio/voice/"
const AUDIO_EXTENSIONS: PackedStringArray = ["ogg", "mp3", "wav"]
const SE_POOL_SIZE := 6
const SILENT_DB := -60.0
## 起播后这段时间内收到的 `finished` 一律当成「上一次播放的补报」丢掉，见
## `_on_bgm_player_finished`。300ms 是拍出来的：补报实测在起播后约一帧（15ms），
## 而本项目最短的曲子（tension.wav）有 38 秒，中间差着两个数量级，不会误伤。
const BGM_FINISH_SETTLE_MS := 300

## 三条音轨的总线名
const BGM_BUS_NAME := "BGM"
const SE_BUS_NAME := "SE"
const VOICE_BUS_NAME := "Voice"

## BGM 总线上的频谱分析器固定占 0 号位 —— 我们自己加的效果器一律从后面追加，
## 清理时按对象身份找下标，绝不 `remove_bus_effect(idx, 0)`。
const SPECTRUM_MIN_HZ := 40.0
const SPECTRUM_MAX_HZ := 12000.0

## 剧本 / 内联标签里写「哪条音轨」时用的名字 → 真实总线名。
## `all` 展开成三条（含 Master？不含 —— Master 上挂效果会把 UI 音效也带进去）。
const FX_TRACKS := {
	"bgm": BGM_BUS_NAME,
	"music": BGM_BUS_NAME,
	"se": SE_BUS_NAME,
	"sfx": SE_BUS_NAME,
	"voice": VOICE_BUS_NAME,
	"vo": VOICE_BUS_NAME,
	"all": "",
	"master": "Master",
}
## 可用的效果器种类见 `AudioFxSpec.KINDS`（唯一清单，解析器 / 运行时 / 编辑器共用）
## 角色静音列表存在配置里的键
const CONFIG_MUTED_VOICES := "muted_voices"

## 打字音的合成参数。没有真实素材时用它，保证「开箱就有手感」。
const TYPING_SFX_ID := "type"
const TYPING_SFX_RATE := 22050
const TYPING_SFX_SECONDS := 0.028
## 合成用的固定种子 —— 每次生成同一个音，不会每次启动听起来都不一样
const TYPING_SFX_SEED := 0x7A9C1B

var _bgm_player: AudioStreamPlayer
var _voice_player: AudioStreamPlayer
var _se_pool: Array[AudioStreamPlayer] = []
var _se_cursor: int = 0
var _bgm_id: String = ""
var _bgm_linear: float = 0.8
## 当前这条 BGM 是否在「流层面」循环。剧本要循环，音乐鉴赏不能循环
## （不循环才收得到 finished，才知道该切下一首）。
var _bgm_looping: bool = true
## 本次 BGM 起播的时刻（毫秒），用来识别切歌后引擎补报的那次 finished。
var _bgm_started_ms: int = 0
var _bgm_tween: Tween
var _stream_cache: Dictionary = {}
var _warned: Dictionary = {}
var _last_se_id: String = ""
var _spectrum: AudioEffectInstance = null

## 语音待播队列。同一句里连写多条 `voice` 时，后写的排在前一条后面依次播完。
var _voice_queue: Array = []
## 语音通道是否「占着」。没有素材时也算——那是「立刻播完」的短暂占用。
var _voice_active: bool = false
var _voice_id: String = ""

## 被玩家静音的角色 id（语音 id 的 `<角色>/` 前缀）
var _muted: Dictionary = {}

## 效果器状态：总线名 → 我们加上去的效果器数组 / 种类 / 到期时刻 / 抖动参数
var _fx_effects: Dictionary = {}
var _fx_kind: Dictionary = {}
var _fx_expiry: Dictionary = {}
var _fx_jitter: Dictionary = {}

## 打字音：真实素材（assets/audio/se/type.*）只在第一次用时查一次
var _typing_override_checked: bool = false
var _typing_override: AudioStream = null
## 内置合成的打字音（懒生成）
var _typing_stream: AudioStreamWAV = null

## BGM 压低（ducking）：目标 dB 与动画
var _duck_db: float = 0.0
var _duck_tween: Tween


func _ready() -> void:
	set_process(false)
	_setup_buses()
	_load_muted_from_config()

	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.name = "BgmPlayer"
	_bgm_player.bus = BGM_BUS_NAME
	# 只有「不循环」的流放完才会触发，详见 bgm_finished 的声明
	_bgm_player.finished.connect(_on_bgm_player_finished)
	add_child(_bgm_player)

	_voice_player = AudioStreamPlayer.new()
	_voice_player.name = "VoicePlayer"
	_voice_player.bus = VOICE_BUS_NAME
	# 播完自然接上队列里的下一条。注意 stop() 不会触发它 ——
	# 手动停止（换句 / 回标题）走的是 stop_voice()，那里自己清队列。
	_voice_player.finished.connect(_finish_voice)
	add_child(_voice_player)

	for i in SE_POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.name = "SePlayer%d" % i
		player.bus = SE_BUS_NAME
		add_child(player)
		_se_pool.append(player)

	ConfigManager.config_changed.connect(_on_config_changed)


## 建三条音轨总线，并给 BGM 挂频谱分析器。幂等 —— 总线已存在时复用，
## 不重复添加效果器（否则每次重进都会多一层分析器）。
func _setup_buses() -> void:
	for bus_name in [BGM_BUS_NAME, SE_BUS_NAME, VOICE_BUS_NAME]:
		var index := AudioServer.get_bus_index(bus_name)
		if index == -1:
			AudioServer.add_bus()
			index = AudioServer.bus_count - 1
			AudioServer.set_bus_name(index, bus_name)
		AudioServer.set_bus_send(index, &"Master")

	var bgm_index := AudioServer.get_bus_index(BGM_BUS_NAME)
	if bgm_index >= 0 and AudioServer.get_bus_effect_count(bgm_index) == 0:
		var analyzer := AudioEffectSpectrumAnalyzer.new()
		analyzer.buffer_length = 0.1
		analyzer.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
		AudioServer.add_bus_effect(bgm_index, analyzer)

	if bgm_index >= 0:
		_spectrum = AudioServer.get_bus_effect_instance(bgm_index, 0)


## 读取当前 BGM 的频谱幅度（0~1，未归一化）。没有音频在播时返回全 0。
## 索引 0 = 低频，末位 = 高频。
##
## **目前没有调用方** —— 音乐鉴赏的唱片 / 频谱可视化已经拿掉，界面侧不再需要。
## 保留是因为 BGM 总线本身是合理的路由分离（BGM 与 SE / 语音分开调音量），
## 而频谱接口随时能接回来。要用的话注意一句：暂停时 playing 读回 false，
## 下面那道 `not _bgm_player.playing` 会把暂停判成「没在播」—— 若将来要做
## 「暂停时定格波形」，得改用 is_bgm_paused() 判断。
func get_spectrum_magnitudes(bars: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(bars)
	if bars <= 0 or _spectrum == null or not _bgm_player.playing:
		return out
	var span := SPECTRUM_MAX_HZ / SPECTRUM_MIN_HZ
	for i in bars:
		var f0 := SPECTRUM_MIN_HZ * pow(span, float(i) / float(bars))
		var f1 := SPECTRUM_MIN_HZ * pow(span, float(i + 1) / float(bars))
		var magnitude: Vector2 = _spectrum.get_magnitude_for_frequency_range(f0, f1)
		out[i] = clampf(magnitude.length(), 0.0, 1.0)
	return out


# ---------------------------------------------------------------------------
# BGM
# ---------------------------------------------------------------------------

## 播放 BGM。`loop = false` 时流不循环，放完会发 bgm_finished（音乐鉴赏用）。
func play_bgm(id: String, volume: float = 0.8, fade: float = 1.0, loop: bool = true) -> void:
	# 解锁必须放在防重入**之前**。它记的是「剧本到达了会播这首曲子的剧情点」，
	# 跟「这一次是不是真的重新起播」无关。放在后面的话，同一首正好在放时
	# 再被点名一次就不会解锁 —— smoke 的「剧本 bgm 指令解锁了 daily」
	# 曾经因此变红（前一个章节已经把 daily 放上了）。
	# 即使当前没有音频文件（骨架阶段）也照样解锁。
	if not id.is_empty() and id != "stop":
		CollectionManager.unlock("music", id)

	# 防重入要把「暂停中」一起挡上：暂停时 playing 读回 false，
	# 只判 playing 会让「暂停后再收到同一条播放指令」重新从头播。
	if id == _bgm_id:
		if _bgm_player.stream_paused:
			# 同一首正暂停着，而剧本要它响 —— 那是「恢复」，不是「重播」
			resume_bgm()
			return
		if _bgm_player.playing:
			return
	_kill_bgm_tween()
	_bgm_looping = loop

	if id.is_empty() or id == "stop":
		_bgm_id = ""
		# 顺手清掉暂停标记，否则下一首起播就带着「暂停」状态
		_bgm_player.stream_paused = false
		if fade > 0.01 and _bgm_player.playing:
			_bgm_tween = create_tween()
			_bgm_tween.tween_property(_bgm_player, "volume_db", SILENT_DB, fade)
			_bgm_tween.tween_callback(_bgm_player.stop)
		else:
			_bgm_player.stop()
		return

	_bgm_id = id
	_bgm_linear = clampf(volume, 0.0, 1.0)
	_bgm_player.stream_paused = false

	var stream := _find_stream(BGM_DIR, id)
	if stream == null:
		return

	if _bgm_player.playing and fade > 0.01:
		_bgm_tween = create_tween()
		_bgm_tween.tween_property(_bgm_player, "volume_db", SILENT_DB, fade * 0.5)
		_bgm_tween.tween_callback(_swap_bgm_stream.bind(stream))
		_bgm_tween.tween_property(_bgm_player, "volume_db", _target_bgm_db(), fade * 0.5)
	else:
		_swap_bgm_stream(stream)
		_bgm_player.volume_db = _target_bgm_db()


func stop_bgm(fade: float = 1.0) -> void:
	play_bgm("", 0.0, fade)


func get_bgm_id() -> String:
	return _bgm_id


# ---------------------------------------------------------------------------
# 播放控制（供音乐鉴赏使用）
# ---------------------------------------------------------------------------

func pause_bgm() -> void:
	# 这里用 playing 当条件是**对的**：问的是「现在真的在出声吗」。
	# 暂停态下 playing 已是 false，重复调用自然变成空操作。
	if _bgm_player.playing:
		_bgm_player.stream_paused = true


func resume_bgm() -> void:
	# **不能加 `if _bgm_player.playing` 守卫。** 暂停时 playing 是 false，
	# 那道守卫会把恢复整个挡掉 —— 音乐从此卡死在暂停里，只能重新起播。
	# 这是本项目真实踩过的 bug：界面上点「暂停」之后就再也回不去了。
	_bgm_player.stream_paused = false


## 是否处于暂停。
##
## **不能用 playing 打头**：Godot 的 AudioStreamPlayer 在 `stream_paused = true`
## 时 `playing` 读回 **false**，写成 `playing and stream_paused` 会恒为 false，
## 于是「暂停中」被误判成「没在播」—— 面板据此显示「播放」并在下一次点击时
## 直接重新起播，玩家看到的就是「点暂停变成了停止」。
func is_bgm_paused() -> bool:
	return _bgm_player.stream_paused


## 只「能听见」才算在播（暂停时返回 false）
func is_bgm_audible() -> bool:
	return _bgm_player.playing and not _bgm_player.stream_paused


## 当前播放位置（秒）。
##
## 同样不要拿 playing 当闸门：暂停时它为 false，挡一道就会让进度条归零，
## 而引擎其实把位置留得好好的（实测暂停后 get_playback_position 照常返回）。
func get_bgm_position() -> float:
	if _bgm_id.is_empty():
		return 0.0
	return _bgm_player.get_playback_position()


## 跳到指定秒数（音乐鉴赏的进度条）。暂停中也能跳，seek 只改位置、不动暂停状态。
func seek_bgm(seconds: float) -> void:
	if _bgm_id.is_empty() or _bgm_player.stream == null:
		return
	var length := get_bgm_length()
	var target := seconds if length <= 0.0 else clampf(seconds, 0.0, length)
	_bgm_player.seek(target)


func get_bgm_length() -> float:
	var stream := _bgm_player.stream
	if stream == null:
		return 0.0
	return stream.get_length()


## 该曲目在 assets/audio/bgm/ 下是否存在真实文件
func has_bgm_asset(id: String) -> bool:
	return _find_stream(BGM_DIR, id) != null


## 该音效在 assets/audio/se/ 下是否存在真实文件。
## 配置里写错 id 时会静默无声，所以测试要能提前查出这种问题。
func has_se_asset(id: String) -> bool:
	if id.is_empty():
		return false
	return _find_stream(SE_DIR, id) != null


## 最近一次「真正播放」的音效 id。供测试与调试用 ——
## 能验证「按钮按下 → 音效发出」这条链路是通的，而不只是连接挂上了。
func get_last_se_id() -> String:
	return _last_se_id


func clear_last_se() -> void:
	_last_se_id = ""


func _swap_bgm_stream(stream: AudioStream) -> void:
	if _bgm_player.stream == stream and _bgm_player.playing:
		return
	enable_stream_loop(stream, _bgm_looping)
	_bgm_player.stream = stream
	_bgm_player.volume_db = SILENT_DB
	# play() 默认从 0 秒起，所以「同一首再来一遍」（单曲循环 / 重播）
	# 走的也是这条路，不需要额外的 seek(0)。
	_bgm_player.play()
	_bgm_started_ms = Time.get_ticks_msec()


## 把引擎的 `finished` 规整成一条可靠的业务信号。这里要处理两件引擎怪癖：
##
## **一、切歌后引擎会补报一次「上一次的结束」。** 实测（tools/music_probe 的 C 段）：
## 切歌时 `stream` 被替换并立即 `play()`，但新流的 playback 在 AudioServer 那边
## 还没注册成 active，下一帧（约 15ms 后）`finished` 会**再报一次**。而这次补报的
## 引擎状态和「真的放完」**一模一样** —— `playing = false`、播放位置归零、
## `get_bgm_length()` 读出来已经是新流的长度，光看状态区分不了。唯一可靠的差别是
## 时间：补报发生在起播后一帧，而本项目最短的曲子也有 38 秒。
## 不挡的后果：上游据此切下一首会**连跳两首** ——
## 现象是「列表循环放完主题曲直接落到终曲」（中间那首被吃掉了）。
##
## **二、不能在 `finished` 里同步换流。** Godot 是在 `NOTIFICATION_INTERNAL_PROCESS`
## 里发这个信号的，在这一刻改 `stream` 再 `play()`，**WAV 那首起不来**
## （实测：切过去后 `playing` 恒为 false、位置停在 0；同样的动作换成 ogg 就正常，
## 在普通帧里换到 WAV 也正常）。所以信号本身延后一帧发出去 ——
## 上游收到时已经离开了那个通知，换流就能落地。
## 顺带这也让「补报」稳定地排在切歌之前，上面那道时间闸门才拦得住。
func _on_bgm_player_finished() -> void:
	var now := Time.get_ticks_msec()
	if now - _bgm_started_ms < BGM_FINISH_SETTLE_MS:
		return
	# 刷新计时起点，用来挡住紧随其后的那次补报
	_bgm_started_ms = now
	_emit_bgm_finished.call_deferred()


func _emit_bgm_finished() -> void:
	bgm_finished.emit()


## 打开 / 关闭一条音频流的循环。
##
## 为什么不能一行搞定：Godot 三种音频流的「循环」字段名字不一样 ——
## Ogg / MP3 是 `loop`（bool），WAV 是 `loop_mode`（枚举）。
## 素材缺失时这个问题完全看不出来，一放进真实 BGM 就会「播完就没了」，
## 所以这里按属性探测，而不是写死某个类型。
##
## `on = false` 给音乐鉴赏用：不循环才收得到 finished，才知道该切哪一首。
## 注意改的是**流资源本身**，而流在 `_stream_cache` 里是共享的 ——
## 所以每次起播前都要显式设一遍，不能假设上一轮的值还在。
##
## **WAV 光设 `loop_mode` 还不够。** 它的循环区间是 `loop_begin` / `loop_end`，
## 导入时若 `edit/loop_mode=0`（默认就是这样），区间是空的（0 / -1）。
## 这时把 `loop_mode` 设成 LOOP_FORWARD，播放**会立刻结束** ——
## 症状是「这首曲子根本放不出来」：`playing` 恒为 false、位置停在 0，
## 而且不报任何错。所以打开循环时必须把空区间补成整段。
static func enable_stream_loop(stream: AudioStream, on: bool = true) -> void:
	if stream == null:
		return
	if "loop" in stream:
		stream.set("loop", on)
		return
	var wav := stream as AudioStreamWAV
	if wav == null:
		return
	if on and wav.loop_end <= wav.loop_begin:
		wav.loop_begin = 0
		# 帧数 = 时长 × 采样率。对 8/16bit、单双声道都成立，
		# 因为 get_length() 的分母正好是「每帧字节数」。
		wav.loop_end = int(round(wav.get_length() * float(wav.mix_rate)))
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD if on else AudioStreamWAV.LOOP_DISABLED


func _kill_bgm_tween() -> void:
	if _bgm_tween != null and _bgm_tween.is_valid():
		_bgm_tween.kill()


# ---------------------------------------------------------------------------
# SE / 语音
# ---------------------------------------------------------------------------

func play_se(id: String, volume: float = 1.0) -> void:
	var stream := _find_stream(SE_DIR, id)
	if stream == null or _se_pool.is_empty():
		return
	_last_se_id = id
	var player := _se_pool[_se_cursor]
	_se_cursor = (_se_cursor + 1) % _se_pool.size()
	player.stream = stream
	player.volume_db = _to_db(clampf(volume, 0.0, 1.0) * _master() * _config_float("se_volume", 0.9))
	player.play()


## 打字机音效（每 N 个字响一次，由对话框调用）。
##
## 素材查找顺序：
##   1. `assets/audio/se/type.<ogg|mp3|wav>` —— 作者放了真素材就用它
##   2. 内置**合成**的短促点击音 —— 骨架阶段没有素材也开箱有手感
## 两者都没有「静默无声」这种情况，所以不必像 `play_se` 那样降级。
##
## 关掉：设置里的「打字音效」开关（配置键 `text_sfx`）。
func play_typing() -> void:
	if not bool(ConfigManager.get_value("text_sfx", true)):
		return
	if _se_pool.is_empty():
		return
	if not _typing_override_checked:
		_typing_override_checked = true
		for ext in AUDIO_EXTENSIONS:
			var path := SE_DIR + TYPING_SFX_ID + "." + ext
			if ResourceLoader.exists(path):
				_typing_override = load(path) as AudioStream
				break
	var stream: AudioStream = _typing_override
	if stream == null:
		if _typing_stream == null:
			_typing_stream = _make_typing_stream()
		stream = _typing_stream

	_last_se_id = TYPING_SFX_ID
	var player := _se_pool[_se_cursor]
	_se_cursor = (_se_cursor + 1) % _se_pool.size()
	player.stream = stream
	player.volume_db = _to_db(clampf(float(ConfigManager.get_value("text_sfx_volume", 0.45)),
		0.0, 1.0) * _master() * _config_float("se_volume", 0.9))
	player.play()


## 合成一段「机械键盘轻敲」：指数衰减的噪声 + 一点低频体感。
##
## 为什么不直接用 `play_se` 的降级：打字音是**每个字都要响**的高频音效，
## 缺素材时静默无声会让「打字手感」这个功能看起来根本没做。
## 合成一段 28ms 的短音成本极低（几百字节），效果足够。
static func _make_typing_stream() -> AudioStreamWAV:
	var frames := int(TYPING_SFX_RATE * TYPING_SFX_SECONDS)
	var data := PackedByteArray()
	data.resize(frames * 2)                     # 16bit 单声道
	var rng := RandomNumberGenerator.new()
	rng.seed = TYPING_SFX_SEED
	for i in frames:
		var t := float(i) / float(frames)
		var env := pow(1.0 - t, 3.0)            # 快速衰减，不然会拖成「沙沙」声
		var noise := rng.randf_range(-1.0, 1.0)
		var body := sin(TAU * 1800.0 * float(i) / float(TYPING_SFX_RATE)) * 0.35
		var v := clampf((noise * 0.75 + body) * env * 0.5, -1.0, 1.0)
		data.encode_s16(i * 2, int(v * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = TYPING_SFX_RATE
	wav.stereo = false
	wav.data = data
	return wav


func play_voice(id: String, volume: float = 1.0, queue: bool = false) -> void:
	if id.is_empty():
		return
	_play_voice(id, _find_stream(VOICE_DIR, id), volume, queue)


## 语音队列的内部实现（也是测试入口 —— 骨架阶段没有语音素材，
## 队列逻辑需要能直接塞一条流进来才验证得了）。
##
## queue = true 且当前已有语音在播时，排到它后面；
## 否则立刻开播，并**清掉排队的那些**。
##
## 为什么要分这两种：同一句里连写多条 voice 是想依次听完；
## 而玩家推进到下一句时，上一条语音必须立刻断掉 —— 否则会声画错位，
## 玩家听到的是上一句的台词，看到的却是新的一句。
##
## 队列里连**已解析好的流**一起存，而不是只存 id 到时候再查一次：
## 少一次查找，也让「查过一次找不到」的结果不会被重复清点。
##
## **被静音的角色在这里就被挡掉**（而不是在播放器上设音量）——
## 挡在这里的话，语音既不占队列位置，也不会把正在播的另一条打断。
func _play_voice(id: String, stream: AudioStream, volume: float, queue: bool) -> void:
	if is_voice_muted(_char_of_voice(id)):
		return
	if stream == null:
		# 没有素材：静默跳过 —— 既不占队列位置，也不打断正在播的那一条
		return
	if queue and _voice_active:
		_voice_queue.append({"id": id, "stream": stream, "volume": volume})
		return
	_voice_queue.clear()
	_start_voice(id, stream, volume)


func _start_voice(id: String, stream: AudioStream, volume: float) -> void:
	_voice_active = true
	_voice_id = id
	_voice_player.stream = stream
	_voice_player.volume_db = _to_db(
		clampf(volume, 0.0, 1.0) * _master() * _config_float("voice_volume", 1.0))
	_voice_player.play()
	# 有人在说话 → 把 BGM 压下去（不然两路声音打架，台词听不清）
	duck_bgm(true)


## 当前语音播完了（自然结束）→ 接上队列里的下一条。
func _finish_voice() -> void:
	_voice_active = false
	_voice_id = ""
	while not _voice_queue.is_empty():
		var next: Dictionary = _voice_queue.pop_front()
		var stream := next.get("stream") as AudioStream
		if stream == null:
			continue
		# 排队期间角色可能被静音了 —— 出队时再判一次
		if is_voice_muted(_char_of_voice(String(next.get("id", "")))):
			continue
		_start_voice(String(next.get("id", "")), stream, float(next.get("volume", 1.0)))
		return
	# 整个队列都空了 → 放开 BGM
	duck_bgm(false)


func stop_voice() -> void:
	_voice_queue.clear()
	_voice_active = false
	_voice_id = ""
	_voice_player.stop()
	duck_bgm(false)


# ---------------------------------------------------------------------------
# BGM 压低（ducking）
# ---------------------------------------------------------------------------

## 压低 / 放开 BGM。
##
## 走的是**总线音量**（`AudioServer.set_bus_volume_db`），不是播放器的 `volume_db` ——
## 后者被淡入淡出（`_bgm_tween`）占着，两者同时写会互相打架
## （表现为「切歌淡入到一半突然跳回原音量」）。总线音量只被 ducking 一个人写，
## 而且天然叠在淡入淡出之上。
##
## 关掉：设置里的「对白时压低音乐」（配置键 `duck_bgm`）。
func duck_bgm(on: bool) -> void:
	var target := 0.0
	if on and bool(ConfigManager.get_value("duck_bgm", true)):
		target = -absf(float(ConfigManager.get_value("duck_db", 12.0)))
	_set_bus_duck(target)


## 当前压低目标（dB，<= 0）。供测试 / 调试 —— 动画是异步的，这里读的是**目标值**。
func get_bgm_duck_db() -> float:
	return _duck_db


func is_bgm_ducked() -> bool:
	return _duck_db < -0.01


func _set_bus_duck(target_db: float) -> void:
	var index := AudioServer.get_bus_index(BGM_BUS_NAME)
	if index < 0:
		return
	if is_equal_approx(_duck_db, target_db) and _duck_tween != null and _duck_tween.is_valid():
		return
	if _duck_tween != null and _duck_tween.is_valid():
		_duck_tween.kill()
	# 压下去要快（不能等半秒才让台词听清），放开要慢（不然像音量跳变）
	var duration := maxf(0.01, float(ConfigManager.get_value(
		"duck_attack" if target_db < _duck_db else "duck_release", 0.12)))
	_duck_db = target_db
	_duck_tween = create_tween()
	_duck_tween.tween_method(
		func(v: float) -> void: AudioServer.set_bus_volume_db(index, v),
		AudioServer.get_bus_volume_db(index), target_db, duration)


## ---- 供播放控制 / 自动化测试查询 ----

func is_voice_active() -> bool:
	return _voice_active


## 当前正在播的语音 id（空闲时为空串）
func get_voice_id() -> String:
	return _voice_id


## 还有几条语音排着队
func get_voice_queue_size() -> int:
	return _voice_queue.size()


## 供自动化测试 / 调试：绕过素材查找，直接往语音通道送一条流（stream 可为 null）。
func voice_channel(id: String, stream: AudioStream, volume: float = 1.0,
		queue: bool = false) -> void:
	_play_voice(id, stream, volume, queue)


## 供自动化测试 / 调试：模拟「当前这条语音播完了」。
func notify_voice_finished() -> void:
	_finish_voice()


# ---------------------------------------------------------------------------
# 角色静音
# ---------------------------------------------------------------------------

## 语音 id 是 `<角色>/<台词>`（见 README 的语音两级目录约定），
## 取斜杠前那一段就是角色 id。没有斜杠时整段当角色 id —— 那种 id 本来
## 也不会跟别的角色撞车。
static func _char_of_voice(id: String) -> String:
	if id.is_empty():
		return ""
	var slash := id.find("/")
	return id if slash < 0 else id.substr(0, slash)


func is_voice_muted(char_id: String) -> bool:
	if char_id.is_empty():
		return false
	return _muted.has(char_id)


func set_voice_muted(char_id: String, muted: bool) -> void:
	if char_id.is_empty():
		return
	if muted:
		_muted[char_id] = true
	else:
		_muted.erase(char_id)
	# 刚被静音的角色如果正在说 / 排队说，立刻掐掉，不然要等到下一句才生效
	if muted and _voice_active and _char_of_voice(_voice_id) == char_id:
		stop_voice()
	if muted:
		_drop_queued_voice(char_id)
	_sync_muted_config()


func set_muted_voices(ids: Array) -> void:
	_muted.clear()
	for raw in ids:
		var id := String(raw).strip_edges()
		if not id.is_empty():
			_muted[id] = true
	_sync_muted_config()


func get_muted_voices() -> Array:
	var out: Array = _muted.keys()
	out.sort()
	return out


func clear_muted_voices() -> void:
	_muted.clear()
	_sync_muted_config()


func _drop_queued_voice(char_id: String) -> void:
	var kept: Array = []
	for entry in _voice_queue:
		var d: Dictionary = entry
		if _char_of_voice(String(d.get("id", ""))) != char_id:
			kept.append(d)
	_voice_queue = kept


func _sync_muted_config() -> void:
	ConfigManager.set_value(CONFIG_MUTED_VOICES, get_muted_voices())


func _load_muted_from_config() -> void:
	_muted.clear()
	var raw: Variant = ConfigManager.get_value(CONFIG_MUTED_VOICES, [])
	if typeof(raw) != TYPE_ARRAY:
		return
	for id in (raw as Array):
		var s := String(id).strip_edges()
		if not s.is_empty():
			_muted[s] = true


# ---------------------------------------------------------------------------
# 音频效果器
# ---------------------------------------------------------------------------

## 给某条音轨挂一个效果器。
##
##   bus      —— "bgm" / "se" / "voice" / "all" / "master"（大小写无所谓）
##   kind     —— 见 FX_KINDS；"none" / "off" / "clear" 等于清除
##   opts     —— {duration: 秒（0 = 持续到显式清除）, strength: 强度, pitch: 移调倍数}
##
## 同一音轨上**我们加的效果器是互斥的**：新的一次会先清掉上一次，
## 避免「故障叠着失真」把声音糊成一团、也避免链越挂越长。
## 频谱分析器在 BGM 总线 0 号位，不参与清理。
##
## 返回是否成功（音轨名不认识时 push_warning 并返回 false，不静默吞掉）。
func apply_audio_fx(bus: String, kind: String, opts: Dictionary = {}) -> bool:
	var k := kind.strip_edges().to_lower()
	if k.is_empty():
		return false
	if AudioFxSpec.is_clear(k):
		clear_audio_fx(bus)
		return true
	if not AudioFxSpec.is_valid_kind(k):
		push_warning("[Audio] 未知效果器 %s（可用：%s）" % [kind, AudioFxSpec.list_text()])
		return false
	var targets := _resolve_fx_buses(bus)
	if targets.is_empty():
		push_warning("[Audio] 未知音轨 %s（可用：%s）" % [bus, AudioFxSpec.tracks_text()])
		return false

	var duration := maxf(0.0, float(opts.get("duration", 0.0)))
	var strength := float(opts.get("strength", 1.0))
	var pitch := maxf(0.01, float(opts.get("pitch", 1.0)))
	for name in targets:
		_install_fx(name, k, strength, pitch)
		_fx_expiry[name] = Time.get_ticks_msec() + int(duration * 1000.0) if duration > 0.0 else 0
	set_process(true)
	return true


## 清掉某条音轨上我们加过的效果器（"all" 清三条）。
func clear_audio_fx(bus: String = "all") -> void:
	for name in _resolve_fx_buses(bus):
		var index := AudioServer.get_bus_index(name)
		if index < 0:
			continue
		for effect in (_fx_effects.get(name, []) as Array):
			_remove_effect(index, effect as AudioEffect)
		_fx_effects.erase(name)
		_fx_kind.erase(name)
		_fx_expiry.erase(name)
		_fx_jitter.erase(name)
	if _fx_jitter.is_empty():
		set_process(false)


func clear_all_audio_fx() -> void:
	clear_audio_fx("all")
	clear_audio_fx("master")


## 当前音轨上挂的效果器种类（没挂返回空串）。供测试 / 调试。
func get_audio_fx(bus: String) -> String:
	var targets := _resolve_fx_buses(bus)
	if targets.is_empty():
		return ""
	return String(_fx_kind.get(targets[0], ""))


## 全部音轨上的效果器状态：{总线名: 种类}
func get_audio_fx_state() -> Dictionary:
	return _fx_kind.duplicate()


func _resolve_fx_buses(bus: String) -> PackedStringArray:
	var key := bus.strip_edges().to_lower()
	if not FX_TRACKS.has(key):
		return PackedStringArray()
	if key == "all":
		return PackedStringArray([BGM_BUS_NAME, SE_BUS_NAME, VOICE_BUS_NAME])
	return PackedStringArray([String(FX_TRACKS[key])])


## 在总线上装一条（或一组）效果器，并记下抖动参数。
##
## glitch / error 需要「时间片跳变」而不是逐帧随机 —— 逐帧随机会糊成噪音，
## 听不出「数字故障」，只像坏了。所以它们注册进 `_fx_jitter`，
## 由 `_process` 每 90ms 换一次参数。
func _install_fx(bus_name: String, kind: String, strength: float, pitch: float) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	# 先清掉上一次的（互斥），再装新的
	for effect in (_fx_effects.get(bus_name, []) as Array):
		_remove_effect(index, effect as AudioEffect)

	var added: Array = []
	var jitter: Dictionary = {}
	var s := clampf(strength, 0.1, 4.0)

	match kind:
		"glitch":
			var d := AudioEffectDistortion.new()
			d.mode = AudioEffectDistortion.MODE_LOFI
			d.drive = clampf(0.55 + 0.35 * s, 0.0, 1.0)
			d.pre_gain = 6.0 * s
			d.post_gain = -6.0
			d.keep_hf_hz = 8000.0
			added.append(d)
			var ps := AudioEffectPitchShift.new()
			ps.fft_size = AudioEffectPitchShift.FFT_SIZE_512
			ps.pitch_scale = 1.0
			added.append(ps)
			jitter = {"dist": d, "pitch": ps, "strength": s, "last_ms": 0, "step_ms": 90}
		"error":
			var lp := AudioEffectLowPassFilter.new()
			lp.cutoff_hz = 3000.0
			lp.resonance = 0.6
			added.append(lp)
			var d2 := AudioEffectDistortion.new()
			d2.mode = AudioEffectDistortion.MODE_LOFI
			d2.drive = 0.9
			d2.pre_gain = 9.0 * s
			d2.post_gain = -9.0
			d2.keep_hf_hz = 5000.0
			added.append(d2)
			var ps2 := AudioEffectPitchShift.new()
			ps2.fft_size = AudioEffectPitchShift.FFT_SIZE_256
			ps2.pitch_scale = 1.0
			added.append(ps2)
			jitter = {"dist": d2, "pitch": ps2, "lp": lp, "strength": s,
				"last_ms": 0, "step_ms": 60}
		"distortion":
			var d3 := AudioEffectDistortion.new()
			d3.mode = AudioEffectDistortion.MODE_OVERDRIVE
			d3.drive = clampf(0.5 * s, 0.0, 1.0)
			d3.pre_gain = 4.0 * s
			d3.post_gain = -4.0
			added.append(d3)
		"pitch":
			var ps3 := AudioEffectPitchShift.new()
			ps3.fft_size = AudioEffectPitchShift.FFT_SIZE_1024
			ps3.pitch_scale = clampf(pitch if not is_equal_approx(pitch, 1.0) else 1.5,
				0.25, 4.0)
			added.append(ps3)
		"muffle", "underwater":
			var lp2 := AudioEffectLowPassFilter.new()
			lp2.cutoff_hz = 700.0 if kind == "muffle" else 380.0
			lp2.resonance = 0.4
			added.append(lp2)
			if kind == "underwater":
				var rv := AudioEffectReverb.new()
				rv.room_size = 0.7
				rv.damping = 0.6
				rv.wet = 0.35
				rv.dry = 0.85
				added.append(rv)
		"radio":
			var bp := AudioEffectBandPassFilter.new()
			bp.cutoff_hz = 1600.0
			bp.resonance = 0.85
			added.append(bp)
			var d4 := AudioEffectDistortion.new()
			d4.mode = AudioEffectDistortion.MODE_ATAN
			d4.drive = 0.35
			added.append(d4)
		"echo":
			# ⚠️ AudioEffectDelay 里没有 `feedback` 这个属性 —— 回授要显式打开
			# `feedback_active` 并设 `feedback_delay_ms` / `feedback_level_db`。
			# 写成 `feedback = 0.3` 会在运行时报「不存在的属性」而且静默失败。
			var dl := AudioEffectDelay.new()
			dl.dry = 1.0
			dl.tap1_active = true
			dl.tap1_delay_ms = 180.0
			dl.tap1_level_db = -6.0
			dl.feedback_active = true
			dl.feedback_delay_ms = 180.0
			dl.feedback_level_db = clampf(-12.0 + 4.0 * s, -40.0, 0.0)
			dl.feedback_lowpass = 5000.0
			added.append(dl)
		"reverb":
			var rv2 := AudioEffectReverb.new()
			rv2.room_size = clampf(0.4 + 0.15 * s, 0.0, 1.0)
			rv2.damping = 0.5
			rv2.wet = 0.3
			rv2.dry = 0.9
			added.append(rv2)
		"amplify":
			var amp := AudioEffectAmplify.new()
			amp.volume_db = clampf(3.0 * s, 0.0, 24.0)
			added.append(amp)

	for effect in added:
		AudioServer.add_bus_effect(index, effect as AudioEffect)
	_fx_effects[bus_name] = added
	_fx_kind[bus_name] = kind
	if jitter.is_empty():
		_fx_jitter.erase(bus_name)
	else:
		_fx_jitter[bus_name] = jitter


func _remove_effect(index: int, effect: AudioEffect) -> void:
	if effect == null:
		return
	for i in AudioServer.get_bus_effect_count(index):
		if AudioServer.get_bus_effect(index, i) == effect:
			AudioServer.remove_bus_effect(index, i)
			return


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()

	# 到期自动清除（先收集再改，避免边遍历边删）
	for bus_name in _fx_expiry.keys():
		var until := int(_fx_expiry[bus_name])
		if until > 0 and now >= until:
			clear_audio_fx(String(bus_name))

	if _fx_jitter.is_empty():
		set_process(false)
		return

	for bus_name in _fx_jitter.keys():
		var j: Dictionary = _fx_jitter[bus_name]
		var step := int(j.get("step_ms", 90))
		if now - int(j.get("last_ms", 0)) < step:
			continue
		j["last_ms"] = now
		var s := float(j.get("strength", 1.0))
		var dist := j.get("dist") as AudioEffectDistortion
		if dist != null:
			dist.drive = clampf(0.45 + randf() * 0.55 * s, 0.0, 1.0)
		var ps := j.get("pitch") as AudioEffectPitchShift
		if ps != null:
			ps.pitch_scale = clampf(1.0 + randf_range(-0.4, 0.4) * s, 0.25, 4.0)
		var lp := j.get("lp") as AudioEffectLowPassFilter
		if lp != null:
			lp.cutoff_hz = randf_range(500.0, 4000.0)


# ---------------------------------------------------------------------------
# 内部工具
# ---------------------------------------------------------------------------

func _on_config_changed(key: String, _value: Variant) -> void:
	match key:
		"master_volume", "bgm_volume":
			# 暂停时 playing 读回 false —— 只判它会让「暂停中调音量」悄悄不生效
			if _bgm_player.playing or _bgm_player.stream_paused:
				_bgm_player.volume_db = _target_bgm_db()
		"voice_volume":
			if _voice_player.playing:
				_voice_player.volume_db = _to_db(_config_float("voice_volume", 1.0) * _master())
		CONFIG_MUTED_VOICES:
			# 设置面板改了静音列表 → 跟上（自己写的也会走到这里，幂等）
			_load_muted_from_config()


func _target_bgm_db() -> float:
	return _to_db(_bgm_linear * _master() * _config_float("bgm_volume", 0.8))


func _master() -> float:
	return _config_float("master_volume", 1.0)


func _config_float(key: String, fallback: float) -> float:
	return float(ConfigManager.get_value(key, fallback))


static func _to_db(linear: float) -> float:
	if linear <= 0.001:
		return SILENT_DB
	return linear_to_db(clampf(linear, 0.0, 1.0))


## 按 ogg → mp3 → wav 的顺序找素材，找不到返回 null 并只提示一次。
func _find_stream(dir: String, id: String) -> AudioStream:
	if id.is_empty():
		return null
	var cache_key := dir + id
	if _stream_cache.has(cache_key):
		return _stream_cache[cache_key] as AudioStream

	for ext in AUDIO_EXTENSIONS:
		var path := dir + id + "." + ext
		if ResourceLoader.exists(path):
			var stream := load(path) as AudioStream
			if stream != null:
				_stream_cache[cache_key] = stream
				return stream

	_stream_cache[cache_key] = null
	if not _warned.has(cache_key):
		_warned[cache_key] = true
		print("[Audio] 缺少素材，已静默跳过: %s" % cache_key)
	return null
