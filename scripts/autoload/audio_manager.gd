extends Node

## 音频管理器（Autoload）
##
## 统一调度 BGM / SE / 语音。核心设计：**素材缺失时静默降级**。
## 骨架阶段 assets/audio/ 下没有任何音频文件，此时所有播放请求
## 都会被安全忽略并只在控制台提示一次，不会中断游戏流程。
## 把同名文件（ogg / mp3 / wav 任一）丢进对应目录即可自动生效。

const BGM_DIR := "res://assets/audio/bgm/"
const SE_DIR := "res://assets/audio/se/"
const VOICE_DIR := "res://assets/audio/voice/"
const AUDIO_EXTENSIONS: PackedStringArray = ["ogg", "mp3", "wav"]
const SE_POOL_SIZE := 6
const SILENT_DB := -60.0

## BGM 走独立总线，挂一个频谱分析效果器供音乐鉴赏的可视化读取
const BGM_BUS_NAME := "BGM"
const SPECTRUM_MIN_HZ := 40.0
const SPECTRUM_MAX_HZ := 12000.0

var _bgm_player: AudioStreamPlayer
var _voice_player: AudioStreamPlayer
var _se_pool: Array[AudioStreamPlayer] = []
var _se_cursor: int = 0
var _bgm_id: String = ""
var _bgm_linear: float = 0.8
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


func _ready() -> void:
	_setup_bgm_bus()

	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.name = "BgmPlayer"
	_bgm_player.bus = BGM_BUS_NAME
	add_child(_bgm_player)

	_voice_player = AudioStreamPlayer.new()
	_voice_player.name = "VoicePlayer"
	# 播完自然接上队列里的下一条。注意 stop() 不会触发它 ——
	# 手动停止（换句 / 回标题）走的是 stop_voice()，那里自己清队列。
	_voice_player.finished.connect(_finish_voice)
	add_child(_voice_player)

	for i in SE_POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.name = "SePlayer%d" % i
		add_child(player)
		_se_pool.append(player)

	ConfigManager.config_changed.connect(_on_config_changed)


## 建一条 BGM 总线并挂频谱分析器。总线已存在时复用，不重复添加效果器。
func _setup_bgm_bus() -> void:
	var bus_index := AudioServer.get_bus_index(BGM_BUS_NAME)
	if bus_index == -1:
		AudioServer.add_bus()
		bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_index, BGM_BUS_NAME)
	AudioServer.set_bus_send(bus_index, &"Master")

	if AudioServer.get_bus_effect_count(bus_index) == 0:
		var analyzer := AudioEffectSpectrumAnalyzer.new()
		analyzer.buffer_length = 0.1
		analyzer.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
		AudioServer.add_bus_effect(bus_index, analyzer)

	_spectrum = AudioServer.get_bus_effect_instance(bus_index, 0)


## 读取当前 BGM 的频谱幅度（0~1，未归一化）。没有音频在播时返回全 0。
## 索引 0 = 低频，末位 = 高频。
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

func play_bgm(id: String, volume: float = 0.8, fade: float = 1.0) -> void:
	if id == _bgm_id and _bgm_player.playing:
		return
	_kill_bgm_tween()

	if id.is_empty() or id == "stop":
		_bgm_id = ""
		if fade > 0.01 and _bgm_player.playing:
			_bgm_tween = create_tween()
			_bgm_tween.tween_property(_bgm_player, "volume_db", SILENT_DB, fade)
			_bgm_tween.tween_callback(_bgm_player.stop)
		else:
			_bgm_player.stop()
		return

	_bgm_id = id
	_bgm_linear = clampf(volume, 0.0, 1.0)

	# 剧本播放到某首曲子 = 玩家「听到了」= 解锁进音乐鉴赏。
	# 即使当前没有对应音频文件（骨架阶段）也照样解锁，
	# 语义是「到达了会播放这首曲子的剧情点」。
	CollectionManager.unlock("music", id)

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
	if _bgm_player.playing:
		_bgm_player.stream_paused = true


func resume_bgm() -> void:
	if _bgm_player.playing:
		_bgm_player.stream_paused = false


func is_bgm_paused() -> bool:
	return _bgm_player.playing and _bgm_player.stream_paused


## 只「能听见」才算在播（暂停时返回 false）
func is_bgm_audible() -> bool:
	return _bgm_player.playing and not _bgm_player.stream_paused


func get_bgm_position() -> float:
	if not _bgm_player.playing:
		return 0.0
	return _bgm_player.get_playback_position()


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
	enable_stream_loop(stream)
	_bgm_player.stream = stream
	_bgm_player.volume_db = SILENT_DB
	_bgm_player.play()


## 让一条音频流循环播放（BGM 必须循环，否则放完一遍就静音了）。
##
## 为什么不能一行搞定：Godot 三种音频流的「循环」字段名字不一样 ——
## Ogg / MP3 是 `loop`（bool），WAV 是 `loop_mode`（枚举）。
## 素材缺失时这个问题完全看不出来，一放进真实 BGM 就会「播完就没了」，
## 所以这里按属性探测，而不是写死某个类型。
static func enable_stream_loop(stream: AudioStream) -> void:
	if stream == null:
		return
	if "loop" in stream:
		stream.set("loop", true)
	elif "loop_mode" in stream:
		stream.set("loop_mode", AudioStreamWAV.LOOP_FORWARD)


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
func _play_voice(id: String, stream: AudioStream, volume: float, queue: bool) -> void:
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


## 当前语音播完了（自然结束）→ 接上队列里的下一条。
func _finish_voice() -> void:
	_voice_active = false
	_voice_id = ""
	while not _voice_queue.is_empty():
		var next: Dictionary = _voice_queue.pop_front()
		var stream := next.get("stream") as AudioStream
		if stream == null:
			continue
		_start_voice(String(next.get("id", "")), stream, float(next.get("volume", 1.0)))
		return


func stop_voice() -> void:
	_voice_queue.clear()
	_voice_active = false
	_voice_id = ""
	_voice_player.stop()


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
# 内部工具
# ---------------------------------------------------------------------------

func _on_config_changed(key: String, _value: Variant) -> void:
	match key:
		"master_volume", "bgm_volume":
			if _bgm_player.playing:
				_bgm_player.volume_db = _target_bgm_db()
		"voice_volume":
			if _voice_player.playing:
				_voice_player.volume_db = _to_db(_config_float("voice_volume", 1.0) * _master())


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
