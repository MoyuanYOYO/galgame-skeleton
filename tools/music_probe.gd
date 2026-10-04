extends Node

## 音乐鉴赏播放链路探针：
##   "D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/music_probe.tscn
##
## 分两段量：
##   A. 直接压 AudioManager，确认「暂停 / 恢复 / 停止」三个动作在引擎层各自做了什么
##   B. 走真实 UI 按钮，确认面板把这三个动作接对了
##
## 只看 print，不改任何文件。用户报告的「点暂停其实变成了停止」如果不复现，
## 说明问题在别处（比如面板把 pause 误发成了 stop），这两段能把它定位到具体一层。

const MAIN_SCENE := "res://scenes/main.tscn"

var _main: Node


func _ready() -> void:
	await _wait(0.3)
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(0.6)
	_main.call("_on_start_requested")
	await _wait(1.2)

	await _probe_audio_manager()
	await _probe_panel()
	await _probe_finish_chain()

	print("[music_probe] DONE")
	get_tree().quit(0)


# ---------------------------------------------------------------------------
# C. 「放完一曲」之后的切歌链路
#
# 用 seek 跳到末尾前 1.2 秒来加速 —— 真等一首 60 秒的曲子跑完太慢。
# 关键是把 bgm_finished 的**触发次数**记下来：如果一次播放放完却收到两次
# 信号，列表循环就会连跳两首（症状：从「主题曲」直接落到「终曲」）。
# ---------------------------------------------------------------------------

var _finish_log: Array[String] = []
var _finish_t0: int = 0


func _probe_finish_chain() -> void:
	print("\n===== C. 放完一曲之后的切歌 =====")
	# 记「相对本次起播的毫秒数」：同帧双发会得到两个几乎相同的 t，
	# 隔了 0.2s 那种则是淡出 tween 期间被补发的第二次。
	AudioManager.bgm_finished.connect(func() -> void:
		_finish_log.append("%s@+%dms" % [
			AudioManager.get_bgm_id(), Time.get_ticks_msec() - _finish_t0]))

	_main.call("_on_gallery_requested")
	await _wait(0.4)
	var gallery: Node = _main.get("gallery")
	gallery.call("show_tab", GalleryPanel.TAB_MUSIC)
	await _wait(0.5)
	var panel: MusicPanel = _main.get_node("%MusicRoot") as MusicPanel

	await _trial(panel, "列表循环", MusicPanel.PlayMode.LIST_LOOP, "theme")
	await _trial(panel, "单曲循环", MusicPanel.PlayMode.SINGLE_LOOP, "theme")
	await _trial(panel, "顺序播放", MusicPanel.PlayMode.ONCE, "theme")
	await _trial(panel, "随机播放", MusicPanel.PlayMode.SHUFFLE, "theme")


func _trial(panel: MusicPanel, label: String, mode: int, from_id: String) -> void:
	panel.set_play_mode(mode)
	AudioManager.stop_bgm(0.0)
	await _wait(0.3)
	_finish_log.clear()
	_main.call("_on_music_track_selected", from_id)
	await _wait(0.5)

	var length := AudioManager.get_bgm_length()
	AudioManager.seek_bgm(maxf(0.0, length - 1.2))
	_finish_t0 = Time.get_ticks_msec()
	print("\n   --- %s：从「%s」起播，跳到最后 1.2s ---" % [label, from_id])
	for i in 4:
		await _wait(0.8)
		var st: AudioStream = AudioManager._bgm_player.stream
		var lm := "n/a"
		if st is AudioStreamWAV:
			lm = str((st as AudioStreamWAV).loop_mode)
		elif st is AudioStreamOggVorbis:
			lm = "loop=%s" % str((st as AudioStreamOggVorbis).loop)
		print("      +%.1fs id=%-13s playing=%-5s looping=%-5s sw_loop=%-8s pos=%5.2f/%5.2f"
			% [float(i + 1) * 0.8, AudioManager.get_bgm_id(),
				str(AudioManager._bgm_player.playing),
				str(AudioManager._bgm_looping), lm,
				AudioManager.get_bgm_position(), AudioManager.get_bgm_length()])
	print("   finished 触发 %d 次，序列=%s" % [_finish_log.size(), str(_finish_log)])
	print("   结果 id=%s（播放器 %s）" % [
		AudioManager.get_bgm_id(),
		"在响" if AudioManager.is_bgm_audible() else "停着"])


# ---------------------------------------------------------------------------
# A. AudioManager 直测
# ---------------------------------------------------------------------------

