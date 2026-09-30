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


func _ready() -> void:
	_setup_bgm_bus()

	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.name = "BgmPlayer"
	_bgm_player.bus = BGM_BUS_NAME
	add_child(_bgm_player)

	_voice_player = AudioStreamPlayer.new()
	_voice_player.name = "VoicePlayer"
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
	_bgm_player.stream = stream
	_bgm_player.volume_db = SILENT_DB
	_bgm_player.play()


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


func play_voice(id: String, volume: float = 1.0) -> void:
	var stream := _find_stream(VOICE_DIR, id)
	if stream == null:
		return
	_voice_player.stream = stream
	_voice_player.volume_db = _to_db(clampf(volume, 0.0, 1.0) * _master() * _config_float("voice_volume", 1.0))
	_voice_player.play()


func stop_voice() -> void:
	_voice_player.stop()


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