func _probe_audio_manager() -> void:
	print("\n===== A. AudioManager 直测 =====")
	AudioManager.stop_bgm(0.0)
	await _wait(0.2)
	_dump("起点（stop 之后）")

	AudioManager.play_bgm("daily", 0.8, 0.0)
	await _wait(0.6)
	_dump("play_bgm(daily) 之后")

	AudioManager.pause_bgm()
	await _wait(0.4)
	_dump("pause_bgm() 之后   ← 这里 playing 应仍为 true、paused 应为 true")

	var pos_at_pause := AudioManager.get_bgm_position()
	await _wait(0.5)
	var pos_after := AudioManager.get_bgm_position()
	print("   [位置] 暂停时 %.3f → 等 0.5s 后 %.3f（应几乎不动）" % [pos_at_pause, pos_after])

	AudioManager.resume_bgm()
	await _wait(0.5)
	_dump("resume_bgm() 之后  ← 应恢复成 playing 且 pos 继续往前走")
	var pos_resumed := AudioManager.get_bgm_position()
	print("   [位置] 恢复后 %.3f（应 > %.3f，且没回到 0）" % [pos_resumed, pos_after])

	AudioManager.stop_bgm(0.0)
	await _wait(0.3)
	_dump("stop_bgm() 之后")

	# tension.wav 是唯一一条 WAV（其余都是 ogg）。WAV 的循环要同时设 loop_mode
	# 与循环区间，少设区间就会出现「开了循环反而放不出来」。
	for loop_on in [true, false]:
		AudioManager.stop_bgm(0.0)
		await _wait(0.3)
		AudioManager.play_bgm("tension", 0.8, 0.0, loop_on)
		await _wait(0.8)
		_dump("tension.wav loop=%s" % str(loop_on))

	# 循环是不是真的成立：跳到末尾前 1.5 秒，看它绕回开头还是停下
	AudioManager.stop_bgm(0.0)
	await _wait(0.3)
	AudioManager.play_bgm("tension", 0.8, 0.0, true)
	await _wait(0.4)
	AudioManager.seek_bgm(AudioManager.get_bgm_length() - 1.5)
	var before_wrap := AudioManager.get_bgm_position()
	await _wait(2.5)
	print("   [WAV 循环] 跳到 %0.1fs，2.5s 后 %0.1fs（绕回小值=循环成立；停在 0=放完就没了）"
		% [before_wrap, AudioManager.get_bgm_position()])

	# 「播放中换流」这条路径单独覆盖一遍：切歌是在 finished 回调里换的，
	# 那条路径对 WAV 有过问题（见 C 段），这里是不在回调里的对照组。
	AudioManager.stop_bgm(0.0)
	await _wait(0.3)
	AudioManager.play_bgm("theme", 0.8, 0.0, false)
	await _wait(0.8)
	AudioManager.play_bgm("tension", 0.8, 0.0, false)
	await _wait(0.8)
	_dump("theme(播放中) → tension.wav")


func _dump(tag: String) -> void:
	print("   [%s] id=%s stream_paused=%s playing=%s paused=%s audible=%s rawpos=%.3f getpos=%.3f"
		% [tag, AudioManager.get_bgm_id(),
			AudioManager._bgm_player.stream_paused,
			AudioManager._bgm_player.playing,
			AudioManager.is_bgm_paused(),
			AudioManager.is_bgm_audible(),
			AudioManager._bgm_player.get_playback_position(),
			AudioManager.get_bgm_position()])


# ---------------------------------------------------------------------------
# B. 走真实 UI 按钮
# ---------------------------------------------------------------------------

func _probe_panel() -> void:
	print("\n===== B. 音乐面板按钮 =====")
	for item in CollectionRegistry.get_items("music"):
		CollectionManager.unlock("music", String((item as Dictionary).get("id", "")))

	_main.call("_on_gallery_requested")
	await _wait(0.4)
	var gallery: Node = _main.get("gallery")
	gallery.call("show_tab", GalleryPanel.TAB_MUSIC)
	await _wait(0.5)

	var track_list: Node = _main.get_node("%TrackList")
	var play_btn: Button = _main.get_node("%MusicPlay")
	var prev_btn: Button = _main.get_node("%MusicPrev")
	var next_btn: Button = _main.get_node("%MusicNext")
	var now_playing: Label = _main.get_node("%NowPlaying")
	var time_label: Label = _main.get_node("%MusicTime")
	print("   曲目数=%d  播放键文字=%s" % [track_list.get_child_count(), play_btn.text])

	AudioManager.stop_bgm(0.0)
	await _wait(0.3)

	# 选中第一首
	var first: Button = track_list.get_child(0) as Button
	print("   点第 1 首：%s" % first.text)
	first.pressed.emit()
	await _wait(0.8)
	_dump("选中曲目后")
	print("   标题=%s / 时间=%s / 播放键=%s" % [now_playing.text, time_label.text, play_btn.text])

	# 第一次点播放键 → 期望「暂停」
	print("\n   --- 第 1 次点播放键（期望暂停）---")
	play_btn.pressed.emit()
	await _wait(0.5)
	_dump("点一次后")
	print("   播放键文字=%s / 时间=%s" % [play_btn.text, time_label.text])

	# 第二次点 → 期望「恢复」
	print("\n   --- 第 2 次点播放键（期望恢复，不该从头开始）---")
	play_btn.pressed.emit()
	await _wait(0.5)
	_dump("点两次后")
	print("   播放键文字=%s / 时间=%s" % [play_btn.text, time_label.text])

	# 上一首 / 下一首
	print("\n   --- 上一首 / 下一首 ---")
	next_btn.pressed.emit()
	await _wait(0.7)
	_dump("下一首后")
	print("   标题=%s / 时间=%s" % [now_playing.text, time_label.text])
	prev_btn.pressed.emit()
	await _wait(0.7)
	_dump("上一首后")
	print("   标题=%s / 时间=%s" % [now_playing.text, time_label.text])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
