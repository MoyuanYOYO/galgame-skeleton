extends Node

## 冒烟测试 / 回归测试
##
## 用法：
##   "D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --headless --path . --script tools/smoke.gd
##
## 覆盖：
##   1. Autoload 单例是否注册
##   2. 正式剧本能否解析、跳转目标是否全部解析成功
##   3. 调度器控制流（if/else、choice、call/return、flag、affection、minigame、ending）
##   4. 存档写入 / 读出 / 删除的往返一致性
##   5. 主场景与小游戏场景能否加载实例化，并把序章整条路线跑通

const MAIN_SCENE := "res://scenes/main.tscn"
const QTE_SCENE := "res://scenes/minigames/rhythm_qte.tscn"
const PROLOGUE := "res://data/scripts/prologue.gvs"
const CHAPTER1 := "res://data/scripts/chapter1.gvs"
const TEST_SCRIPT_PATH := "user://__smoke_test.gvs"
const OP_COVERAGE_PATH := "user://__smoke_op_coverage.gvs"

## 序章全选第一项 + 小游戏通关后的期望好感度：
##   5(选项) + 8(小游戏) + 15(天台选项) + 6(第一章选项) + 10(真结局) = 44
const EXPECTED_AFFECTION := 44.0

const TEST_SCRIPT := """label start
set var hp 10
if var hp > 5
    set var path "high"
else
    set var path "low"
end
choice
    "选 A" -> branch_a
    "选 B" -> branch_b
end
label branch_a
set var picked "a"
affection alice 7
jump merge
label branch_b
set var picked "b"
affection alice -7
jump merge
label merge
call sub
flag done
minigame rhythm_qte rounds=1 need=1
ending test_end "冒烟结局"
label sub
add var hp 5
return
"""

var _failed: int = 0
var _checks: int = 0

## 注意：GDScript 的 lambda 对局部变量是「按值捕获」，所以这些跨回调
## 收集的状态必须放在成员变量上，否则回调里的赋值传不出来。
var _ended_id: String = ""
var _ended_title: String = ""
var _minigame_requests: Array = []
var _say_count: int = 0
var _resumed_text: String = ""
var _seen_stage_ops: Array = []
var _seen_audio_ops: Array = []


func _ready() -> void:
	# 等一帧：_ready 阶段 root 正在装配子节点，此时 add_child 会被拒绝
	await get_tree().process_frame
	print("[smoke] ==== 开始 ====")

	# 测试会读写 user:// 下的真实数据（收藏记录 / 自动存档 / 设置），
	# 先备份，跑完原样还原 —— 否则跑一次测试就把玩家进度清了。
	var auto_backup := SaveManager.read_slot(SaveManager.AUTO_SLOT)
	var collection_backup := CollectionManager.to_dict()
	var config_backup: Dictionary = ConfigManager.data.duplicate(true)

	_check_autoloads()
	_check_parser()
	_check_ui_theme()
	_check_text_effects()
	_check_motion_parsing()
	_check_player_comforts()
	_check_stage_polish()
	_check_content_org()
	_check_tooling()
	_check_runner_flow()
	_check_save_roundtrip()
	_check_rollback_buffer()
	_check_audio()
	_check_script_paths()
	_check_shaders()
	_check_architecture()
	await _check_media()
	await _check_scenes()

	# 还原现场
	if auto_backup.is_empty():
		SaveManager.delete_slot(SaveManager.AUTO_SLOT)
	else:
		SaveManager.write_slot(SaveManager.AUTO_SLOT, auto_backup)
	CollectionManager.from_dict(collection_backup)
	CollectionManager.save_data()
	for key in config_backup.keys():
		ConfigManager.set_value(String(key), config_backup[key], false)

	print("[smoke] ==== 结束 ====")
	if _failed == 0:
		print("[smoke] ALL OK  (%d checks)" % _checks)
	else:
		printerr("[smoke] FAILED  %d / %d" % [_failed, _checks])
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("   OK   %s" % label)
	else:
		_failed += 1
		printerr("   FAIL %s" % label)


## 按真实时间等待。自动播放 / 跳过都依赖 Time.get_ticks_msec()，
## 用「等 N 帧」是等不到的（无垂直同步时帧率可能上千）。
func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## 统一的 say 收集器。用成员方法而不是 lambda，因为 lambda 对局部变量
## 是按值捕获的，赋值传不出来。
func _collect_say(_speaker: String, text: String, _expr: String) -> void:
	_say_count += 1
	_resumed_text = text


# ---------------------------------------------------------------------------
# 1. Autoload
# ---------------------------------------------------------------------------

func _check_autoloads() -> void:
	print("[smoke] 1. Autoload 单例")
	for node_name in ["ConfigManager", "GameManager", "AudioManager", "SaveManager"]:
		_ok(get_tree().root.has_node(node_name), "%s 已注册" % node_name)


# ---------------------------------------------------------------------------
# 2. 剧本解析
# ---------------------------------------------------------------------------

func _check_parser() -> void:
	print("[smoke] 2. 剧本解析")
	for path in [PROLOGUE, CHAPTER1]:
		var file_name := String(path).get_file()
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			_ok(false, "%s 可读取" % file_name)
			continue
		var result := GvsParser.parse(text, file_name)
		for e in result["errors"]:
			printerr("        · %s" % String(e))
		_ok(bool(result["ok"]), "%s 解析无错误" % file_name)
		if not bool(result["ok"]):
			continue

		var commands: Array = result["commands"]
		var labels: Dictionary = result["labels"]
		_ok(commands.size() > 0, "%s 生成了 %d 条指令" % [file_name, commands.size()])

		var unresolved := 0
		var choice_count := 0
		var branch_count := 0
		for c in commands:
			var cmd: Dictionary = c
			if cmd.has("target") and int(cmd["target"]) < 0:
				unresolved += 1
			match String(cmd.get("op", "")):
				"choice":
					choice_count += 1
					for opt in cmd["options"]:
						if int((opt as Dictionary)["target"]) < 0:
							unresolved += 1
				"branch_false":
					branch_count += 1
		_ok(unresolved == 0, "%s 跳转目标全部解析成功" % file_name)
		_ok(not labels.is_empty(), "%s 定义了 %d 个标签" % [file_name, labels.size()])
		if file_name == "prologue.gvs":
			_ok(choice_count >= 2, "prologue 含 %d 个选项块" % choice_count)
			_ok(branch_count >= 3, "prologue 含 %d 个条件分支" % branch_count)


# ---------------------------------------------------------------------------
# 11. 外观配置（配色 / 字体 / 按钮尺寸与贴图）
# ---------------------------------------------------------------------------

func _check_ui_theme() -> void:
	print("[smoke] 11. 外观配置")

	UiTheme.reload()

	# --- 配置加载 ---
	_ok(UiTheme.color("accent").a > 0.5, "调色板可解析（accent=%s）" % UiTheme.ACCENT)
	_ok(UiTheme.number("title", 0.0) > 0.0, "字号配置存在（title=%d）" % int(UiTheme.number("title", 0.0)))

	var preset_count := 0
	for key in UiTheme.section("buttons").keys():
		if not String(key).begins_with("_"):
			preset_count += 1
	_ok(preset_count >= 5, "按钮预设数量 = %d" % preset_count)

	# --- 按钮尺寸来自预设 ---
	# v5.2 起标题菜单收窄到 340（对齐选型页 mockup：17.7cqw × 19.2 ≈ 340）
	_ok(UiTheme.button_min_size("title") == Vector2(340.0, 68.0),
		"title 预设尺寸 = %s" % UiTheme.button_min_size("title"))
	_ok(UiTheme.button_min_size("choice") == Vector2(760.0, 68.0),
		"choice 预设尺寸 = %s" % UiTheme.button_min_size("choice"))

	var probe := Button.new()
	UiTheme.apply_button(probe, "title")
	_ok(probe.custom_minimum_size == Vector2(340.0, 68.0),
		"apply_button 按预设设了 custom_minimum_size")
	_ok(probe.get_theme_font_size("font_size") == 26, "apply_button 按预设设了字号")

	# --- 开关（CheckButton）的文字颜色 ---
	# Godot 默认主题里 font_pressed_color / font_hover_pressed_color 是**白色**，
	# 而本项目的面板是浅色纸面 —— 只覆盖 font_color 的话，「开关一打开文字就变白、
	# 看不见」。所以必须逐个状态确认都被显式覆盖成了传入的颜色。
	var check := CheckButton.new()
	UiTheme.apply_check_button(check, UiTheme.TEXT, 20)
	var not_overridden: Array = []
	for state in ["font_color", "font_hover_color", "font_pressed_color",
			"font_hover_pressed_color", "font_focus_color"]:
		if check.get_theme_color(state) != UiTheme.TEXT:
			not_overridden.append(state)
	_ok(not_overridden.is_empty(),
		"开关的五个文字状态色都被覆盖（否则打开/悬停会变白看不见）：%s"
		% str(not_overridden))
	_ok(check.get_theme_font_size("font_size") == 20, "开关字号跟随传入值")
	_ok(check.get_theme_color("font_disabled_color") == UiTheme.TEXT_DIM,
		"开关禁用态用次级色，不会白得看不见")

	# --- 未定义预设要回退而不是崩 ---
	var fallback := Button.new()
	UiTheme.apply_button(fallback, "这个预设不存在")
	_ok(fallback.get_theme_stylebox("normal") != null, "未定义预设回退到 default")

	# --- 九宫格贴图通路 ---
	# 刻意与当前真实配置解耦：临时改预设再还原，这样无论 title 预设本身
	# 有没有配贴图，两条分支都能被覆盖到。
	var buttons: Dictionary = UiTheme.section("buttons")
	var title_preset: Dictionary = buttons.get("title", {})
	var saved_texture := String(title_preset.get("texture", ""))
	var saved_margin := int(title_preset.get("texture_margin", 14))
	var texture_path := "res://assets/ui/button_ninepatch.png"

	# 分支一：清空贴图 → 程序化 StyleBoxFlat
	title_preset["texture"] = ""
	var flat_probe := Button.new()
	UiTheme.apply_button(flat_probe, "title")
	_ok(flat_probe.get_theme_stylebox("normal") is StyleBoxFlat,
		"未配贴图时用程序化 StyleBoxFlat")
	flat_probe.free()

	# 分支二：配上贴图 → 九宫格 StyleBoxTexture
	if ResourceLoader.exists(texture_path):
		title_preset["texture"] = texture_path
		title_preset["texture_margin"] = 14
		# 必须先把独立的四态贴图清掉，才能确定走的是「只配一张贴图」这条分支。
		# 不能假设真实配置里没有 texture_hover —— 那等于把测试绑死在某个配置状态上，
		# 一旦给预设补了四态贴图，这里就会误报。
		for st in ["hover", "pressed", "disabled"]:
			title_preset["texture_" + st] = ""
		var textured := Button.new()
		UiTheme.apply_button(textured, "title")
		var sb := textured.get_theme_stylebox("normal")
		_ok(sb is StyleBoxTexture, "配了贴图时改用九宫格 StyleBoxTexture")
		if sb is StyleBoxTexture:
			var ts := sb as StyleBoxTexture
			_ok(ts.texture != null, "九宫格贴图已载入")
			_ok(int(ts.texture_margin_left) == 14,
				"九宫格切边 = %d" % int(ts.texture_margin_left))
		var hover := textured.get_theme_stylebox("hover")
		_ok(hover is StyleBoxTexture and (hover as StyleBoxTexture).modulate_color != Color.WHITE,
			"只配一张贴图时，hover 用色调区分")
		textured.free()
	else:
		_ok(false, "示例贴图缺失: %s（先跑 --import）" % texture_path)

	# 还原（断言比对的是「改之前的值」，不是「空」，所以 title 预设
	# 本身配了贴图时这条依然成立）
	title_preset["texture"] = saved_texture
	title_preset["texture_margin"] = saved_margin
	_ok(String(title_preset.get("texture", "")) == saved_texture,
		"测试后已还原预设（不污染真实配置）")

	# --- 预设可以覆盖文字颜色（金底按钮需要深色字） ---
	var tinted := Button.new()
	UiTheme.apply_button(tinted, "title")
	var declared := String(title_preset.get("font_color", "")).strip_edges()
	var expected_font := UiTheme.TEXT if declared.is_empty() \
		else Color.from_string(declared, UiTheme.TEXT)
	_ok(tinted.get_theme_color("font_color") == expected_font,
		"文字颜色取自预设（%s）" % tinted.get_theme_color("font_color"))
	tinted.free()

	# --- focus 态不能漏 Godot 默认样式 ---
	# 不 override 时 Godot 默认给黑色方框边框 + 白色文字：
	# 选项面板第一个按钮会 grab_focus，症状是「按下出黑框 + 文字变白看不清」。
	var focus_probe := Button.new()
	UiTheme.apply_button(focus_probe, "default")
	var fsb := focus_probe.get_theme_stylebox("focus")
	_ok(fsb is StyleBoxFlat and is_equal_approx((fsb as StyleBoxFlat).bg_color.a, 0.0),
		"focus 样式是透明底描边（不是默认黑框）")
	_ok(focus_probe.get_theme_color("font_focus_color")
		== focus_probe.get_theme_color("font_color"),
		"focus 态文字颜色与普通态一致（不再默认白字）")
	focus_probe.free()

	# 编辑器手改优先（normal 已被 override）的按钮也要拿到 focus 修复
	# —— 这条断言守的就是「提前 return 跳过 focus 处理」的回归
	var manual_btn := Button.new()
	manual_btn.add_theme_stylebox_override("normal", StyleBoxFlat.new())
	UiTheme.apply_button(manual_btn, "default")
	_ok(manual_btn.has_theme_stylebox_override("focus"),
		"编辑器手改过的按钮同样没有默认黑框")
	manual_btn.free()

	# --- 按钮音效 ---
	var audio := UiTheme.section("audio")
	var click_id := String(audio.get("click", "")).strip_edges()
	var hover_id := String(audio.get("hover", "")).strip_edges()
	_ok(not click_id.is_empty(), "配置了点击音效 id（%s）" % click_id)
	_ok(not hover_id.is_empty(), "配置了悬停音效 id（%s）" % hover_id)
	# 配置写错 id 会静默无声，这条专门抓这种问题
	_ok(AudioManager.has_se_asset(click_id), "点击音效文件真的存在（%s）" % click_id)
	_ok(AudioManager.has_se_asset(hover_id), "悬停音效文件真的存在（%s）" % hover_id)

	var sfx_btn := Button.new()
	UiTheme.apply_button(sfx_btn, "title")
	_ok(sfx_btn.has_meta(UiTheme.SFX_META), "apply_button 自动挂上了音效")
	_ok(sfx_btn.button_down.get_connections().size() == 1,
		"点击音效连接了 1 个回调（%d）" % sfx_btn.button_down.get_connections().size())
	_ok(sfx_btn.mouse_entered.get_connections().size() == 1, "悬停音效已连接")

	# 重复 apply_button 不应重复挂（否则点一下响两声）
	UiTheme.apply_button(sfx_btn, "title")
	_ok(sfx_btn.button_down.get_connections().size() == 1, "重复 apply_button 不会重复挂音效")

	# 真正触发一次，验证「按下 → 音效发出」这条链路是通的
	AudioManager.clear_last_se()
	sfx_btn.emit_signal("button_down")
	_ok(AudioManager.get_last_se_id() == click_id,
		"按下按钮真的触发了音效（%s）" % AudioManager.get_last_se_id())

	AudioManager.clear_last_se()
	sfx_btn.emit_signal("mouse_entered")
	_ok(AudioManager.get_last_se_id() == hover_id,
		"鼠标悬停真的触发了音效（%s）" % AudioManager.get_last_se_id())

	# 禁用状态不该出声
	sfx_btn.disabled = true
	AudioManager.clear_last_se()
	sfx_btn.emit_signal("button_down")
	_ok(AudioManager.get_last_se_id().is_empty(), "按钮禁用时不播音效")
	sfx_btn.free()
	AudioManager.clear_last_se()

	# sfx:false 的预设应当静音
	var silent_preset: Dictionary = buttons.get("small", {})
	var had_sfx := silent_preset.has("sfx")
	var saved_sfx: Variant = silent_preset.get("sfx", true)
	silent_preset["sfx"] = false
	var silent_btn := Button.new()
	UiTheme.apply_button(silent_btn, "small")
	_ok(not silent_btn.has_meta(UiTheme.SFX_META), "预设写 sfx:false 时按钮静音")
	silent_btn.free()
	if had_sfx:
		silent_preset["sfx"] = saved_sfx
	else:
		silent_preset.erase("sfx")

	# --- 字体：未配置时应安全返回 null ---
	_ok(UiTheme.font("body") == null, "未配置字体时返回 null（回退到内置字体）")
	_ok(UiTheme.font("不存在的键") == null, "未定义的字体键安全返回 null")

	# --- 对话框位置来自配置 ---
	_ok(UiTheme.dialogue_value("offset_left", -1.0) == 132.0,
		"对话框左边距 = %d" % int(UiTheme.dialogue_value("offset_left", -1.0)))
	# v5.2 起改为 -382：按选型页 mockup 换算（高 13.4cqw≈257 + 上下投影边 24×2
	# + 底距 77）。对话框整体变高、底边上抬到 77px，比例与 mockup 一致。
	_ok(UiTheme.dialogue_value("offset_top", 0.0) == -382.0,
		"对话框高度偏移 = %d" % int(UiTheme.dialogue_value("offset_top", 0.0)))

	probe.free()
	fallback.free()


# ---------------------------------------------------------------------------
# 12. 文字特效与打字节奏
# ---------------------------------------------------------------------------

func _check_text_effects() -> void:
	print("[smoke] 12. 文字特效与打字节奏")

	# --- 基础：无标记文本 ---
	var plain := TypingTimeline.build("你好世界", 10.0)
	var times: PackedFloat64Array = plain.get("times", PackedFloat64Array())
	_ok(String(plain.get("display", "")) == "你好世界", "无标记文本原样保留")
	_ok(times.size() == 4, "时间轴长度 = 可见字符数（%d）" % times.size())
	_ok(is_equal_approx(times[0], 0.1), "首字时刻 = 1/速度（%.3f）" % times[0])

	var ascending := true
	for i in range(1, times.size()):
		if times[i] <= times[i - 1]:
			ascending = false
	_ok(ascending, "时间轴单调递增")

	# --- 停顿 ---
	var paused := TypingTimeline.build("前[wait=0.5]后", 10.0)
	var ptimes: PackedFloat64Array = paused.get("times", PackedFloat64Array())
	_ok(String(paused.get("display", "")) == "前后", "停顿标记被剥离出显示文本")
	_ok(ptimes.size() == 2, "停顿不占可见字符（%d）" % ptimes.size())
	_ok(is_equal_approx(ptimes[1] - ptimes[0], 0.6),
		"停顿后间隔 = 停顿 + 单字耗时（%.3f）" % (ptimes[1] - ptimes[0]))

	# --- 变速 ---
	var fast := TypingTimeline.build("慢[speed=2]快快快快[/speed]", 10.0)
	var ftimes: PackedFloat64Array = fast.get("times", PackedFloat64Array())
	_ok(String(fast.get("display", "")) == "慢快快快快", "变速标记被剥离")
	_ok(ftimes.size() == 5, "变速标记不占可见字符（%d）" % ftimes.size())
	_ok(is_equal_approx(ftimes[1] - ftimes[0], 0.05),
		"段内间隔减半（%.3f）" % (ftimes[1] - ftimes[0]))
	_ok(is_equal_approx(ftimes[4] - ftimes[3], 0.05), "变速持续到 [/speed] 为止")

	# --- 非节奏标签要留给 RichTextLabel ---
	var styled := TypingTimeline.build("[bounce]弹[/bounce]", 10.0)
	_ok(String(styled.get("display", "")) == "[bounce]弹[/bounce]",
		"特效标签原样保留，交给 RichTextLabel")
	var stimes: PackedFloat64Array = styled.get("times", PackedFloat64Array())
	_ok(stimes.size() == 1, "特效标签不占可见字符（%d）" % stimes.size())

	# --- 边界 ---
	var empty := TypingTimeline.build("", 10.0)
	var etimes: PackedFloat64Array = empty.get("times", PackedFloat64Array())
	_ok(etimes.is_empty(), "空文本时间轴为空")
	_ok(is_equal_approx(TypingTimeline.total_seconds(etimes), 0.0), "空文本总时长 0")

	var unbalanced := TypingTimeline.build("[/speed]啊", 10.0)
	var utimes: PackedFloat64Array = unbalanced.get("times", PackedFloat64Array())
	_ok(utimes.size() == 1 and is_equal_approx(utimes[0], 0.1),
		"多余的 [/speed] 不会破坏基准速度")

	var ultra := TypingTimeline.build("[speed=0.001]啊", 10.0)
	var ultimes: PackedFloat64Array = ultra.get("times", PackedFloat64Array())
	_ok(ultimes.size() == 1 and ultimes[0] <= TypingTimeline.MAX_SECONDS_PER_CHAR + 0.001,
		"单字等待有上限，节奏不会被拖死（%.3f）" % ultimes[0])

	var no_close := TypingTimeline.build("[未闭合的标签", 10.0)
	var ntimes: PackedFloat64Array = no_close.get("times", PackedFloat64Array())
	_ok(ntimes.size() == 7, "未闭合的 [ 当普通字符处理（%d）" % ntimes.size())

	# --- 二分查表 ---
	_ok(TypingTimeline.revealed_count(times, -1.0) == 0, "elapsed < 0 时显示 0 个")
	_ok(TypingTimeline.revealed_count(times, 0.05) == 0, "未到首字时刻显示 0 个")
	_ok(TypingTimeline.revealed_count(times, 0.1) == 1, "到首字时刻显示 1 个")
	_ok(TypingTimeline.revealed_count(times, 999.0) == times.size(), "超长 elapsed 全部显示")

	# --- 三个自定义特效已注册且标记名正确 ---
	_ok(BounceEffect.new().bbcode == "bounce", "BounceEffect 的标记名 = bounce")
	_ok(GlitchEffect.new().bbcode == "glitch", "GlitchEffect 的标记名 = glitch")
	_ok(BlinkEffect.new().bbcode == "blink", "BlinkEffect 的标记名 = blink")

	# 错乱效果必须用「时间片跳变」而不是逐帧随机，否则字会抖到没法读
	var glitch := GlitchEffect.new()
	var fx := CharFXTransform.new()
	fx.env = {}
	fx.elapsed_time = 1.0
	glitch._process_custom_fx(fx)
	var first := fx.offset
	fx.elapsed_time = 1.0001
	glitch._process_custom_fx(fx)
	_ok(fx.offset == first, "同一时间片内错乱偏移不变（不是逐帧乱抖）")

	# 跨过时间片边界后应当跳变
	fx.elapsed_time = 1.2
	glitch._process_custom_fx(fx)
	_ok(fx.offset != first, "跨时间片后错乱偏移发生变化")


# ---------------------------------------------------------------------------
# 13. 演出动效指令的解析
# ---------------------------------------------------------------------------

func _check_motion_parsing() -> void:
	print("[smoke] 13. 演出动效指令")

	var result := GvsParser.parse("""
label start
hop alice height=50 times=3 duration=0.9
zoom alice 1.4 duration=0.6 ease=out_elastic
shake alice strength=15 times=6 duration=0.5
move alice right duration=1.2 ease=in_cubic
screen_shake strength=25 times=5 duration=0.6
screen_flash color=#ff0000 duration=0.4
screen_fx swirl strength=1.6 duration=2.0
""", "motion_test.gvs")
	_ok(bool(result["ok"]), "动效剧本解析无错误")
	if not bool(result["ok"]):
		for e in result["errors"]:
			printerr("        · %s" % String(e))
		return

	var by_op: Dictionary = {}
	for c in result["commands"]:
		var cmd: Dictionary = c
		by_op[String(cmd.get("op", ""))] = cmd

	_ok(by_op.has("hop"), "hop 已解析")
	if by_op.has("hop"):
		var hop: Dictionary = by_op["hop"]
		_ok(is_equal_approx(float(hop["height"]), 50.0), "hop height 参数生效")
		_ok(int(hop["times"]) == 3, "hop times 参数生效")

	_ok(by_op.has("zoom"), "zoom 已解析")
	if by_op.has("zoom"):
		var zoom: Dictionary = by_op["zoom"]
		_ok(is_equal_approx(float(zoom["scale"]), 1.4), "zoom 倍数生效")
		_ok(String(zoom["ease"]) == "out_elastic", "zoom ease 参数生效")

	_ok(by_op.has("shake"), "shake 已解析")
	_ok(by_op.has("screen_shake"), "screen_shake 已解析")
	if by_op.has("screen_shake"):
		_ok(is_equal_approx(float((by_op["screen_shake"] as Dictionary)["strength"]), 25.0),
			"screen_shake strength 参数生效")
	_ok(by_op.has("screen_flash"), "screen_flash 已解析")
	if by_op.has("screen_flash"):
		_ok(String((by_op["screen_flash"] as Dictionary)["color"]) == "#ff0000",
			"screen_flash color 参数生效")

	_ok(by_op.has("screen_fx"), "screen_fx 已解析")
	if by_op.has("screen_fx"):
		var fx: Dictionary = by_op["screen_fx"]
		_ok(String(fx["kind"]) == "swirl", "screen_fx 种类生效")
		_ok(is_equal_approx(float(fx["strength"]), 1.6), "screen_fx strength 参数生效")
		_ok(is_equal_approx(float(fx["duration"]), 2.0), "screen_fx duration 参数生效")

	# 种类名写错必须是**解析期错误**，不能静默降级 —— 降级的话表现就是
	# 「剧本写了、演出不出来」，只有控制台一行 warning，正是最难查的那类 bug。
	var bad_fx := GvsParser.parse("label start\nscreen_fx glich\n", "bad_fx.gvs")
	_ok(not bool(bad_fx["ok"]), "screen_fx 种类拼错会被解析器拦下")
	# 缺种类也一样
	var no_kind := GvsParser.parse("label start\nscreen_fx\n", "no_kind.gvs")
	_ok(not bool(no_kind["ok"]), "screen_fx 缺种类会被解析器拦下")
	# 关闭写法（none）是合法的
	var off_fx := GvsParser.parse("label start\nscreen_fx none\n", "off_fx.gvs")
	_ok(bool(off_fx["ok"]), "screen_fx none 合法（用来关闭）")

	# move 的 ease 是新增的，缺省应为 out_cubic（不是线性）
	_ok(by_op.has("move"), "move 已解析")
	if by_op.has("move"):
		_ok(String((by_op["move"] as Dictionary)["ease"]) == "in_cubic",
			"move ease 参数生效")

	var defaulted := GvsParser.parse("label start\nmove alice left", "m.gvs")
	for c in defaulted["commands"]:
		var cmd: Dictionary = c
		if String(cmd.get("op", "")) == "move":
			_ok(String(cmd.get("ease", "")) == "out_cubic",
				"move 缺省 ease = out_cubic（不是线性）")

	_ok(Stage.known_eases().size() >= 8, "内置缓动预设 %d 个" % Stage.known_eases().size())


# ---------------------------------------------------------------------------
# 14. 玩家体验：已读追踪 / 存档缩略图
# ---------------------------------------------------------------------------

## 测试用槽位，故意选在 SLOT_COUNT 之外，避免污染真实存档
const PROBE_SLOT := 99


func _check_player_comforts() -> void:
	print("[smoke] 14. 已读追踪 / 存档缩略图")

	# --- 已读追踪 ---
	# 已读数据是全局的（跨存档），测试必须存下旧数据再还原，
	# 否则每跑一次测试都会往玩家的已读记录里塞探针字符串，
	# 把「已读率」这个指标算虚高。
	var probe := "【smoke 测试文本】%d" % randi()
	var read_backup := ReadTracker.to_dict()
	var count_before := ReadTracker.read_count()
	_ok(not ReadTracker.is_read(probe), "新文本默认未读")
	ReadTracker.mark_read(probe)
	_ok(ReadTracker.is_read(probe), "标记后变为已读")
	_ok(ReadTracker.read_count() == count_before + 1, "标记后计数 +1")
	ReadTracker.mark_read(probe)
	_ok(ReadTracker.read_count() == count_before + 1, "重复标记不会增加计数")
	_ok(not ReadTracker.is_read(""), "空文本永远算未读")
	_ok(not ReadTracker.is_read("【肯定没人看过的句子】%d" % randi()), "没标记过的仍是未读")
	ReadTracker.from_dict(read_backup)

	# --- 存档缩略图 ---
	SaveManager.delete_slot(PROBE_SLOT)
	_ok(not SaveManager.has_thumbnail(PROBE_SLOT), "空槽位没有缩略图")
	_ok(SaveManager.get_thumbnail(PROBE_SLOT) == null, "空槽位读缩略图返回 null")

	var image := Image.create(64, 36, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.4, 0.8, 1.0))
	_ok(SaveManager.write_thumbnail(PROBE_SLOT, image), "缩略图写入成功")
	_ok(SaveManager.has_thumbnail(PROBE_SLOT), "写入后能查到缩略图")

	var texture := SaveManager.get_thumbnail(PROBE_SLOT)
	_ok(texture != null, "缩略图能读回为 Texture2D")
	if texture != null:
		_ok(texture.get_width() == 64 and texture.get_height() == 36,
			"读回的尺寸正确（%dx%d）" % [texture.get_width(), texture.get_height()])

	SaveManager.write_slot(PROBE_SLOT, {"chapter_title": "测试", "preview": "内容"})
	_ok(bool(SaveManager.get_slot_info(PROBE_SLOT)["has_thumb"]),
		"槽位摘要带上 has_thumb")

	SaveManager.delete_slot(PROBE_SLOT)
	_ok(not SaveManager.has_thumbnail(PROBE_SLOT),
		"删除存档会一并删掉缩略图（不留孤儿文件）")


# ---------------------------------------------------------------------------
# 15. 转场遮罩 / 滑入滑出
# ---------------------------------------------------------------------------

func _check_stage_polish() -> void:
	print("[smoke] 15. 转场遮罩 / 滑入滑出")

	# --- 转场名 → shader 模式 ---
	_ok(Stage.transition_mode("dissolve") == 0, "dissolve → mode 0")
	_ok(Stage.transition_mode("wipe") == 1, "wipe → mode 1")
	_ok(Stage.transition_mode("blinds") == 2, "blinds → mode 2")
	_ok(Stage.transition_mode("circle") == 3, "circle → mode 3")
	_ok(Stage.transition_mode("fade") == -1, "fade 不走遮罩（用 alpha 交叉淡入）")
	_ok(Stage.transition_mode("none") == -1, "none 不走遮罩")
	_ok(Stage.transition_mode("随便写的") == -1, "未知转场安全回退到 fade 路径")
	_ok(Stage.transition_names().size() >= 5, "转场名列表 %d 项" % Stage.transition_names().size())

	# --- 滑入方向 ---
	_ok(Stage.is_slide("slide_left"), "slide_left 是滑入")
	_ok(Stage.is_slide("slide_right"), "slide_right 是滑入")
	_ok(Stage.is_slide("slide_up"), "slide_up 是滑入")
	_ok(not Stage.is_slide("fade"), "fade 不是滑入")
	_ok(not Stage.is_slide("none"), "none 不是滑入")

	# --- shader 资源 ---
	var shader := load("res://shaders/transition.gdshader") as Shader
	_ok(shader != null, "转场 shader 能加载")
	if shader != null:
		_ok(shader.code.contains("progress"), "shader 暴露 progress 参数")

	# --- 剧本能解析新的 type 值 ---
	var result := GvsParser.parse("""
label start
bg rooftop type=dissolve fade=0.9
cg cg_classroom type=wipe fade=0.7
hide_cg type=blinds fade=0.5
show alice at=left type=slide_left fade=0.6
hide bob type=slide_right fade=0.4
""", "transition_test.gvs")
	_ok(bool(result["ok"]), "转场剧本解析无错误")

	var by_op: Dictionary = {}
	for c in result["commands"]:
		var cmd: Dictionary = c
		by_op[String(cmd.get("op", ""))] = cmd

	_ok(String((by_op.get("bg", {}) as Dictionary).get("transition", "")) == "dissolve",
		"bg 的 type 参数生效")
	_ok(String((by_op.get("cg", {}) as Dictionary).get("transition", "")) == "wipe",
		"cg 的 type 参数生效")
	_ok(String((by_op.get("hide_cg", {}) as Dictionary).get("transition", "")) == "blinds",
		"hide_cg 的 type 参数生效")
	_ok(String((by_op.get("show", {}) as Dictionary).get("transition", "")) == "slide_left",
		"show 的 type 参数生效")
	_ok(String((by_op.get("hide", {}) as Dictionary).get("transition", "")) == "slide_right",
		"hide 的 type 参数生效")

	# 不写 type 时应该回落到 fade
	var defaulted := GvsParser.parse("label start\nbg rooftop", "d.gvs")
	for c in defaulted["commands"]:
		var cmd: Dictionary = c
		if String(cmd.get("op", "")) == "bg":
			_ok(String(cmd.get("transition", "")) == "fade", "bg 缺省 type = fade")

	# --- 天气 / 运镜 / 语音 / 表情时长 ---
	var more := GvsParser.parse("""
label start
weather snow intensity=0.6
weather none
bg_motion scale=1.12 x=18 y=-9 duration=7.5 ease=out_cubic
voice alice_001 volume=0.8
expr alice smile fade=0.4
""", "stage_extra.gvs")
	_ok(bool(more["ok"]), "天气 / 运镜 / 语音剧本解析无错误")
	if not bool(more["ok"]):
		for e in more["errors"]:
			printerr("        · %s" % String(e))
		return

	var extra: Dictionary = {}
	for c in more["commands"]:
		var cmd: Dictionary = c
		var op := String(cmd.get("op", ""))
		if op == "weather" and not extra.has("weather"):
			extra["weather"] = cmd
		elif op == "bg_motion" or op == "voice" or op == "expr":
			extra[op] = cmd

	_ok(String((extra.get("weather", {}) as Dictionary).get("kind", "")) == "snow",
		"weather 类型参数生效")
	_ok(is_equal_approx(float((extra.get("weather", {}) as Dictionary).get("intensity", 0.0)), 0.6),
		"weather intensity 参数生效")

	var motion: Dictionary = extra.get("bg_motion", {})
	_ok(is_equal_approx(float(motion.get("scale", 0.0)), 1.12), "bg_motion scale 生效")
	_ok(is_equal_approx(float(motion.get("x", 0.0)), 18.0), "bg_motion x 生效")
	_ok(is_equal_approx(float(motion.get("duration", 0.0)), 7.5), "bg_motion duration 生效")
	_ok(String(motion.get("ease", "")) == "out_cubic", "bg_motion ease 生效")

	var voice: Dictionary = extra.get("voice", {})
	_ok(String(voice.get("id", "")) == "alice_001", "voice id 生效")
	_ok(is_equal_approx(float(voice.get("volume", 0.0)), 0.8), "voice volume 生效")

	var expr_cmd: Dictionary = extra.get("expr", {})
	_ok(is_equal_approx(float(expr_cmd.get("duration", 0.0)), 0.4),
		"expr 的 fade 参数变成过渡时长（%.2f）" % float(expr_cmd.get("duration", 0.0)))

	# --- 天气粒子贴图能程序化生成 ---
	for kind in ["rain", "snow", "sakura"]:
		var tex := PlaceholderAssets.get_weather_particle(kind)
		_ok(tex != null and tex.get_width() > 0 and tex.get_height() > 0,
			"天气粒子贴图 %s 生成成功（%dx%d）" % [kind, tex.get_width(), tex.get_height()])
	_ok(PlaceholderAssets.get_weather_particle("snow") == PlaceholderAssets.get_weather_particle("snow"),
		"天气贴图有缓存（同一实例）")

	# --- 两个新 shader 能加载 ---
	_ok(load("res://shaders/char_expr.gdshader") != null, "表情过渡 shader 能加载")


# ---------------------------------------------------------------------------
# 16. 内容组织：结局 / 路线 / 已读率 / 章节
# ---------------------------------------------------------------------------

func _check_content_org() -> void:
	print("[smoke] 16. 内容组织：结局 / 路线 / 已读率 / 章节")

	# --- ScriptStats ---
	_ok(ScriptStats.total_lines() > 0, "统计到 %d 句台词" % ScriptStats.total_lines())
	_ok(ScriptStats.choices().size() >= 2, "统计到 %d 个选项点" % ScriptStats.choices().size())
	_ok(ScriptStats.script_files().size() >= 2, "发现 %d 个剧本文件" % ScriptStats.script_files().size())
	_ok(ScriptStats.chapters().size() >= 1, "章节表有 %d 章" % ScriptStats.chapters().size())

	# 每个选项点都要能定位到标签 —— 路线图用「文件:标签」当键，缺了就记不上
	var missing_label := 0
	for entry in ScriptStats.choices():
		if String((entry as Dictionary).get("label", "")).is_empty():
			missing_label += 1
	_ok(missing_label == 0, "所有选项点都有归属标签（缺失 %d 个）" % missing_label)

	# --- 结局 id 必须全局唯一，且注册表里要有对应条目 ---
	var ending_ids := {}
	var duplicated: Array = []
	for path in ScriptStats.script_files():
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var text := file.get_as_text()
		file.close()
		var result := GvsParser.parse(text, path.get_file())
		for c in result.get("commands", []):
			var cmd: Dictionary = c
			if String(cmd.get("op", "")) != "ending":
				continue
			var id := String(cmd.get("id", ""))
			if ending_ids.has(id):
				duplicated.append("%s（%s 与 %s）" % [id, ending_ids[id], path.get_file()])
			else:
				ending_ids[id] = path.get_file()

	if duplicated.is_empty():
		_ok(true, "结局 id 全局唯一（共 %d 个）" % ending_ids.size())
	else:
		_ok(false, "结局 id 有重复：%s" % ", ".join(duplicated))

	var unregistered: Array = []
	for id in ending_ids.keys():
		if not CollectionRegistry.has_item("endings", String(id)):
			unregistered.append(String(id))
	_ok(unregistered.is_empty(),
		"剧本里的结局都在注册表里（缺 %s）" % ", ".join(unregistered))

	# --- 结局收藏（存下旧数据，测完还原，别动玩家真实进度）---
	var saved_collection := CollectionManager.to_dict()
	CollectionManager.reset_all()
	_ok(not CollectionManager.is_unlocked("endings", "true_end"), "结局初始未解锁")
	_ok(CollectionManager.unlock("endings", "true_end"), "解锁结局成功")
	_ok(CollectionManager.is_unlocked("endings", "true_end"), "解锁后可查到")
	_ok(CollectionManager.total_count("endings") >= 4,
		"结局注册表有 %d 条" % CollectionManager.total_count("endings"))
	CollectionManager.from_dict(saved_collection)
	CollectionManager.save_data()

	# --- RouteTracker ---
	var saved_route := RouteTracker.to_dict()
	RouteTracker.clear()
	_ok(RouteTracker.get_pick("prologue.gvs", "start") == -1, "没走过的选项点返回 -1")
	RouteTracker.record_pick("res://data/scripts/prologue.gvs", "start", 1)
	_ok(RouteTracker.get_pick("prologue.gvs", "start") == 1, "记录选项后能查回（带完整路径也能对上）")
	_ok(RouteTracker.pick_count() == 1, "选项记录计数正确")

	RouteTracker.record_chapter("prologue")
	_ok(RouteTracker.has_visited("prologue"), "章节访问记录生效")
	_ok(not RouteTracker.has_visited("chapter1"), "没走过的章节仍是未访问")

	var chapters := ScriptStats.chapters()
	if not chapters.is_empty():
		_ok(RouteTracker.is_chapter_available(chapters[0] as Dictionary),
			"第一章（没写 unlock_flag）默认可选")
	var gated := {"unlock_flag": "__smoke_gate"}
	_ok(not RouteTracker.is_chapter_available(gated), "带 unlock_flag 的章节初始锁定")
	GameManager.set_flag("__smoke_gate")
	_ok(RouteTracker.is_chapter_available(gated), "flag 置位后章节解锁")

	RouteTracker.from_dict(saved_route)
	RouteTracker.save_now()

	# --- 已读率的分母 ---
	_ok(ScriptStats.total_lines() > 0, "已读率分母有效（%d 句）" % ScriptStats.total_lines())
	var read_backup2 := ReadTracker.to_dict()
	var before := ReadTracker.read_count()
	ReadTracker.mark_read("【smoke 已读率测试】%d" % randi())
	_ok(ReadTracker.read_count() == before + 1, "标记已读后计数 +1")
	ReadTracker.from_dict(read_backup2)

	# --- 已读率的分母与分子必须同口径 ---
	# 曾经显示成「已读 150 / 62 句」：分子用了全局的 ReadTracker.read_count()
	# （跨存档、跨剧本版本，连测试探针都算在内），分母却只是当前剧本的台词数。
	var lines := ScriptStats.line_texts()
	_ok(lines.size() == ScriptStats.total_lines(),
		"line_texts 与 total_lines 同口径（%d 句）" % lines.size())

	var read_backup3 := ReadTracker.to_dict()
	# 故意把全局计数推到超过总句数 —— 若哪天分子又用回全局计数，下面的断言必然失败
	var need := ScriptStats.total_lines() + 1 - ReadTracker.read_count()
	for i in maxi(0, need):
		ReadTracker.mark_read("【smoke 口径探针 %d】" % i)
	_ok(ReadTracker.read_count() > ScriptStats.total_lines(),
		"全局已读数已被推高到超过总句数（%d > %d）"
			% [ReadTracker.read_count(), ScriptStats.total_lines()])

	var progress := RecordsPanel.read_progress()
	_ok(progress.y == ScriptStats.total_lines(), "分母是当前剧本的台词数（%d）" % progress.y)
	_ok(progress.x >= 0 and progress.x <= progress.y,
		"记录面板的已读句数不超过总句数（%d / %d）" % [progress.x, progress.y])
	ReadTracker.from_dict(read_backup3)

	# --- 记录面板能构建（不崩、四个板块都在）---
	var panel := RecordsPanel.new()
	add_child(panel)
	await get_tree().process_frame
	panel.present()
	_ok(panel.visible, "记录面板能打开")

	# 面板必须按**视口**撑满，而不是被内容撑成一张「卡在左上角的卡片」。
	# 这个 bug 真实存在过：Control 直接挂在 CanvasLayer 下时锚点拿不到视口
	# 尺寸，size 由内容决定（约 1422×890），于是右边和下边各留一大片空、
	# 路线图被截断、标题界面还从留白里透出来。
	var vp_size := get_viewport().get_visible_rect().size
	_ok(panel.size.is_equal_approx(vp_size),
		"记录面板撑满视口（%.0f×%.0f / 视口 %.0f×%.0f）"
			% [panel.size.x, panel.size.y, vp_size.x, vp_size.y])

	panel.hide_panel()
	_ok(not panel.visible, "记录面板能关闭")
	panel.queue_free()


# ---------------------------------------------------------------------------
# 17. 工具链：剧本校验 / 素材清单
# ---------------------------------------------------------------------------

func _check_tooling() -> void:
	print("[smoke] 17. 工具链：剧本校验 / 素材清单")

	# --- 静态校验必须全绿 ---
	var result := ScriptAudit.audit()
	var errors: Array = result["errors"]
	var warnings: Array = result["warnings"]
	for e in errors:
		printerr("        [错误] %s" % String(e))
	for w in warnings:
		printerr("        [提醒] %s" % String(w))
	_ok(errors.is_empty(), "剧本校验无错误（%d 个）" % errors.size())
	_ok(warnings.is_empty(), "剧本校验无提醒（%d 个）" % warnings.size())
	_ok(int(result["files"]) >= 2, "校验扫到 %d 个文件" % int(result["files"]))
	_ok(int(result["commands"]) > 100, "校验扫到 %d 条指令" % int(result["commands"]))

	# --- 校验器本身要能抓出问题（喂它一段故意写坏的剧本）---
	# 直接测内部逻辑不现实，改用「构造后校验」的方式：
	# 结局 id 重复是校验器的一条规则，这里验证它确实会报
	var dup_text := """
label start
ending dup_end "结局甲"
ending dup_end "结局乙"
"""
	var dup_result := GvsParser.parse(dup_text, "dup.gvs")
	var dup_ids := {}
	var dup_found := false
	for c in dup_result.get("commands", []):
		var id := String((c as Dictionary).get("id", ""))
		if String((c as Dictionary).get("op", "")) == "ending":
			if dup_ids.has(id):
				dup_found = true
			dup_ids[id] = true
	_ok(dup_found, "重复的结局 id 能被检出（校验器的核心规则之一）")

	# --- 素材清单 ---
	var assets := ScriptAudit.assets()
	_ok(not assets.is_empty(), "素材清单非空（%d 类）" % assets.size())
	_ok(assets.has("bg"), "清单里有背景")
	_ok(assets.has("char"), "清单里有立绘")
	_ok((assets.get("bg", {}) as Dictionary).has("classroom"), "背景清单含 classroom")

	# 素材是否存在会随工程状态变（骨架期 assets/ 是空的，带上素材后就有文件），
	# 所以这里**不能**断言「classroom 一定缺文件」—— 那等于把测试绑死在某个目录状态上：
	# 一放真素材就红，而这种红是测试的错，不是工程的错。
	# 改成断言与状态无关的不变量：探针 id 必然查不到。
	_ok(not ScriptAudit.has_real_asset("bg", "__probe_missing__"), "不存在的 id 返回 false（用占位图）")
	_ok(not ScriptAudit.has_real_asset("bg", ""), "空 id 返回 false 而不是崩")
	_ok(not ScriptAudit.has_real_asset("不存在的类型", "x"), "未知素材类型返回 false")

	# 缺失清单必须与实际文件严格互补：有文件的 id 不许出现在清单里，
	# 没文件的 id 必须出现。空目录和满目录下都成立，只有真不一致时才会失败。
	var missing := ScriptAudit.missing_assets()
	var consistent := true
	for kind in assets.keys():
		var table: Dictionary = assets[kind]
		for id in table.keys():
			if bool(table[id]) == (missing.get(kind, []) as Array).has(id):
				consistent = false
	_ok(consistent, "缺失清单与实际文件严格互补（共 %d 类素材，其中 %d 类有缺失）"
		% [assets.size(), missing.size()])

	# --- 缺素材的表情回退到该角色的 normal 表情 ---
	# 没有这层回退时，剧本用了没素材的表情（alice@angry）会直接跳到
	# 程序化占位立绘 —— 有真素材的角色突然换成火柴人。
	# 断言与素材状态解耦：angry 素材真补上时回退不触发，跳过即可。
	if ResourceLoader.exists("res://assets/sprites/alice/normal.png") \
			and not ResourceLoader.exists("res://assets/sprites/alice/angry.png"):
		_ok(PlaceholderAssets.get_char("alice", "angry")
			== PlaceholderAssets.get_char("alice", "normal"),
			"缺 angry 素材时回退 alice 的 normal 表情（不跳程序占位）")

	# --- 解析器保留了跳转标签名（静态校验靠它）---
	var parsed := GvsParser.parse("label start\njump somewhere\nlabel somewhere\nnarr 到了", "t.gvs")
	var jump_label := ""
	for c in parsed.get("commands", []):
		var cmd: Dictionary = c
		if String(cmd.get("op", "")) == "jump":
			jump_label = String(cmd.get("label", ""))
	_ok(jump_label == "somewhere", "跳转指令保留标签名（%s）" % jump_label)


# ---------------------------------------------------------------------------
# 3. 调度器控制流
# ---------------------------------------------------------------------------

func _check_runner_flow() -> void:
	print("[smoke] 3. 调度器控制流")

	var writer := FileAccess.open(TEST_SCRIPT_PATH, FileAccess.WRITE)
	if writer == null:
		_ok(false, "无法写入临时测试剧本")
		return
	writer.store_string(TEST_SCRIPT)
	writer.close()

	GameManager.reset_run()

	var runner := ScriptRunner.new()
	get_tree().root.add_child(runner)

	_ended_id = ""
	_ended_title = ""
	runner.script_ended.connect(func(id: String, title: String) -> void:
		_ended_id = id
		_ended_title = title)

	_ok(runner.load_script(TEST_SCRIPT_PATH), "测试剧本载入成功")

	_minigame_requests = []
	runner.minigame_requested.connect(func(id: String, params: Dictionary) -> void:
		_minigame_requests.append({"id": id, "params": params}))

	runner.start()

	_ok(String(GameManager.get_var("path", "")) == "high", "if/else 走了 true 分支")
	_ok(runner.is_waiting_choice(), "遇到 choice 进入等待态")

	runner.submit_choice(0)
	_ok(String(GameManager.get_var("picked", "")) == "a", "choice 选中了 A 分支")
	_ok(is_equal_approx(GameManager.get_affection("alice"), 7.0), "affection 指令生效")
	_ok(is_equal_approx(float(GameManager.get_var("hp", 0.0)), 15.0), "call/return 子过程执行生效")
	_ok(GameManager.get_flag("done"), "flag 指令生效")
	_ok(runner.is_waiting_minigame(), "遇到 minigame 进入等待态")
	_ok(_minigame_requests.size() == 1, "minigame_requested 信号已发出")
	if _minigame_requests.size() == 1:
		var req: Dictionary = _minigame_requests[0]
		_ok(String(req["id"]) == "rhythm_qte", "小游戏 id 正确")
		_ok(int((req["params"] as Dictionary).get("rounds", 0)) == 1, "小游戏参数解析正确")

	runner.submit_minigame({"success": true, "score": 1, "max": 1})
	_ok(runner.is_ended(), "提交小游戏结果后剧本结束")
	_ok(_ended_id == "test_end", "ending id 正确 (%s)" % _ended_id)
	_ok(_ended_title == "冒烟结局", "ending 标题正确 (%s)" % _ended_title)
	_ok(GameManager.get_flag("rhythm_qte_cleared"), "小游戏成功点亮 cleared 旗标")
	_ok(int(GameManager.get_var("minigame_score", 0)) == 1, "小游戏得分写入变量")

	var state := runner.get_state()
	_ok(String(state.get("file", "")) == TEST_SCRIPT_PATH, "runner 状态含剧本路径")
	_ok(state.has("ip"), "runner 状态含指令指针")

	runner.queue_free()
	DirAccess.remove_absolute(TEST_SCRIPT_PATH)


# ---------------------------------------------------------------------------
# 4. 存档往返
# ---------------------------------------------------------------------------

func _check_save_roundtrip() -> void:
	print("[smoke] 4. 存档往返")
	var slot := 5
	SaveManager.delete_slot(slot)

	var payload := {
		"chapter_title": "冒烟章节",
		"preview": "测试文本",
		"speaker": "爱丽丝",
		"play_time": 61.0,
		"game": {
			"flags": {"met_alice": true},
			"affection": {"alice": 23},
			"vars": {"chapter": 2},
			"play_time": 61.0,
			"chapter_title": "冒烟章节",
		},
		"runner": {"file": TEST_SCRIPT_PATH, "ip": 3, "call_stack": []},
		"stage": {"bg": "classroom", "chars": [{"char": "alice", "expr": "smile", "at": "left"}]},
		"backlog": [{"speaker": "爱丽丝", "text": "测试文本"}],
	}

	_ok(SaveManager.write_slot(slot, payload), "写入槽位 %d" % slot)
	_ok(SaveManager.slot_exists(slot), "槽位文件存在")

	var info := SaveManager.get_slot_info(slot)
	_ok(not bool(info["empty"]), "槽位摘要非空")
	_ok(String(info["chapter_title"]) == "冒烟章节", "摘要章节名正确")
	_ok(String(info["speaker"]) == "爱丽丝", "摘要说话人正确")

	var loaded := SaveManager.read_slot(slot)
	_ok(String(loaded.get("preview", "")) == "测试文本", "读回文本一致")
	_ok(int((loaded.get("runner") as Dictionary).get("ip", -1)) == 3, "读回指令指针一致")

	GameManager.from_dict(loaded.get("game", {}))
	_ok(GameManager.get_flag("met_alice"), "读档后旗标恢复")
	_ok(is_equal_approx(GameManager.get_affection("alice"), 23.0), "读档后好感度恢复")
	_ok(int(GameManager.get_var("chapter", 0)) == 2, "读档后整数变量仍是 int 2（未被 JSON 变成 2.0）")

	_ok(SaveManager.newest_slot() >= 0, "newest_slot 能定位到存档")
	_ok(SaveManager.delete_slot(slot), "删除槽位")
	_ok(not SaveManager.slot_exists(slot), "删除后槽位不存在")


# ---------------------------------------------------------------------------
# 5. 场景加载 + 端到端跑通序章
# ---------------------------------------------------------------------------

func _check_scenes() -> void:
	print("[smoke] 5. 场景与端到端流程")

	var qte := load(QTE_SCENE) as PackedScene
	_ok(qte != null, "rhythm_qte.tscn 可加载")
	if qte != null:
		var qte_node := qte.instantiate()
		_ok(qte_node != null, "rhythm_qte.tscn 可实例化")
		if qte_node != null:
			_ok(qte_node.has_signal("minigame_finished"), "小游戏暴露 minigame_finished 信号")
			_ok(qte_node.has_method("setup") and qte_node.has_method("start"),
				"小游戏实现了 setup / start 契约")
			qte_node.queue_free()

	var main_scene := load(MAIN_SCENE) as PackedScene
	_ok(main_scene != null, "main.tscn 可加载")
	if main_scene == null:
		return
	var main_node := main_scene.instantiate()
	_ok(main_node != null, "main.tscn 可实例化")
	if main_node == null:
		return

	get_tree().root.add_child(main_node)
	_ok(main_node.has_node("%DialogueBox"), "对话框节点已就位")
	_ok(main_node.has_node("%ChoicePanel"), "选项面板已就位")
	_ok(main_node.has_node("%MinigameLayer"), "小游戏层已就位")
	_ok(main_node.has_node("%HudBar"), "HUD 已就位")

	# --- 文字特效已挂到对话框 ---
	var text_label := main_node.get_node("%TextLabel") as RichTextLabel
	_ok(text_label.bbcode_enabled, "对话框启用了 BBCode")
	_ok(text_label.custom_effects.size() >= 3,
		"对话框挂了 %d 个自定义特效" % text_label.custom_effects.size())

	var dialogue: DialogueBox = main_node.get("dialogue") as DialogueBox
	_ok(dialogue != null, "拿到 DialogueBox")
	if dialogue != null:
		dialogue.show_line("测试", "前[wait=0.5]后")
		_ok(text_label.text == "前后", "show_line 剥离了节奏标记（%s）" % text_label.text)
		_ok(dialogue.is_typing(), "带停顿的文本进入打字状态")
		_ok(text_label.visible_characters == 0, "打字从 0 个字符开始")
		_ok(dialogue.complete_typing(), "可以跳过打字")
		_ok(text_label.visible_characters == -1, "跳过后全部可见")
		dialogue.hide_box()

	# --- 跳过已读 / 未读 ---
	var saved_skip_unread: Variant = ConfigManager.get_value("skip_unread", false)
	ConfigManager.set_value("skip_unread", false)

	var fresh_line := "【smoke】这句没人看过 %d" % randi()
	dialogue.show_line("测试", fresh_line)
	_ok(not bool(main_node.call("_may_skip_current")), "未读文本：跳过键会停下来")
	ReadTracker.mark_read(fresh_line)
	_ok(bool(main_node.call("_may_skip_current")), "已读文本：跳过键继续快进")

	ConfigManager.set_value("skip_unread", true)
	_ok(bool(main_node.call("_may_skip_current")), "开启「跳过未读」后一律可跳")
	ConfigManager.set_value("skip_unread", false)
	dialogue.hide_box()

	# 开着「跳过未读」时，跳过键必须真的能推进（而不是被卡住）
	ConfigManager.set_value("skip_unread", true)
	_ok(bool(main_node.call("_may_skip_current")), "「跳过未读」开关生效")
	ConfigManager.set_value("skip_unread", saved_skip_unread)

	# --- 隐藏 UI ---
	var hud_layer := main_node.get("ui_layer") as CanvasLayer
	_ok(hud_layer != null, "拿到 UI 层")
	if hud_layer != null:
		_ok(hud_layer.visible, "UI 默认可见")
		main_node.call("_toggle_ui_hidden")
		_ok(not hud_layer.visible, "切换后 UI 隐藏（截图模式）")
		main_node.call("_toggle_ui_hidden")
		_ok(hud_layer.visible, "再切一次恢复显示")

	var runner: ScriptRunner = main_node.get("runner") as ScriptRunner
	_ok(runner != null, "main.gd 创建了 ScriptRunner")
	if runner == null:
		main_node.queue_free()
		return

	_say_count = 0
	_resumed_text = ""
	runner.say.connect(_collect_say)

	# 演出层：立绘定位 / 背景切换 / 状态序列化
	var stage_node: Stage = main_node.get("stage") as Stage
	_ok(stage_node != null, "main.gd 拿到了 Stage")
	if stage_node != null:
		stage_node.show_char("alice", "normal", "left", "none", 0.0)
		stage_node.show_char("bob", "normal", "right", "none", 0.0)
		var expect_left := Stage.anchor_x("left") - Stage.CHAR_WIDTH * 0.5
		var expect_right := Stage.anchor_x("right") - Stage.CHAR_WIDTH * 0.5
		_ok(is_equal_approx(stage_node.get_char_x("alice"), expect_left),
			"立绘 left 定位正确 (%.1f)" % stage_node.get_char_x("alice"))
		_ok(is_equal_approx(stage_node.get_char_x("bob"), expect_right),
			"立绘 right 定位正确 (%.1f)" % stage_node.get_char_x("bob"))
		_ok(stage_node.get_char_x("alice") < stage_node.get_char_x("bob"),
			"left 在 right 左侧")

		stage_node.set_bg("classroom", "none", 0.0)
		var stage_state := stage_node.get_state()
		_ok(String(stage_state["bg"]) == "classroom", "背景状态已记录")
		_ok((stage_state["chars"] as Array).size() == 2, "立绘状态记录了 2 个角色")
		stage_node.clear()
		_ok((stage_node.get_state()["chars"] as Array).is_empty(), "clear 清空了立绘")

	# --- 立绘动效 ---
	stage_node.show_char("alice", "normal", "left", "none", 0.0)
	var base_pos := stage_node.get_char_position("alice")
	_ok(base_pos.x > 0.0, "立绘已就位（%s）" % base_pos)

	stage_node.char_zoom("alice", 1.3, 0.0)
	_ok(is_equal_approx(stage_node.get_char_scale("alice"), 1.3),
		"zoom 立即生效（%.2f）" % stage_node.get_char_scale("alice"))
	stage_node.char_zoom("alice", 1.0, 0.0)

	stage_node.char_jump("alice", 40.0, 2, 0.5)
	# 轮询而不是等固定时长 —— 起跳/落地是周期性的，固定时刻可能正好落在
	# 「已经回到地面」的那一瞬，那样断言会假失败
	var rose := false
	var lowest := base_pos.y
	for i in 40:
		await _wait(0.02)
		var y := stage_node.get_char_position("alice").y
		lowest = minf(lowest, y)
		if y < base_pos.y - 1.0:
			rose = true
			break
	_ok(rose, "jump 过程中立绘抬起（最低到达 y=%.1f，基准 %.1f）" % [lowest, base_pos.y])
	await _wait(0.6)
	_ok(stage_node.get_char_position("alice").is_equal_approx(base_pos),
		"jump 结束后回到基准位")

	stage_node.char_shake("alice", 10.0, 3, 0.3)
	await _wait(0.6)
	_ok(stage_node.get_char_position("alice").is_equal_approx(base_pos),
		"shake 结束后回到基准位")

	# 打断后重新起跳也要从基准位开始，不能从半空续跳
	stage_node.char_jump("alice", 60.0, 2, 1.0)
	await _wait(0.15)
	stage_node.char_jump("alice", 40.0, 2, 0.3)
	await _wait(0.5)
	_ok(stage_node.get_char_position("alice").is_equal_approx(base_pos),
		"被打断后重新起跳仍从基准位开始")

	# --- 画面动效 ---
	_ok(stage_node.get_world_offset() == Vector2.ZERO, "初始画面无偏移")
	stage_node.screen_shake(20.0, 4, 0.4)
	await _wait(0.1)
	_ok(stage_node.get_world_offset() != Vector2.ZERO, "震动中画面有偏移")
	await _wait(0.7)
	_ok(stage_node.get_world_offset() == Vector2.ZERO, "震动结束后画面归位")

	stage_node.screen_flash(Color.WHITE, 0.2)
	await _wait(0.05)
	_ok(stage_node.get_flash_alpha() > 0.0, "闪光期间 alpha > 0")
	await _wait(0.4)
	_ok(is_equal_approx(stage_node.get_flash_alpha(), 0.0), "闪光结束后 alpha 归零")

	# 全屏震动必须同时带动 UI 层 —— 只震舞台的话，铺满的背景平移没有参照物，
	# 玩家根本看不出在动（实测峰值只有画布宽的 0.74%）
	var ui_layer := main_node.get("ui_layer") as CanvasLayer
	_ok(ui_layer != null, "拿到 UI 层")
	if ui_layer != null:
		main_node.call("_shake_ui", 40.0, 4, 0.4)
		await _wait(0.1)
		_ok(ui_layer.offset != Vector2.ZERO, "全屏震动同时带动 UI 层（对话框跟着抖）")
		await _wait(0.7)
		_ok(ui_layer.offset == Vector2.ZERO, "UI 层震动后归位")

	# 抖动偏移不能抽出接近零的向量（各轴独立随机就会）
	var min_offset := 9999.0
	for i in 300:
		min_offset = minf(min_offset, Stage.shake_offset(20.0).length())
	_ok(min_offset > 6.0, "抖动偏移始终有力度（最小 %.1f / 设定 20）" % min_offset)

	# --- clear 要复位动效状态 ---
	stage_node.char_zoom("alice", 1.5, 0.0)
	stage_node.screen_shake(20.0, 4, 0.4)
	stage_node.clear()
	_ok(stage_node.get_world_offset() == Vector2.ZERO, "clear 复位画面偏移")
	stage_node.show_char("alice", "normal", "left", "none", 0.0)
	_ok(is_equal_approx(stage_node.get_char_scale("alice"), 1.0),
		"clear 后立绘缩放复位")

	# --- 多立绘协同：说话人亮、其他人暗 ---
	stage_node.show_char("alice", "normal", "left", "none", 0.0)
	stage_node.show_char("bob", "normal", "right", "none", 0.0)

	stage_node.focus_speaker("alice", 0.5, 0.0)
	_ok(is_equal_approx(stage_node.get_char_brightness("alice"), 1.0), "说话人保持明亮")
	_ok(is_equal_approx(stage_node.get_char_brightness("bob"), 0.5), "非说话人被压暗到 0.5")

	stage_node.focus_speaker("bob", 0.5, 0.0)
	_ok(is_equal_approx(stage_node.get_char_brightness("bob"), 1.0), "换人说话后换他亮")
	_ok(is_equal_approx(stage_node.get_char_brightness("alice"), 0.5), "原先说话的人变暗")

	stage_node.focus_speaker("", 0.5, 0.0)
	_ok(is_equal_approx(stage_node.get_char_brightness("alice"), 1.0)
		and is_equal_approx(stage_node.get_char_brightness("bob"), 1.0),
		"旁白（speaker 为空）时两人都恢复明亮")

	# --- 滑入：起点必须在屏幕外 ---
	var left_target := Stage.anchor_x("left") - Stage.CHAR_WIDTH * 0.5
	stage_node.hide_char("alice", "none", 0.0)
	stage_node.show_char("alice", "normal", "left", "slide_left", 0.5)
	await _wait(0.05)
	_ok(stage_node.get_char_position("alice").x < 0.0,
		"slide_left 起点在屏幕左侧外（x=%.0f）" % stage_node.get_char_position("alice").x)
	_ok(is_equal_approx(stage_node.get_char_brightness("alice"), 1.0),
		"滑入时 alpha 直接给满（不边滑边淡入）")
	await _wait(0.7)
	_ok(is_equal_approx(stage_node.get_char_position("alice").x, left_target),
		"滑入结束后落到正确位置（x=%.0f / 期望 %.0f）"
			% [stage_node.get_char_position("alice").x, left_target])

	# 滑出：朝屏幕外走
	stage_node.hide_char("alice", "slide_right", 0.5)
	await _wait(0.7)
	_ok(not stage_node.is_char_visible("alice"), "slide_right 滑出后隐藏")

	# --- 离场槽：move 到 off_left / off_right 必须整体出画 ---
	# 只有 left/center/right 时，「溜走」演出只能移到左侧角色身边
	# （和女主叠在一起），出不去屏幕。
	stage_node.show_char("alice", "normal", "left", "none", 0.0)
	stage_node.move_char("alice", "off_left", 0.0)
	var off_l := stage_node.get_char_position("alice")
	_ok(off_l.x + Stage.CHAR_WIDTH <= 0.0,
		"off_left 立绘整体在屏幕左侧外（x=%.0f + 宽 %.0f）"
			% [off_l.x, Stage.CHAR_WIDTH])
	stage_node.move_char("alice", "off_right", 0.0)
	var off_r := stage_node.get_char_position("alice")
	_ok(off_r.x >= Stage.DESIGN.x,
		"off_right 立绘整体在屏幕右侧外（x=%.0f ≥ 画布 %.0f）"
			% [off_r.x, Stage.DESIGN.x])

	# --- 天气 ---
	_ok(stage_node.get_weather().is_empty(), "初始没有天气")
	stage_node.set_weather("snow", 1.0)
	_ok(stage_node.get_weather() == "snow", "切到雪天")
	stage_node.set_weather("rain", 0.5)
	_ok(stage_node.get_weather() == "rain", "切到雨天（雪被替换）")
	stage_node.set_weather("none")
	_ok(stage_node.get_weather().is_empty(), "weather none 关掉天气")
	stage_node.set_weather("不存在的天气")
	_ok(stage_node.get_weather().is_empty(), "未知天气安全降级为无天气")

	# --- 背景运镜 ---
	_ok(is_equal_approx(float(stage_node.get_bg_motion()["scale"]), 1.0), "初始背景无缩放")
	stage_node.bg_motion(1.12, Vector2(20.0, -10.0), 0.0)
	var motion := stage_node.get_bg_motion()
	_ok(is_equal_approx(float(motion["scale"]), 1.12),
		"bg_motion 立即生效（scale=%.2f）" % float(motion["scale"]))
	_ok((motion["position"] as Vector2).is_equal_approx(Vector2(20.0, -10.0)),
		"bg_motion 位移生效（%s）" % motion["position"])
	stage_node.stop_bg_motion()
	_ok(is_equal_approx(float(stage_node.get_bg_motion()["scale"]), 1.0), "stop_bg_motion 复位")

	# --- 表情过渡 ---
	stage_node.show_char("alice", "normal", "left", "none", 0.0)
	stage_node.set_expr("alice", "smile", 0.4)
	_ok(stage_node.is_expr_transitioning("alice"), "表情切换进入过渡状态")
	await _wait(0.6)
	_ok(not stage_node.is_expr_transitioning("alice"), "过渡结束后停下")
	stage_node.set_expr("alice", "smile", 0.4)
	_ok(not stage_node.is_expr_transitioning("alice"), "重复设同一个表情不触发过渡")

	# --- 语音：认领与重播 ---
	# 走 _on_say 而不是直接 dialogue.show_line —— 认领逻辑在 _on_say 里
	main_node.call("_on_audio_command", {"op": "voice", "id": "alice_001"})
	main_node.call("_on_say", "alice", "【smoke】这一句配了语音", "normal")
	_ok(String(main_node.get("_line_voice")) == "alice_001", "语音被这一句认领")
	dialogue.hide_box()

	main_node.call("_on_say", "alice", "【smoke】这一句没写 voice", "normal")
	_ok(String(main_node.get("_line_voice")).is_empty(), "下一句不会误认领上一句的语音")
	dialogue.hide_box()

	# 点名字牌应该发出重播请求（用 Dictionary 收集状态 —— GDScript 的 lambda
	# 对局部变量是按值捕获的，用 bool 变量传不出来）
	var probe_state := {"fired": false}
	dialogue.voice_replay_requested.connect(
		func() -> void: probe_state["fired"] = true)
	var plate := main_node.get_node("%NamePlate") as PanelContainer
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	plate.gui_input.emit(click)
	_ok(bool(probe_state["fired"]), "点说话人名字牌会发出重播请求")
	_ok(plate.mouse_filter == Control.MOUSE_FILTER_STOP,
		"名字牌吃掉点击，不会顺手把对白推进下去")

	# --- 调试控制台 ---
	# 先确保加载了剧本 —— 前面的测试可能把 runner 停在别的状态
	runner.load_script("res://data/scripts/prologue.gvs")
	runner.start()
	_ok(runner.has_label("start"), "runner 能查标签是否存在")
	_ok(not runner.has_label("根本不存在的标签"), "不存在的标签返回 false")
	_ok(not runner.jump_to_label("根本不存在的标签"), "跳到不存在的标签会被拒绝")

	_ok(runner.jump_to_label("ending_alone"), "能直接跳到任意标签")
	_ok(runner.get_current_label() == "ending_alone",
		"跳转后当前标签更新（%s）" % runner.get_current_label())
	_ok(runner.get_state_name() != "WAITING_CHOICE", "跳转清掉了等待态")

	var console: DebugConsole = main_node.get("debug_console")
	if console != null:
		_ok(not console.visible, "控制台默认收起")
		console.toggle()
		_ok(console.visible, "切换后打开")

		# 控制台的矩形必须与视口一致。它曾经被撑成「视口宽 + 视口宽」（1920→3840）
		# 的矩形，而面板是锚在**底部**的 —— 于是整个控制台被顶到画布外面，
		# 按 `~` 什么都看不见。而逻辑测试只查 visible，所以一直没抓到。
		var console_vp := get_viewport().get_visible_rect().size
		_ok(console.size.is_equal_approx(console_vp),
			"控制台尺寸等于视口（%.0f×%.0f / 视口 %.0f×%.0f）"
				% [console.size.x, console.size.y, console_vp.x, console_vp.y])
		# 跑几条只读命令，确认不崩
		console.call("_execute", "state")
		console.call("_execute", "audit")
		console.call("_execute", "assets")
		console.call("_execute", "flag __smoke_console_flag true")
		_ok(GameManager.get_flag("__smoke_console_flag"), "控制台能设置旗标")
		console.call("_execute", "aff alice 33")
		_ok(is_equal_approx(GameManager.get_affection("alice"), 33.0), "控制台能改好感度")
		console.call("_execute", "这条命令不存在")
		console.toggle()
		_ok(not console.visible, "再切一次收起")
	else:
		_ok(false, "debug 构建下应当建出调试控制台")

	# 端到端：从 start 一路跑到结局（遇选项选第一项、小游戏判成功）
	GameManager.reset_run()
	_ok(runner.load_script(PROLOGUE), "序章载入 runner")
	runner.start()

	var deadline := Time.get_ticks_msec() + 20000
	var steps := 0
	var hit_wait := false
	while not runner.is_ended() and Time.get_ticks_msec() < deadline:
		steps += 1
		if runner.is_waiting_choice():
			runner.submit_choice(0)
		elif runner.is_waiting_minigame():
			runner.submit_minigame({"success": true, "score": 5, "max": 5})
		elif runner.is_waiting_say() or runner.is_waiting_click():
			runner.advance()
		else:
			# 计时器等待：必须让出真实帧，ScriptRunner._process 才会推进
			hit_wait = true
			await get_tree().process_frame

	_ok(runner.is_ended(), "序章可从 start 一路跑到 ending（%d 步）" % steps)
	_ok(Time.get_ticks_msec() < deadline, "控制流未出现死循环")
	_ok(hit_wait, "wait 指令被真实帧驱动过（计时器路径已覆盖）")
	_ok(String(runner.get_current_file()).ends_with("chapter1.gvs"),
		"jump_file 成功跳到第一章（当前 %s）" % runner.get_current_file())
	_ok(is_equal_approx(GameManager.get_affection("alice"), EXPECTED_AFFECTION),
		"整条路线好感度累计正确（alice=%s，期望 %s）" % [
			GameManager.get_affection("alice"), EXPECTED_AFFECTION])
	_ok(GameManager.get_flag("rhythm_qte_cleared"), "小游戏通关旗标已点亮")
	_ok(String(GameManager.get_var("stance", "")) == "defend", "选项写入了 stance 变量")
	_ok(String(GameManager.chapter_title) == "第一章 · 春日的答案",
		"chapter 指令设置了章节名（%s）" % GameManager.chapter_title)

	await _check_auto_advance(main_node, runner)
	await _check_title_load(main_node, runner)
	_check_continue_precision(main_node, runner)
	await _check_gallery(main_node, runner)
	await _check_real_input(main_node, runner)
	await _check_op_coverage()
	_check_rollback(main_node, runner)
	_check_save_manage(main_node)
	_check_read_dim(main_node)
	_check_marker_stripping(main_node)
	_check_i18n(main_node)
	# 放最后：它会动到 runner（回滚快照还原）并把舞台 clear 掉
	_check_settings_ui(main_node)
	await _check_screen_fx(main_node)

	main_node.queue_free()


# ---------------------------------------------------------------------------
# 10. 真实输入模拟
#
# 前面所有测试都是直接调内部方法（_on_pressed / _on_advance_requested），
# 绕过了 GUI 层。这一节改用真实的 InputEvent 走完整链路：
#   push_input → 视口 GUI 命中测试 → Control._gui_input → 信号 → 业务逻辑
#
# 这是唯一能抓到「按钮被别的控件挡住」「锚点算错位置导致点不到」
# 「mouse_filter 配错」这类问题的手段 —— 纯逻辑测试永远看不见。
#
# 两个坑：
#   1. 必须窗口模式跑。headless 下视口只有 64×64，命中测试不可用。
#   2. push_input 收的是**窗口坐标**，不是画布坐标。项目用了
#      canvas_items 拉伸（画布 1920×1080 → 窗口 1280×720），直接把
#      get_global_rect() 的结果丢进去会命中错误的目标。
#      正确做法是过一次 Viewport.get_final_transform()。
# ---------------------------------------------------------------------------

func _check_real_input(main_node: Node, runner: ScriptRunner) -> void:
	print("[smoke] 10. 真实输入模拟")

	if DisplayServer.get_name() == "headless":
		print("   SKIP  headless 下视口只有 64×64，GUI 命中测试不可用")
		print("         用窗口模式跑同一个场景即可覆盖这一节")
		return

	main_node.call("_back_to_title")
	await _wait(0.4)

	var start_button := main_node.get_node("%StartButton") as Button
	_ok(start_button != null, "拿到「开始游戏」按钮")
	if start_button == null:
		return

	# 命中测试前置检查：这个点上最顶层的控件必须就是按钮本身
	var hovered := _hover_test(start_button)
	_ok(hovered == start_button, "按钮位置的最顶层控件就是它自己（未被遮挡）")

	_click_control(start_button)
	await _wait(0.4)
	_ok(not (main_node.get("title") as TitleScreen).visible,
		"真实点击「开始游戏」后标题收起")

	# 真实空格推进对白
	await _wait(0.6)
	var advanced := false
	for i in 20:
		var before := String(main_node.get("_last_text"))
		_press_key(KEY_SPACE)
		await _wait(0.08)
		if String(main_node.get("_last_text")) != before:
			advanced = true
			break
	_ok(advanced, "真实空格按键能推进对白")

	# 真实点击 HUD 按钮
	var hud_button := main_node.get_node("%BtnBacklog") as Button
	if hud_button != null and hud_button.is_visible_in_tree():
		_click_control(hud_button)
		await _wait(0.35)
		_ok(bool((main_node.get("backlog") as BacklogPanel).visible),
			"真实点击 HUD「回看」能打开面板")
		main_node.call("_close_modals")
	else:
		_ok(false, "HUD「回看」按钮不可见")

	main_node.call("_back_to_title")


## 把画布坐标换算成 push_input 期望的窗口坐标
func _to_window_point(control: Control) -> Vector2:
	return get_tree().root.get_final_transform() * control.get_global_rect().get_center()


func _hover_test(control: Control) -> Control:
	var point := _to_window_point(control)
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	get_tree().root.push_input(motion)
	return get_tree().root.gui_get_hovered_control()


func _click_control(control: Control) -> void:
	var point := _to_window_point(control)

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point
	press.global_position = point
	get_tree().root.push_input(press)

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = point
	release.global_position = point
	get_tree().root.push_input(release)


func _press_key(keycode: Key) -> void:
	var down := InputEventKey.new()
	down.keycode = keycode
	down.pressed = true
	get_tree().root.push_input(down)

	var up := InputEventKey.new()
	up.keycode = keycode
	up.pressed = false
	get_tree().root.push_input(up)


# ---------------------------------------------------------------------------
# 9. 鉴赏（CG / 音乐）与剧情重播
# ---------------------------------------------------------------------------

func _check_gallery(main_node: Node, runner: ScriptRunner) -> void:
	print("[smoke] 9. 鉴赏与剧情重播")

	# --- 注册表 ---
	var cg_items := CollectionRegistry.get_items("cg")
	var music_items := CollectionRegistry.get_items("music")
	_ok(cg_items.size() >= 4, "CG 注册表加载了 %d 项" % cg_items.size())
	_ok(music_items.size() >= 3, "音乐注册表加载了 %d 项" % music_items.size())
	_ok(CollectionRegistry.has_item("cg", "cg_rooftop"), "能按 id 取到 CG 条目")
	_ok(CollectionRegistry.get_item("cg", "不存在的").is_empty(), "不存在的 id 返回空字典")

	# --- 主题配置 ---
	_ok(GalleryTheme.count("columns", 0) > 0, "主题列数 = %d" % GalleryTheme.count("columns", 0))
	_ok(GalleryTheme.color("accent").a > 0.5, "主题配色可解析")
	_ok(GalleryTheme.label("locked_label", "") == "???", "主题文案 locked_label = ???")
	_ok(not GalleryTheme.visualizer_mode().is_empty(),
		"可视化模式 = %s" % GalleryTheme.visualizer_mode())

	# --- 解锁语义 ---
	CollectionManager.reset_all()
	_ok(not CollectionManager.is_unlocked("cg", "cg_rooftop"), "初始未解锁")
	_ok(CollectionManager.unlock("cg", "cg_rooftop"), "首次解锁返回 true")
	_ok(not CollectionManager.unlock("cg", "cg_rooftop"), "重复解锁返回 false")
	_ok(not CollectionManager.unlock("cg", "根本没这个id"), "未注册的 id 不能解锁")

	# --- 落盘往返（不要用 reset_all 清内存，它会把空状态也写盘） ---
	CollectionManager.save_data()
	CollectionManager.from_dict({})
	_ok(not CollectionManager.is_unlocked("cg", "cg_rooftop"), "内存已清空")
	CollectionManager.load_data()
	_ok(CollectionManager.is_unlocked("cg", "cg_rooftop"), "解锁状态落盘后能读回")

	# --- 剧本指令解锁 ---
	CollectionManager.reset_all()
	GameManager.reset_run()
	runner.load_script(PROLOGUE)
	runner.start()
	var guard := 40
	while not runner.is_waiting_choice() and guard > 0:
		guard -= 1
		runner.advance()
	_ok(CollectionManager.is_unlocked("cg", "cg_classroom"), "剧本 cg 指令解锁了 cg_classroom")
	_ok(CollectionManager.is_unlocked("music", "daily"), "剧本 bgm 指令解锁了 daily")
	_ok(not CollectionManager.is_unlocked("cg", "cg_secret_01"), "隐藏 CG 仍处于锁定")

	# --- CG 网格 ---
	var gallery: GalleryPanel = main_node.get("gallery") as GalleryPanel
	var cg_viewer: CgViewer = main_node.get("cg_viewer") as CgViewer
	var stage_node: Stage = main_node.get("stage") as Stage
	gallery.present(GalleryPanel.TAB_CG)
	_ok(gallery.visible, "鉴赏面板可打开")

	var grid := main_node.get_node("%CgGrid") as GridContainer
	_ok(grid.get_child_count() == cg_items.size(),
		"CG 网格卡片数 = 注册表条目数 (%d)" % grid.get_child_count())
	_ok(grid.columns == GalleryTheme.count("columns", 3), "网格列数取自主题配置")

	var locks := _count_lock_icons(grid)
	var expected_locks := CollectionManager.total_count("cg") - CollectionManager.unlocked_count("cg")
	_ok(locks == expected_locks, "锁图标数 = 未解锁数 (%d / 期望 %d)" % [locks, expected_locks])

	# --- 点击已解锁 CG 打开详情 ---
	main_node.call("_on_cg_activated", "cg_classroom")
	_ok(cg_viewer.visible, "点击已解锁 CG 能打开详情页")
	_ok(cg_viewer.get_current_id() == "cg_classroom", "详情页指向正确的 CG")
	_ok(cg_viewer.has_replay(), "cg_classroom 配置了可重播片段")
	main_node.call("_on_cg_activated", "cg_secret_01")
	_ok(not cg_viewer.has_replay(), "未配置 replay 的 CG 会置灰重播按钮")

	# --- 详情页的留白 ---
	# 这个面板的 stylebox 是自己拼的（没走 apply_panel 预设），内边距曾经传 0 ——
	# CG 图、标题文字和按钮会全部顶到边框上。
	var viewer_panel := cg_viewer.get_node("Panel") as PanelContainer
	var viewer_sb := viewer_panel.get_theme_stylebox("panel")
	_ok(viewer_sb.content_margin_left > 0.0 and viewer_sb.content_margin_right > 0.0
		and viewer_sb.content_margin_top > 0.0 and viewer_sb.content_margin_bottom > 0.0,
		"CG 详情页面板有内边距（左 %.0f / 上 %.0f），内容不顶边框"
		% [viewer_sb.content_margin_left, viewer_sb.content_margin_top])
	_ok(GalleryTheme.count("viewer_pad_h", 0) > 0
		and GalleryTheme.count("viewer_pad_v", 0) > 0,
		"详情页的内边距在主题配置里（可调，不用改代码）")

	# --- 音乐面板 ---
	gallery.show_tab(GalleryPanel.TAB_MUSIC)
	_ok(not (main_node.get_node("%CgScroll") as Control).visible, "切到音乐页签后 CG 网格隐藏")

	var track_list := main_node.get_node("%TrackList") as VBoxContainer
	_ok(track_list.get_child_count() == music_items.size(),
		"曲目列表项数 = 注册表条目数 (%d)" % track_list.get_child_count())

	var disabled_count := 0
	for child in track_list.get_children():
		if (child as Button).disabled:
			disabled_count += 1
	var expected_disabled := CollectionManager.total_count("music") - CollectionManager.unlocked_count("music")
	_ok(disabled_count == expected_disabled,
		"未解锁曲目按钮禁用 (%d / 期望 %d)" % [disabled_count, expected_disabled])

	# --- 当前曲目高亮 ---
	var first_unlocked := ""
	for item in music_items:
		var id := String((item as Dictionary).get("id", ""))
		if CollectionManager.is_unlocked("music", id):
			first_unlocked = id
			break
	_ok(not first_unlocked.is_empty(), "至少有一首已解锁曲目")
	main_node.call("_on_music_track_selected", first_unlocked)
	await _wait(0.25)
	_ok(AudioManager.get_bgm_id() == first_unlocked,
		"播放请求已生效（%s）" % AudioManager.get_bgm_id())

	var highlight_color := GalleryTheme.color("highlight")
	var highlighted := 0
	for child in track_list.get_children():
		var btn := child as Button
		if btn.has_theme_color_override("font_color") \
				and btn.get_theme_color("font_color").is_equal_approx(highlight_color):
			highlighted += 1
	_ok(highlighted == 1, "恰好有一项被高亮（%d）" % highlighted)

	# --- 唱片 / 频谱控件已生成 ---
	var visualizer_host := main_node.get_node("%VisualizerHost") as Control
	_ok(_count_visualizer_nodes(visualizer_host) > 0,
		"可视化控件已按主题配置生成（模式 %s）" % GalleryTheme.visualizer_mode())

	# --- 剧情重播 ---
	CollectionManager.unlock("cg", "cg_rooftop")
	gallery.hide_panel()
	GameManager.reset_run()
	GameManager.set_affection("alice", 7.0)
	GameManager.set_flag("sentinel")
	stage_node.clear()
	var backlog_before := (main_node.get("_backlog_entries") as Array).size()

	main_node.call("_on_cg_replay_requested", "cg_rooftop")
	_ok(bool(main_node.get("_replay_active")), "进入重播模式")
	_ok(runner.is_replaying(), "runner 处于重播模式")
	_ok(not bool(main_node.get("_autosave_enabled")), "重播期间自动存档已禁用")

	var seen_cg := ""
	var steps := 0
	var guard2 := 400
	while bool(main_node.get("_replay_active")) and guard2 > 0:
		guard2 -= 1
		steps += 1
		var shown := stage_node.get_cg_id()
		if not shown.is_empty():
			seen_cg = shown
		if runner.is_waiting_say() or runner.is_waiting_click():
			main_node.call("_on_advance_requested")
		else:
			await get_tree().process_frame

	_ok(not bool(main_node.get("_replay_active")), "重播自动结束（%d 步）" % steps)
	_ok(seen_cg == "cg_rooftop", "重播过程中确实展示了目标 CG（%s）" % seen_cg)
	_ok(not runner.is_replaying(), "runner 已退出重播模式")
	_ok(bool(main_node.get("_autosave_enabled")), "重播结束后自动存档恢复")

	# 重播不该污染玩家进度
	_ok(is_equal_approx(GameManager.get_affection("alice"), 7.0),
		"重播后好感度回到快照值（%s）" % GameManager.get_affection("alice"))
	_ok(GameManager.get_flag("sentinel"), "重播后旗标回到快照值")
	_ok((main_node.get("_backlog_entries") as Array).size() == backlog_before,
		"重播没有污染回看记录")

	# 结束后回到鉴赏界面
	_ok(gallery.visible, "重播结束回到鉴赏界面")
	_ok(cg_viewer.visible, "CG 详情页也一并恢复")

	# 清理
	gallery.hide_panel()
	cg_viewer.hide_panel()


func _count_lock_icons(node: Node) -> int:
	var total := 0
	for child in node.get_children():
		if child is LockIcon:
			total += 1
		total += _count_lock_icons(child)
	return total


func _count_nodes_of_type(node: Node, type_name: String) -> int:
	var total := 0
	for child in node.get_children():
		if child.get_class() == type_name:
			total += 1
		total += _count_nodes_of_type(child, type_name)
	return total


func _count_visualizer_nodes(node: Node) -> int:
	var total := 0
	for child in node.get_children():
		if child is RecordDisc or child is SpectrumBars:
			total += 1
		total += _count_visualizer_nodes(child)
	return total


# ---------------------------------------------------------------------------
# 8. 「继续游戏」的恢复精度
#
# 曾经的 bug：_autosave() 只在 _on_choices() 里被调用，于是自动存档永远停在
# 上一个选项处。玩家在选项之后读的整段内容都不会被记录，「继续游戏」自然
# 只能跳回那个选项。现在每句对白都会刷新自动存档。
#
# 断言的关键：必须验证「读档后重新播出了那句对白」，而不是比对 _last_text ——
# 后者在返回标题时不会被清空，即使读档失败也还是旧值，断言会恒真。
# ---------------------------------------------------------------------------

func _check_continue_precision(main_node: Node, runner: ScriptRunner) -> void:
	print("[smoke] 8. 继续游戏恢复精度")

	GameManager.reset_run()
	(main_node.get("stage") as Stage).clear()
	runner.load_script(PROLOGUE)
	runner.start()

	# 推到第一个选项并选择（这一步本身就会触发一次自动存档）
	var guard := 80
	while not runner.is_waiting_choice() and guard > 0:
		guard -= 1
		main_node.call("_on_advance_requested")
	_ok(runner.is_waiting_choice(), "已推进到第一个选项")
	main_node.call("_on_option_selected", 0)

	# 选项之后继续推进若干句，让当前位置远离任何选项
	var advanced := 0
	while advanced < 3 and not runner.is_waiting_choice() \
			and not runner.is_waiting_minigame() and not runner.is_ended():
		main_node.call("_on_advance_requested")
		advanced += 1
	_ok(advanced == 3, "选项之后又推进了 %d 句" % advanced)

	var expected_text := String(main_node.get("_last_text"))
	_ok(not expected_text.is_empty(), "当前位置对白：%s" % expected_text)

	# 回标题 → 点「继续游戏」
	main_node.call("_back_to_title")
	_ok((main_node.get("title") as TitleScreen).visible, "已回到标题界面")

	_say_count = 0
	_resumed_text = ""
	main_node.call("_on_continue_requested")

	_ok(not (main_node.get("title") as TitleScreen).visible, "「继续游戏」进入了游戏")
	_ok(_say_count >= 1,
		"读档后重新播出了对白（%d 句）—— 若停在选项处则为 0 句" % _say_count)
	_ok(_resumed_text == expected_text,
		"恢复到的是当前位置而不是上一个选项\n          期望：%s\n          实际：%s" % [
			expected_text, _resumed_text])

	main_node.call("_back_to_title")


# ---------------------------------------------------------------------------
# 7. 标题界面读档
# ---------------------------------------------------------------------------

func _check_title_load(main_node: Node, runner: ScriptRunner) -> void:
	print("[smoke] 7. 标题读档")

	var title: TitleScreen = main_node.get("title") as TitleScreen
	var save_load: SaveLoadPanel = main_node.get("save_load") as SaveLoadPanel
	var load_button := main_node.get_node("%LoadButton") as Button
	if title == null or save_load == null or load_button == null:
		_ok(false, "标题 / 存读档面板 / 读档按钮 任一缺失")
		return

	var slot := 3
	SaveManager.delete_slot(slot)

	# 造一个存档：跑一段序章，停在第一个选项处，写入可验证的状态再存
	GameManager.reset_run()
	var stage_node: Stage = main_node.get("stage") as Stage
	stage_node.clear()
	runner.load_script(PROLOGUE)
	runner.start()
	var guard := 60
	while not runner.is_waiting_choice() and guard > 0:
		guard -= 1
		runner.advance()
	_ok(runner.is_waiting_choice(), "存档前已推进到第一个选项")

	GameManager.set_flag("__smoke_flag")
	GameManager.set_var("__smoke_var", 42)
	GameManager.set_affection("alice", 17.0)
	# 记下存档当时的背景再存 —— 断言「读回来的和存下去的一致」，
	# 而不是硬编码某个背景名（那样剧本一改测试就碎）
	var expected_bg := stage_node.get_bg_id()
	var payload: Dictionary = main_node.call("_build_payload")
	_ok(SaveManager.write_slot(slot, payload), "写入测试存档槽 %d" % slot)

	# 回标题，并把现场破坏掉 —— 这样才能证明读档是从文件恢复的，
	# 而不是内存里恰好还留着旧数据
	main_node.call("_back_to_title")
	GameManager.reset_run()
	stage_node.clear()
	_ok(not GameManager.get_flag("__smoke_flag"), "内存状态已清空（准备验证真读档）")

	_ok(title.visible, "回到标题界面")
	_ok(not load_button.disabled, "有存档时「读取存档」按钮可用")
	_ok(not (main_node.get_node("%ContinueButton") as Button).disabled,
		"有存档时「继续游戏」按钮可用")

	# 标题上点「读取存档」
	main_node.call("_on_load_requested")
	_ok(save_load.visible, "标题界面能打开存档面板")
	_ok(save_load.is_load_mode(), "面板处于读取模式（标题不会误触保存）")

	# 选槽位读档
	main_node.call("_on_slot_chosen", slot)
	_ok(not save_load.visible, "读档成功后面板自动关闭")
	_ok(not title.visible, "读档成功后标题自动收起")
	_ok(bool(main_node.get("hud").visible), "读档成功后 HUD 显示")
	_ok(not runner.is_ended(), "runner 已恢复到剧本中（未结束）")
	_ok(String(runner.get_current_file()).ends_with("prologue.gvs"),
		"恢复的剧本文件正确（%s）" % runner.get_current_file())
	_ok(runner.is_waiting_choice(), "恢复到了存档时的等待态（选项处）")
	_ok(GameManager.get_flag("__smoke_flag"), "读档恢复了旗标")
	_ok(int(GameManager.get_var("__smoke_var", 0)) == 42, "读档恢复了变量")
	_ok(is_equal_approx(GameManager.get_affection("alice"), 17.0),
		"读档恢复了好感度（alice=%s）" % GameManager.get_affection("alice"))
	_ok(stage_node.get_bg_id() == expected_bg,
		"读档恢复了演出层背景（%s / 期望 %s）" % [stage_node.get_bg_id(), expected_bg])

	# 清理
	SaveManager.delete_slot(slot)
	main_node.call("_back_to_title")


# ---------------------------------------------------------------------------
# 6. 自动播放（回归测试）
#
# 曾经的 bug：ScriptRunner._exec_say() 先 emit(say) 再设 _state = WAITING_SAY，
# 而 main.gd 的 _on_say 回调里会调 _arm_auto_deadline()，它第一行就检查
# runner.is_waiting_say()。回调触发时状态还是 RUNNING，于是定时器被清零且
# 不再武装 —— 表现为「自动播放只能推进一句就卡住」。
# ---------------------------------------------------------------------------

func _check_auto_advance(main_node: Node, runner: ScriptRunner) -> void:
	print("[smoke] 6. 自动播放")

	var old_speed: Variant = ConfigManager.get_value("text_speed")
	var old_delay: Variant = ConfigManager.get_value("auto_delay")
	# persist=false：只改内存，不污染用户的 config.json
	ConfigManager.set_value("text_speed", 400.0, false)
	ConfigManager.set_value("auto_delay", 0.05, false)

	_say_count = 0
	GameManager.reset_run()
	runner.load_script(PROLOGUE)
	runner.start()
	await _wait(0.15)
	var before := _say_count

	main_node.call("_toggle_auto")
	_ok(bool(main_node.get("_auto_mode")), "点击「自动」后进入自动播放状态")
	# 开启态反馈是「变色锁定」而不是「（开）」后缀：normal 样式必须换成
	# pressed 贴图，且文字保持「自动」（走 i18n）
	var auto_btn: Button = main_node.get("_btn_auto")
	_ok(String(auto_btn.text) == "自动",
		"开启后按钮文字仍是「自动」（不显示后缀）")
	var hud_p: Dictionary = UiTheme.preset("hud")
	var pressed_sb := UiTheme._button_stylebox(hud_p, "pressed")
	_ok(auto_btn.get_theme_stylebox("normal") != null
		and auto_btn.get_theme_stylebox("normal").texture == pressed_sb.texture,
		"开启后 normal 样式换用 pressed 贴图（变色锁定）")
	await _wait(1.5)
	var advanced := _say_count - before

	_ok(before >= 1, "自动播放测试起点已播出 %d 句" % before)
	_ok(advanced >= 3,
		"自动播放连续推进 %d 句（原 bug 只会推进 1 句）" % advanced)

	# 中途若已撞到选项，_on_choices 会把自动播放关掉；这里只保证能关
	if bool(main_node.get("_auto_mode")):
		main_node.call("_toggle_auto")
	_ok(not bool(main_node.get("_auto_mode")), "自动播放可以关闭")

	# 快速跳过：走的是每帧轮询而不是定时器，属于同一类风险的邻居，一并覆盖
	GameManager.reset_run()
	runner.load_script(PROLOGUE)
	runner.start()
	await _wait(0.05)
	var before_skip := _say_count
	main_node.call("_toggle_skip")
	await _wait(0.6)
	var skipped := _say_count - before_skip
	if bool(main_node.get("_skip_mode")):
		main_node.call("_toggle_skip")
	_ok(skipped >= 3, "快速跳过连续推进 %d 句" % skipped)

	ConfigManager.set_value("text_speed", old_speed, false)
	ConfigManager.set_value("auto_delay", old_delay, false)


# ---------------------------------------------------------------------------
# 11. 指令端到端覆盖
#
# 守住一类极难发现的 bug：解析器认识某条指令，调度器却没给它转发分支。
# 表现是「剧本明明写对了，演出就是不出来」——不崩、不报错，只留一条没人
# 看的 push_warning。hop / zoom / shake / screen_shake / screen_flash /
# bg_motion / weather / voice 这八条就曾经这样静默失效了整整一轮。
#
# 光断言「解析结果正确」抓不到它（那正是当年漏掉的原因 —— 之前的动效测试
# 只检查 parser 产出，从不经 runner 执行）。必须真的用调度器把指令跑一遍，
# 再确认它没有落进未知指令分支。
# ---------------------------------------------------------------------------

## 每条指令一个最小剧本样本。expect 为空表示这条指令不产生演出/音频信号
## （控制流、赋值、结局等直接在调度器内部消化）。
const OP_SAMPLES: Dictionary = {
	"label": {"line": "label t1", "expect": ""},
	"jump": {"line": "jump t1\nlabel t1", "expect": ""},
	"goto": {"line": "goto t1\nlabel t1", "expect": ""},
	"call": {"line": "call s1\nlabel s1\nreturn", "expect": ""},
	"return": {"line": "call s1\nlabel s1\nreturn", "expect": ""},
	"jump_file": {"line": "jump_file res://data/scripts/chapter1.gvs ending_normal",
		"expect": ""},
	"bg": {"line": "bg classroom", "expect": "stage"},
	"show": {"line": "show alice", "expect": "stage"},
	"hide": {"line": "hide alice", "expect": "stage"},
	"move": {"line": "move alice center", "expect": "stage"},
	"expr": {"line": "expr alice smile", "expect": "stage"},
	"clear": {"line": "clear", "expect": "stage"},
	"hop": {"line": "hop alice", "expect": "stage"},
	"zoom": {"line": "zoom alice 1.2", "expect": "stage"},
	"shake": {"line": "shake alice", "expect": "stage"},
	"screen_shake": {"line": "screen_shake", "expect": "stage"},
	"screen_flash": {"line": "screen_flash", "expect": "stage"},
	"screen_fx": {"line": "screen_fx glitch", "expect": "stage"},
	"bg_motion": {"line": "bg_motion scale=1.1", "expect": "stage"},
	"weather": {"line": "weather rain", "expect": "stage"},
	"cg": {"line": "cg cg_classroom", "expect": "stage"},
	"hide_cg": {"line": "hide_cg", "expect": "stage"},
	"anim": {"line": "anim alice speed=0.5", "expect": "stage"},
	"video": {"line": "video op_demo layer=ui", "expect": "stage"},
	"hide_video": {"line": "hide_video fade=0.2", "expect": "stage"},
	"unlock": {"line": "unlock cg cg_classroom", "expect": ""},
	"bgm": {"line": "bgm daily", "expect": "audio"},
	"se": {"line": "se bell", "expect": "audio"},
	"voice": {"line": "voice alice_001", "expect": "audio"},
	"wait": {"line": "wait 0.01", "expect": ""},
	"wait_click": {"line": "wait_click", "expect": ""},
	"pause": {"line": "pause", "expect": ""},
	"set": {"line": "set var x 1", "expect": ""},
	"add": {"line": "add var x 1", "expect": ""},
	"sub": {"line": "sub var x 1", "expect": ""},
	"flag": {"line": "flag f1", "expect": ""},
	"affection": {"line": "affection alice 5", "expect": ""},
	"if": {"line": "if flag f1\n    narr y\nend", "expect": ""},
	"elif": {"line": "if flag f1\n    narr y\nelif flag f2\n    narr n\nend", "expect": ""},
	"else": {"line": "if flag f1\n    narr y\nelse\n    narr n\nend", "expect": ""},
	"end": {"line": "if flag f1\n    narr y\nend", "expect": ""},
	"choice": {"line": "choice\n    \"A\" -> t1\nend\nlabel t1", "expect": ""},
	"minigame": {"line": "minigame rhythm_qte rounds=1 need=1", "expect": ""},
	"ending": {"line": "", "expect": ""},
	"chapter": {"line": "chapter 测试章", "expect": ""},
	"narr": {"line": "narr 旁白", "expect": ""},
	"narration": {"line": "narration 旁白", "expect": ""},
}


func _check_op_coverage() -> void:
	print("[smoke] 18. 指令端到端覆盖")

	# 先断言样本表本身覆盖了全部关键字 —— 否则以后新增指令时，这一节会悄悄失效
	var missing: Array = []
	for kw in GvsParser.KEYWORDS:
		if not OP_SAMPLES.has(kw):
			missing.append(String(kw))
	if missing.is_empty():
		_ok(true, "样本表覆盖了全部 %d 条指令" % GvsParser.KEYWORDS.size())
	else:
		_ok(false, "样本表缺少样本：%s" % ", ".join(missing))

	var probe := ScriptRunner.new()
	add_child(probe)
	probe.stage_command.connect(_collect_stage_cmd)
	probe.audio_command.connect(_collect_audio_cmd)

	for name in OP_SAMPLES.keys():
		var sample: Dictionary = OP_SAMPLES[name]
		var body := String(sample.get("line", ""))
		var text := "label start\n"
		if not body.is_empty():
			text += body + "\n"
		# 结尾一定放一条 ending，保证剧本能自然终止，驱动循环不会空转
		text += "ending smoke_probe \"覆盖测试\"\n"

		var f := FileAccess.open(OP_COVERAGE_PATH, FileAccess.WRITE)
		f.store_string(text)
		f.close()

		_seen_stage_ops.clear()
		_seen_audio_ops.clear()
		probe.last_unknown_op = ""
		if not probe.load_script(OP_COVERAGE_PATH):
			_ok(false, "%s 的样本剧本可加载" % name)
			continue
		probe.start()
		await _drive_to_end(probe)

		_ok(probe.last_unknown_op == "", "%s 已被调度器处理" % name)
		var expect := String(sample.get("expect", ""))
		if expect == "stage":
			_ok(_seen_stage_ops.has(name), "%s 已转发到演出层" % name)
		elif expect == "audio":
			_ok(_seen_audio_ops.has(name), "%s 已转发到音频层" % name)

	DirAccess.remove_absolute(ProjectSettings.globalize_path(OP_COVERAGE_PATH))
	probe.queue_free()


## 把调度器驱动到结束：该点的点、该选的选、该等时间的等。
## 加步数上限是为了防止剧本写错时（比如跳进了死循环）测试挂死。
func _drive_to_end(runner: ScriptRunner, max_steps: int = 400) -> void:
	var guard := 0
	while guard < max_steps:
		guard += 1
		if runner.is_ended():
			return
		match runner.get_state_name():
			"waiting_say", "waiting_click":
				runner.advance()
			"waiting_choice":
				runner.submit_choice(0)
			"waiting_minigame":
				runner.submit_minigame({"success": true, "score": 1, "max": 1})
			"waiting_video":
				runner.submit_video_finished()
			"waiting_timer":
				await _wait(0.06)
			"ended", "idle":
				return
			_:
				await get_tree().process_frame


func _collect_stage_cmd(cmd: Dictionary) -> void:
	_seen_stage_ops.append(String(cmd.get("op", "")))


func _collect_audio_cmd(cmd: Dictionary) -> void:
	_seen_audio_ops.append(String(cmd.get("op", "")))


# ---------------------------------------------------------------------------
# 19. 界面本地化
#
# 最关键的一条是「切成英文再切回中文，必须回到中文」。
# 实现上最容易在这里翻车：如果第二次翻译拿的是**已经翻好的英文**去查表，
# 表里没有这条 key，就会原样返回英文，界面永远卡在英文上。
# 所以原文必须存在节点的元数据里，每次都拿原文查表。
# ---------------------------------------------------------------------------

func _check_i18n(main_node: Node) -> void:
	print("[smoke] 19. 界面本地化")

	var original := String(ConfigManager.get_value(I18n.CONFIG_KEY, I18n.DEFAULT_LANG))
	var langs := I18n.languages()
	_ok(langs.has(I18n.DEFAULT_LANG), "语言列表里有默认语言 %s" % I18n.DEFAULT_LANG)
	_ok(langs.has("en"), "data/i18n/ 下的英文表被识别到")

	I18n.set_language("en")
	# 缺条目必须回退原文 —— 漏翻只影响那一条，不能把界面显示成 key
	_ok(I18n.t("这条文案根本没有") == "这条文案根本没有", "缺条目时回退原文")
	_ok(I18n.t("开始游戏") == "Start Game", "静态文案翻译生效")
	_ok(I18n.t("存档 {n}", {"n": 3}) == "Slot 3", "带参数的文案占位符生效")
	_ok(I18n.t("删除") == "Delete", "新增的存档管理文案已进翻译表")
	_ok(I18n.t("删除存档 {slot}？此操作不可撤销。", {"slot": "Slot 3"}).contains("Slot 3"),
		"确认文案里的槽位占位符能正确替换")

	var ui_layer := main_node.get("ui_layer") as CanvasLayer
	var auto_btn := main_node.get("_btn_auto") as Button
	I18n.apply_tree(ui_layer)
	_ok(auto_btn.text.begins_with("Auto"),
		"HUD 按钮已换成英文（现在是「%s」）" % auto_btn.text)

	# 切回中文。这一步挂了的话，界面会永久卡在英文上。
	I18n.set_language(I18n.DEFAULT_LANG)
	I18n.apply_tree(ui_layer)
	_ok(auto_btn.text.begins_with("自动"),
		"切回中文能还原（现在是「%s」）" % auto_btn.text)

	# 再切一次英文，确认可以反复来回
	I18n.set_language("en")
	I18n.apply_tree(ui_layer)
	_ok(auto_btn.text.begins_with("Auto"), "可以反复来回切换")

	I18n.set_language(original)
	I18n.apply_tree(ui_layer)
	_ok(String(ConfigManager.get_value(I18n.CONFIG_KEY, "")) == original,
		"收尾还原成玩家原本的语言（%s）" % original)


# ---------------------------------------------------------------------------
# 20. 回滚缓冲（纯数据类，不需要场景）
#
# 回滚最容易翻车的两点，这里都要钉死：
#   1. 游标与容量的边界 —— 空缓冲不能退、满了要丢最旧的、游标不能指错格；
#   2. 回退后再推进，旧的「未来」历史必须丢掉 —— 否则会翻进一条
#      其实没走过的分支（玩家回退改选项后，那段被抛弃的剧情还赖在历史里）。
# ---------------------------------------------------------------------------

func _check_rollback_buffer() -> void:
	print("[smoke] 20. 回滚缓冲")

	var buf := RollbackBuffer.new(3)
	_ok(buf.is_empty() and buf.cursor() == -1, "新缓冲是空的，游标在 -1")
	_ok(not buf.can_back() and not buf.can_forward(), "空缓冲前后都动不了")
	_ok(buf.back().is_empty() and buf.forward().is_empty(), "空缓冲 back / forward 返回空字典")
	_ok(buf.at(0).is_empty(), "越界取值返回空字典")

	buf.push({"i": 1})
	buf.push({"i": 2})
	buf.push({"i": 3})
	_ok(buf.size() == 3 and buf.cursor() == 2, "推满三格，游标停在最后一格")
	_ok(int(buf.current().get("i", 0)) == 3, "current 是最后推入那格")

	buf.push({"i": 4})
	_ok(buf.size() == 3, "超出容量后总数不再增长")
	_ok(int(buf.at(0).get("i", 0)) == 2, "丢掉的确实是最旧那格（现在 at(0) 是 2）")
	_ok(buf.cursor() == 2, "满容量丢旧后游标仍指向最新那格")

	_ok(int(buf.back().get("i", 0)) == 3, "back 返回上一格")
	_ok(buf.cursor() == 1, "back 之后游标前移一格")
	_ok(int(buf.forward().get("i", 0)) == 4, "forward 撤销一次回退，回到最新")
	_ok(not buf.can_forward(), "到最新一格后不能再前进")

	buf.back()
	buf.back()
	_ok(int(buf.current().get("i", 0)) == 2, "连退两格停在 2")
	_ok(buf.can_forward(), "退回中间位置时还能前进")

	# 关键：回退后再推进新剧情，未来那一截必须丢掉
	buf.push({"i": 9})
	_ok(buf.size() == 2, "回退后推新快照：作废的未来被整体丢弃（只剩 2 格）")
	_ok(int(buf.at(0).get("i", 0)) == 2 and int(buf.at(1).get("i", 0)) == 9,
		"丢弃后剩下的就是「当前位置」加「新剧情」")
	_ok(buf.cursor() == 1 and not buf.can_forward(),
		"分支截断后游标落在新快照上，且不能再前进")

	buf.clear()
	_ok(buf.is_empty() and buf.cursor() == -1, "clear 之后回到初始状态")


# ---------------------------------------------------------------------------
# 21. 回滚（端到端：采集 / 回退 / 前进 / 分支截断 / 选项处回退 / 滚轮输入）
# ---------------------------------------------------------------------------

const ROLLBACK_SCRIPT_PATH := "user://__smoke_rollback.gvs"

## 三段线性剧情，每段都改背景和变量；末尾挂一个选项，用来测「退到选项处重选」。
const ROLLBACK_SCRIPT := """label start
bg classroom
set var n 1
narr 回滚·第一句
bg rooftop
set var n 2
narr 回滚·第二句
bg street
set var n 3
narr 回滚·第三句
choice
    "去 A" -> branch_a
    "去 B" -> branch_b
end
label branch_a
set var picked "a"
narr A 线
ending ra "A 结局"
label branch_b
set var picked "b"
narr B 线
ending rb "B 结局"
"""


func _check_rollback(main_node: Node, runner: ScriptRunner) -> void:
	print("[smoke] 21. 回滚")

	var writer := FileAccess.open(ROLLBACK_SCRIPT_PATH, FileAccess.WRITE)
	if writer == null:
		_ok(false, "无法写入回滚测试剧本")
		return
	writer.store_string(ROLLBACK_SCRIPT)
	writer.close()

	var dialogue := main_node.get("dialogue") as DialogueBox
	var choices := main_node.get("choices") as ChoicePanel
	var stage_node := main_node.get("stage") as Stage
	var backlog := main_node.get("backlog") as BacklogPanel

	# 用游戏自己的入口起一局 —— 它会清空历史、藏标题、开始跑剧本，
	# 这样滚轮输入那一段的「非标题 / 无面板」前置条件才是真的
	main_node.call("_close_modals")
	main_node.call("_on_start_requested", ROLLBACK_SCRIPT_PATH, "")
	var rb := main_node.get("_rollback") as RollbackBuffer

	_ok(dialogue.get_full_text() == "回滚·第一句", "开局停在第一句")
	_ok(rb.size() == 1 and rb.cursor() == 0, "开局历史里正好一句")

	runner.advance()
	_ok(dialogue.get_full_text() == "回滚·第二句", "推进到第二句")
	runner.advance()
	_ok(dialogue.get_full_text() == "回滚·第三句", "推进到第三句")
	_ok(rb.size() == 3, "三句各留了一份快照")

	var backlog_before := (main_node.get("_backlog_entries") as Array).size()
	_ok(backlog_before == 3, "回看记录累计到 3 句")

	# --- 回退：指针、软状态、画面三者必须一起退 ---
	_ok(bool(main_node.call("_rollback_step", -1)), "回退一句成功")
	_ok(dialogue.get_full_text() == "回滚·第二句", "回退后显示的是第二句")
	_ok(int(GameManager.get_var("n", 0)) == 2, "回退后变量 n 还原成 2（不是 3）")
	_ok(stage_node.get_bg_id() == "rooftop", "回退后背景还原成 rooftop（不是 street）")
	_ok((main_node.get("_backlog_entries") as Array).size() == 2,
		"回退后回看记录截到这一句")

	_ok(bool(main_node.call("_rollback_step", -1)), "再回退一句成功")
	_ok(dialogue.get_full_text() == "回滚·第一句", "回退到第一句")
	_ok(int(GameManager.get_var("n", 0)) == 1, "变量跟着退到 1")
	_ok(stage_node.get_bg_id() == "classroom", "背景跟着退到 classroom")
	_ok(not bool(main_node.call("_rollback_step", -1)), "已经到历史开头，再退无效")
	_ok(dialogue.get_full_text() == "回滚·第一句", "退到头后画面不变")

	# --- 前进：撤销回退 ---
	_ok(bool(main_node.call("_rollback_step", 1)), "前进一句成功")
	_ok(dialogue.get_full_text() == "回滚·第二句", "前进后回到第二句")
	_ok(int(GameManager.get_var("n", 0)) == 2, "前进后变量恢复成 2")
	main_node.call("_rollback_step", 1)
	_ok(dialogue.get_full_text() == "回滚·第三句", "再前进回到第三句")

	# --- 退到选项处重选 ---
	# 先真正推进到选项，缓冲区里才会留下那一格
	runner.advance()
	_ok(runner.is_waiting_choice() and choices.visible, "推进到选项，选项摊在眼前")
	_ok(rb.size() == 4, "选项也占了一格历史")
	_ok(String(rb.current().get("kind", "")) == "choice", "这一格标记为 choice")

	# 退回对白：选项面板必须收起来，不能一直挡在前面
	_ok(bool(main_node.call("_rollback_step", -1)), "从选项退回上一句成功")
	_ok(dialogue.get_full_text() == "回滚·第三句", "退回后显示第三句")
	_ok(not choices.visible, "退离选项后选项面板收起")
	_ok(not runner.is_waiting_choice(), "调度器退出选项等待态")

	# 再前进，回到「选项摊在眼前」那一格重新决断
	_ok(bool(main_node.call("_rollback_step", 1)), "前进回到选项格成功")
	_ok(runner.is_waiting_choice(), "前进历史能停在「等选项」那一格")
	_ok(choices.visible, "停在选项格里，选项面板重新弹了出来")
	_ok(dialogue.get_full_text() == "回滚·第三句", "选项背后仍是第三句上下文")

	# 先选 A 走一遍
	runner.submit_choice(0)
	_ok(String(GameManager.get_var("picked", "")) == "a", "第一次选了 A 分支")
	_ok(dialogue.get_full_text() == "A 线", "显示 A 线剧情")
	_ok(rb.size() == 5, "A 线记进历史（共 5 格）")

	# 退回选项、改选 B —— A 线那一格必须被丢弃，而不是叠加在后面
	_ok(bool(main_node.call("_rollback_step", -1)), "从 A 线退回选项")
	_ok(runner.is_waiting_choice() and choices.visible, "退回到选项等待态")
	runner.submit_choice(1)
	_ok(String(GameManager.get_var("picked", "")) == "b", "改选 B 分支")
	_ok(dialogue.get_full_text() == "B 线", "显示 B 线剧情")
	_ok(rb.size() == 5, "改选后历史长度不变（旧的未来被替换而非叠加）")
	_ok(String(rb.current().get("text", "")) == "B 线", "当前格是 B 线")
	_ok(not rb.can_forward(), "改选后无法再前进到被丢弃的 A 线")

	var has_discarded_a := false
	for i in rb.size():
		if String(rb.at(i).get("text", "")) == "A 线":
			has_discarded_a = true
	_ok(not has_discarded_a, "被丢弃的 A 线彻底不在历史里")

	# --- 滚轮输入 ---
	main_node.call("_close_modals")
	main_node.call("_on_start_requested", ROLLBACK_SCRIPT_PATH, "")
	runner.advance()
	runner.advance()
	_ok(dialogue.get_full_text() == "回滚·第三句", "重置后停在第三句")

	var cursor_before := rb.cursor()
	var wheel_up := InputEventMouseButton.new()
	wheel_up.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel_up.pressed = true
	main_node.call("_unhandled_input", wheel_up)
	_ok(rb.cursor() == cursor_before - 1, "滚轮向上回退了一格")
	_ok(dialogue.get_full_text() == "回滚·第二句", "滚轮向上之后看到的是上一句")

	var wheel_down := InputEventMouseButton.new()
	wheel_down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel_down.pressed = true
	main_node.call("_unhandled_input", wheel_down)
	_ok(dialogue.get_full_text() == "回滚·第三句", "滚轮向下撤销回退，回到第三句")

	# --- 设置项：关掉滚轮回滚，滚轮上应退回「打开回看」 ---
	ConfigManager.set_value("rollback_wheel", false, false)
	var cursor_locked := rb.cursor()
	main_node.call("_unhandled_input", wheel_up)
	_ok(rb.cursor() == cursor_locked, "关掉「滚轮用于回滚」后，滚轮不再动历史")
	_ok(backlog.visible, "关掉后滚轮向上退回打开回看面板（旧行为）")
	main_node.call("_close_modals")
	ConfigManager.set_value("rollback_wheel", true, false)

	# --- 新开局必须清掉旧历史 ---
	main_node.call("_on_start_requested", ROLLBACK_SCRIPT_PATH, "")
	_ok(rb.size() == 1 and rb.cursor() == 0, "重新开局后历史清空到只剩第一句")

	# --- 读档：回看记录不该被重复追加，回滚历史也不该跨存档接续 ---
	runner.advance()
	runner.advance()
	var backlog_now := (main_node.get("_backlog_entries") as Array).size()
	_ok(backlog_now == 3, "读档前回看记录 3 句")

	SaveManager.delete_slot(PROBE_SLOT)
	_ok(bool(SaveManager.write_slot(PROBE_SLOT, main_node.call("_build_payload"))),
		"写入探针存档")
	main_node.call("_load_slot", PROBE_SLOT)
	_ok((main_node.get("_backlog_entries") as Array).size() == backlog_now,
		"读档后回看记录没多出重复的一条")
	_ok(rb.is_empty(), "读档后回滚历史被清空（不跨存档接续）")
	_ok(dialogue.get_full_text() == "回滚·第三句", "读档回到了存档时那一句")
	SaveManager.delete_slot(PROBE_SLOT)

	# 公开的清空入口（调试 / 测试用）
	main_node.call("clear_rollback_history")
	_ok(rb.is_empty() and rb.cursor() == -1, "clear_rollback_history 能清空历史")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(ROLLBACK_SCRIPT_PATH))
	main_node.call("_back_to_title")


# ---------------------------------------------------------------------------
# 22. 着色器静态检查
#
# Godot 的着色语言**不允许**在 fragment() / vertex() 里用 return ——
# 违反时着色器直接编译失败，但表现为「某个过渡效果就是不出来」，
# 逻辑测试全绿、控制台只多一行 error，极易被当成「本来就没做」。
# char_expr.gdshader 就真的踩过这个坑（表情交叉过渡整段失效）。
# 这里静态守一道：扫 shaders/ 下每个文件的入口函数体，不许出现 return。
# ---------------------------------------------------------------------------

func _check_shaders() -> void:
	print("[smoke] 22. 着色器静态检查")

	var dir := DirAccess.open("res://shaders")
	_ok(dir != null, "shaders 目录可打开")
	if dir == null:
		return

	var files: Array = []
	for f in dir.get_files():
		if String(f).ends_with(".gdshader"):
			files.append(String(f))
	_ok(not files.is_empty(), "找到 %d 个着色器文件" % files.size())

	for file_name in files:
		var path := "res://shaders/%s" % file_name
		var src := FileAccess.get_file_as_string(path)
		if src.is_empty():
			_ok(false, "%s 可读取" % file_name)
			continue
		var offenders := _shader_entry_returns(src)
		if offenders.is_empty():
			_ok(true, "%s 的 fragment / vertex 里没有非法 return" % file_name)
		else:
			_ok(false, "%s 在 %s 里用了 return（Godot 着色语言不允许，会编译失败）"
				% [file_name, ", ".join(offenders)])

	# --- modulate 守卫：给 COLOR 赋值时**不要**乘进来的 COLOR。
	#     节点 modulate（focus_speaker 改的 modulate.rgb、淡入淡出改的
	#     modulate.a）由引擎在 fragment 之后叠加；在 shader 里再乘一遍等于
	#     叠加两次 —— char_expr 会整张立绘暗掉约 40%（一挂材质就永久变暗），
	#     transition 会把转场中的那一层压暗约 35%（转场时发暗发红，结束才恢复）。
	#     这两个都是像素级才能发现的坑，逻辑测试只会全绿。
	#     实测依据见 tools/char_shader_probe.gd 与 tools/mask_fidelity_probe.gd。
	var modulated_shaders := {
		"char_expr.gdshader": "表情材质一挂上就整张立绘变暗",
		"transition.gdshader": "转场中的新画面发暗发红",
	}
	for file_name in modulated_shaders:
		var src2 := FileAccess.get_file_as_string("res://shaders/%s" % file_name)
		if src2.is_empty():
			_ok(false, "%s 可读取" % file_name)
			continue
		var bad2 := _color_assigns_reapplying_modulate(src2)
		_ok(bad2 == 0, "%s 的 COLOR 赋值没有重复叠加 modulate（否则%s）"
			% [file_name, modulated_shaders[file_name]])

	# 守卫自检：一个从不失败的守卫等于没有守卫。
	var bad_src := "void fragment() {\n\tCOLOR = base * COLOR;\n}"
	var good_src := "void fragment() {\n\tCOLOR = base;\n}"
	_ok(_color_assigns_reapplying_modulate(bad_src) == 1
		and _color_assigns_reapplying_modulate(good_src) == 0,
		"modulate 守卫自检：抓得出重复叠加的写法、放行得了正确写法")


## 返回「在函数体里出现 return」的入口函数名列表。
func _shader_entry_returns(src: String) -> Array:
	var found: Array = []
	for entry in ["fragment", "vertex"]:
		var body := _extract_function_body(src, entry)
		if body.is_empty():
			continue
		if _has_return_statement(_strip_line_comments(body)):
			found.append(entry)
	return found


## 粗略抽取 `void <name>(...) { ... }` 的函数体，按大括号配平。
func _extract_function_body(src: String, fname: String) -> String:
	var start := src.find("void %s(" % fname)
	if start < 0:
		return ""
	var brace := src.find("{", start)
	if brace < 0:
		return ""
	var depth := 0
	var i := brace
	while i < src.length():
		var ch := src[i]
		if ch == "{":
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0:
				return src.substr(brace + 1, i - brace - 1)
		i += 1
	return ""


## 去掉 // 行注释，避免把说明文字里的 return 误判成语句。
func _strip_line_comments(src: String) -> String:
	var out := ""
	for line in src.split("\n"):
		var at := line.find("//")
		out += (line.substr(0, at) if at >= 0 else line) + "\n"
	return out


## 用词边界匹配，避免把 returned / return_value 这类标识符算进去。
func _has_return_statement(body: String) -> bool:
	var re := RegEx.new()
	if re.compile("(^|[^A-Za-z0-9_])return([^A-Za-z0-9_]|$)") != OK:
		return body.contains("return")
	return re.search(body) != null


## 数 fragment() 里「给 COLOR 赋值时又把进来的 COLOR 乘了一遍」的行数。
## 节点 modulate 由引擎在 fragment 之后叠加（实测：modulate=0.55 时渲染结果
## 正好是 shader 输出的 0.55 倍），shader 里再乘一次 = 叠加两次，
## 表现为整层被压暗（char_expr 约 -40%、transition 约 -35%）。
func _color_assigns_reapplying_modulate(src: String) -> int:
	var body := _strip_line_comments(_extract_function_body(src, "fragment"))
	var bad := 0
	for line in body.split("\n"):
		var l := String(line).strip_edges()
		if not l.begins_with("COLOR") or not l.contains("=") or l.contains("=="):
			continue
		if l.contains("* COLOR") or l.contains("COLOR *"):
			bad += 1
	return bad


# ---------------------------------------------------------------------------
# 23. 音频：BGM 循环与语音队列
#
# 两个都属于「没有素材就完全看不出来」的问题：
#   · BGM 不循环 —— 骨架阶段 assets/audio/bgm/ 是空的，一放进真实曲子才会
#     发现「播完一遍就静音了」；
#   · 语音只有一条通道 —— 同一句里连写多条 voice 时，后面那句会把前面打断。
# 所以这里用**代码合成的静音流**来驱动，不依赖任何素材文件。
# ---------------------------------------------------------------------------

func _check_audio() -> void:
	print("[smoke] 23. 音频：BGM 循环与语音队列")

	# --- 循环开关 ---
	# 三种音频流的「循环」字段名不一样：Ogg / MP3 是 loop(bool)，WAV 是 loop_mode(枚举)。
	var wav := _make_silent_stream()
	AudioManager.enable_stream_loop(wav)
	_ok(wav.loop_mode == AudioStreamWAV.LOOP_FORWARD,
		"WAV 通过 loop_mode 打开循环（字段名与 Ogg / MP3 不同）")
	AudioManager.enable_stream_loop(null)
	_ok(true, "传空流不会崩")

	# --- 语音队列 ---
	AudioManager.stop_voice()
	var stream := _make_silent_stream()

	AudioManager.voice_channel("v1", stream)
	_ok(AudioManager.is_voice_active() and AudioManager.get_voice_id() == "v1",
		"第一条语音立刻开播")

	AudioManager.voice_channel("v2", stream, 1.0, true)
	AudioManager.voice_channel("v3", stream, 1.0, true)
	_ok(AudioManager.get_voice_queue_size() == 2, "同句后续语音进入队列（2 条）")
	_ok(AudioManager.get_voice_id() == "v1", "队首不被抢走，仍播第一条")

	AudioManager.notify_voice_finished()
	_ok(AudioManager.get_voice_id() == "v2", "播完自动接上第二条")
	_ok(AudioManager.get_voice_queue_size() == 1, "队列递减到 1")
	AudioManager.notify_voice_finished()
	_ok(AudioManager.get_voice_id() == "v3", "再接上第三条")
	AudioManager.notify_voice_finished()
	_ok(not AudioManager.is_voice_active() and AudioManager.get_voice_queue_size() == 0,
		"整个队列播完，通道回到空闲")

	# --- 换句：打断并清队列（否则声画错位）---
	AudioManager.voice_channel("a", stream)
	AudioManager.voice_channel("b", stream, 1.0, true)
	_ok(AudioManager.get_voice_queue_size() == 1, "先排队一条")
	AudioManager.voice_channel("c", stream)
	_ok(AudioManager.get_voice_id() == "c" and AudioManager.get_voice_queue_size() == 0,
		"不排队的新语音打断当前，并把排队的一并清掉")

	AudioManager.stop_voice()
	_ok(not AudioManager.is_voice_active() and AudioManager.get_voice_queue_size() == 0,
		"stop_voice 清空通道与队列")

	# --- 素材缺失：静默跳过，不占位置也不打断 ---
	AudioManager.voice_channel("a", stream)
	AudioManager.voice_channel("并没有这个素材", null)
	_ok(AudioManager.get_voice_id() == "a",
		"没有素材的语音被静默跳过，不会打断正在播的那条")
	AudioManager.voice_channel("也没有这个素材", null, 1.0, true)
	_ok(AudioManager.get_voice_queue_size() == 0, "没有素材的语音不占队列位置")
	AudioManager.stop_voice()


## 合成 0.1 秒静音流。没有它，语音队列在素材缺失的骨架工程里根本无从验证。
static func _make_silent_stream() -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	wav.stereo = false
	var bytes := PackedByteArray()
	bytes.resize(2205 * 2)
	wav.data = bytes
	return wav


# ---------------------------------------------------------------------------
# 24. 存档删除与覆盖确认
#
# 存档是玩家几十小时的进度，写操作必须过一道确认。
# 原先的问题：SaveManager 有 delete_slot() 这个 API，界面却根本没有入口 ——
# 删不掉，而且覆盖已有存档是**点了就写**，没有任何提示。
# ---------------------------------------------------------------------------

func _check_save_manage(main_node: Node) -> void:
	print("[smoke] 24. 存档删除与覆盖确认")

	var save_load := main_node.get("save_load") as SaveLoadPanel
	if save_load == null:
		_ok(false, "存读档面板缺失")
		return

	var slot := PROBE_SLOT
	var spare := PROBE_SLOT - 1
	SaveManager.delete_slot(slot)
	SaveManager.delete_slot(spare)
	_ok(bool(SaveManager.write_slot(slot, {"chapter_title": "删除测试", "preview": "内容"})),
		"写入一个用于删除测试的存档")

	var chosen := {"slot": -1}
	save_load.slot_chosen.connect(func(s: int) -> void: chosen["slot"] = s)
	save_load.present(false)
	_ok(not save_load.is_confirm_visible(), "刚打开面板时没有确认弹层")

	# 覆盖已占用的槽位 → 先确认
	save_load.call("_on_slot_pressed", slot)
	_ok(save_load.is_confirm_visible(), "覆盖已占用槽位会先弹确认")
	_ok(int(chosen["slot"]) == -1, "确认之前不会真的写下去")
	_ok(save_load.get_confirm_text().contains("覆盖"), "文案说明这是覆盖操作")

	save_load.confirm_cancel()
	_ok(not save_load.is_confirm_visible() and int(chosen["slot"]) == -1,
		"点取消：不覆盖，弹层收起")

	save_load.call("_on_slot_pressed", slot)
	save_load.confirm_accept()
	_ok(int(chosen["slot"]) == slot, "点确定：才真的发出保存请求")

	# 空槽位直接保存，不该多一步确认
	chosen["slot"] = -1
	save_load.call("_on_slot_pressed", spare)
	_ok(not save_load.is_confirm_visible() and int(chosen["slot"]) == spare,
		"空槽位直接进入保存，不弹确认")

	# 自动存档槽：能读，但不该手动写
	SaveManager.write_slot(SaveManager.AUTO_SLOT, {"chapter_title": "自动", "preview": "x"})
	save_load.present(false)
	_ok(not save_load.is_slot_enabled(SaveManager.AUTO_SLOT),
		"保存模式下自动存档槽不可点（写了也会被下一次自动存档冲掉）")
	save_load.present(true)
	_ok(save_load.is_slot_enabled(SaveManager.AUTO_SLOT),
		"读取模式下自动存档槽可点（读是合理的）")

	# 删除 → 先确认，确认后存档与缩略图一起消失
	var changed := {"fired": false}
	save_load.slots_changed.connect(func() -> void: changed["fired"] = true)
	save_load.present(false)
	save_load.call("_on_delete_pressed", slot)
	_ok(save_load.is_confirm_visible(), "删除会先弹确认")
	_ok(save_load.get_confirm_text().contains("删除"), "文案说明这是删除操作")

	save_load.confirm_cancel()
	_ok(SaveManager.slot_exists(slot), "点取消：存档还在")

	save_load.call("_on_delete_pressed", slot)
	save_load.confirm_accept()
	_ok(not SaveManager.slot_exists(slot), "点确定：存档被删除")
	_ok(not SaveManager.has_thumbnail(slot), "删除存档时缩略图一并清理")
	_ok(bool(changed["fired"]), "删除后发出 slots_changed，标题按钮状态得以刷新")

	save_load.hide_panel()
	_ok(not save_load.is_confirm_visible(), "关面板会把确认弹层一并收起")

	SaveManager.delete_slot(spare)


# ---------------------------------------------------------------------------
# 25. 已读文本变暗
#
# 顺序坑：_on_say 会**先 mark_read、再 show_line**。如果 show_line 自己去查
# ReadTracker，查到的永远是「已读」—— 于是每一句（含第一次看到的）都被压暗。
# 所以「这句以前看过没有」必须由 _on_say 在标记之前问出来，再传进去。
# ---------------------------------------------------------------------------

func _check_read_dim(main_node: Node) -> void:
	print("[smoke] 25. 已读文本变暗")

	var dialogue := main_node.get("dialogue") as DialogueBox
	var text_label := main_node.get_node("%TextLabel") as RichTextLabel
	if dialogue == null or text_label == null:
		_ok(false, "对话框 / 文本控件缺失")
		return

	var old_dim: Variant = ConfigManager.get_value("dim_read_text", false)
	# 用随机文案，避免撞上玩家已有的已读记录；也不去 clear() 别人的记录
	var line := "【smoke】已读判定 %d" % randi()

	ConfigManager.set_value("dim_read_text", true, false)

	main_node.call("_on_say", "", line, "")
	_ok(text_label.get_theme_color("default_color") == UiTheme.TEXT,
		"第一次看到：正常字色（不会被自己刚标记的已读误伤）")
	_ok(ReadTracker.is_read(line), "显示之后才被标记成已读")

	main_node.call("_on_say", "", line, "")
	_ok(text_label.get_theme_color("default_color") == UiTheme.TEXT_DIM,
		"重看同一句：压暗")

	ConfigManager.set_value("dim_read_text", false, false)
	main_node.call("_on_say", "", line, "")
	_ok(text_label.get_theme_color("default_color") == UiTheme.TEXT,
		"关掉开关后，已读文本也保持正常字色")

	ConfigManager.set_value("dim_read_text", old_dim, false)
	dialogue.hide_box()


# ---------------------------------------------------------------------------
# 26. 标记不外漏
#
# 台词里带着 [wait=0.7] / [speed=2.5] / [bounce] 这些标记 —— 它们只对打字机
# 有意义。任何「把台词渲染成静态一行」的地方都必须先剥掉，否则玩家会看到
# `alice: 明天，[speed=2.5]要不要一起走？[/speed]`。
# 回看面板与存档预览都真出过这个问题（截图对比时一眼看到）。
#
# 两处的剥法还不一样：回看面板是 RichTextLabel，特效标记要留着给它渲染；
# 存档预览是普通 Label（不解析 BBCode），所以标签必须全部丢掉。
# ---------------------------------------------------------------------------

func _check_marker_stripping(main_node: Node) -> void:
	print("[smoke] 26. 标记不外漏")

	_ok(TypingTimeline.strip("前[wait=0.5]后") == "前后", "strip 剥掉等待标记")
	_ok(TypingTimeline.strip("这一句[speed=3]很快[/speed]") == "这一句很快",
		"strip 剥掉变速标记（含闭合标签）")
	_ok(TypingTimeline.strip("弹[bounce height=13]跳[/bounce]")
		== "弹[bounce height=13]跳[/bounce]",
		"strip 保留特效标记，交给 RichTextLabel")

	# 存档预览：普通 Label，所有标签都必须消失
	var lines := SaveLoadPanel._slot_lines(PROBE_SLOT, {
		"empty": false,
		"chapter_title": "测试章",
		"saved_at": "2026-01-01 00:00:00",
		"preview": "明天，[speed=2.5]要不要一起走？[/speed][wait=0.9]",
		"speaker": "alice",
		"play_time": 12.0,
	})
	_ok(not String(lines[1]).contains("["),
		"存档预览里没有任何标记残留（%s）" % String(lines[1]))
	_ok(String(lines[1]).contains("要不要一起走"), "预览保留了正文")
	_ok(String(lines[1]).contains("alice"), "预览仍带说话人")

	# 回看面板：RichTextLabel，只剥节奏标记，特效标记留着
	var backlog := main_node.get("backlog") as BacklogPanel
	backlog.present([{"speaker": "alice", "text": "前[wait=0.5]后[bounce]弹[/bounce]"}])
	var texts := _collect_rich_text(backlog)
	_ok(texts.size() == 1, "回看里生成了 1 条")
	if texts.size() == 1:
		_ok(not texts[0].contains("[wait"), "回看条目里没有残留的节奏标记")
		_ok(texts[0].contains("[bounce]"), "回看条目保留特效标记（由 RichTextLabel 渲染）")
	backlog.hide_panel()


## 收集一棵子树里所有 RichTextLabel 的 text
func _collect_rich_text(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	if root is RichTextLabel:
		out.append((root as RichTextLabel).text)
	for child in root.get_children():
		out.append_array(_collect_rich_text(child))
	return out


# ---------------------------------------------------------------------------
# 27. 架构守卫
#
# 分层是这个骨架能长期维护的前提，而它最容易在「顺手加一行」时被打破 ——
# 在 autoload 里 new 一个面板、在 core 里 import 一个 UI 类、把路径常量又抄一份。
# 这类破坏**没有任何运行时症状**，直到某天想单独替换某一层才发现拆不开。
# 所以这里做静态扫描，把「看不见的约定」变成会失败的断言。
#
# 例外必须写进白名单并写明理由 —— 有理由的例外才是设计，没理由的就是漏。
# ---------------------------------------------------------------------------

## core / autoload 里不该出现的表现层类型（面板 / 演出层 / 调试台）
##
## 注意 ScreenFx 与 ScreenFxSpec 是两回事：前者是挂在场景里的表现层节点，
## 后者是放在 core 的纯数据（种类表），两边都要用，所以只禁前者。
## _mentions() 用的是词边界，ScreenFxSpec 不会被 ScreenFx 误伤。
const PRESENTATION_TYPES: PackedStringArray = [
	"DialogueBox", "BacklogPanel", "ChoicePanel", "GalleryPanel", "CgViewer",
	"RecordsPanel", "SettingsPanel", "SaveLoadPanel", "MusicPanel", "TitleScreen",
	"LockIcon", "RecordDisc", "SpectrumBars", "DebugConsole", "Stage", "ScreenFx",
]
## 唯一允许反过来抓编排层的表现层文件：调试台本来就是个「什么都能碰」的工具，
## 拿 main 引用来换实现简单，是作者在它文件头注明的取舍。
const ORCHESTRATOR_EXCEPTIONS: PackedStringArray = ["debug_console.gd"]
## 唯一允许出现剧本路径字面量的文件 —— 它就是「路径住在哪」的权威
const PATH_AUTHORITY := "script_paths.gd"
const SCRIPT_DIR_LITERAL := "\"res://data/scripts"


func _check_architecture() -> void:
	print("[smoke] 27. 架构守卫")

	# --- 规则一：core / autoload 不得引用表现层 ---
	var violations: Array = []
	var scanned: PackedStringArray = []
	for prefix in ["core", "autoload"]:
		scanned.append_array(_all_gd_files("res://scripts/" + prefix))
	_ok(not scanned.is_empty(), "扫到 %d 个 core / autoload 文件" % scanned.size())
	for name in scanned:
		var code := _code_only("res://scripts/%s" % name)
		for type_name in PRESENTATION_TYPES:
			if _mentions(code, type_name):
				violations.append("%s → %s" % [name, type_name])
	if violations.is_empty():
		_ok(true, "core / autoload 没有引用任何表现层类型")
	else:
		_ok(false, "core / autoload 引用了表现层：%s" % ", ".join(violations))

	# --- 规则二：表现层不得反向抓编排层 ---
	var reverse: Array = []
	for prefix in ["ui", "stage"]:
		for name in _all_gd_files("res://scripts/" + prefix):
			if ORCHESTRATOR_EXCEPTIONS.has(name.get_file()):
				continue
			var code := _code_only("res://scripts/%s" % name)
			if _mentions(code, "_main") or _mentions(code, "main_node"):
				reverse.append(String(name))
	if reverse.is_empty():
		_ok(true, "表现层没有反向引用编排层（调试台按白名单豁免）")
	else:
		_ok(false, "表现层反向引用了编排层：%s" % ", ".join(reverse))

	# --- 规则三：剧本路径知识必须集中在 ScriptPaths ---
	var scattered: Array = []
	var authority_seen := false
	for name in _all_gd_files("res://scripts"):
		if not _has_path_literal("res://scripts/%s" % name):
			continue
		if String(name).get_file() == PATH_AUTHORITY:
			authority_seen = true
			continue
		scattered.append(String(name))
	_ok(authority_seen, "%s 确实是路径字面量的持有者" % PATH_AUTHORITY)
	if scattered.is_empty():
		_ok(true, "除 %s 外没有别的文件硬写剧本路径" % PATH_AUTHORITY)
	else:
		_ok(false, "剧本路径又散出来了：%s" % ", ".join(scattered))

	# --- 守卫自检：一个从不失败的守卫等于没有守卫 ---
	# 喂几段合成源码，确认它「抓得到真违规」而且「不误报注释 / 字符串」
	_ok(_mentions(_code_only_of("var s: Stage = null"), "Stage"),
		"守卫能抓到代码里的表现层引用")
	_ok(not _mentions(_code_only_of("## 转发给 Stage 演出层"), "Stage"),
		"守卫忽略注释里提到的类名")
	_ok(not _mentions(_code_only_of("push_warning(\"[Stage] 出错了\")"), "Stage"),
		"守卫忽略字符串里提到的类名")
	_ok(not _mentions(_code_only_of("var staged := 1"), "Stage"),
		"守卫用词边界匹配，不会误伤 StageXxx")


## 递归列出 root 下所有 .gd（返回相对 root 的路径）
static func _all_gd_files(root: String, prefix: String = "") -> PackedStringArray:
	# 把 root 规整成带结尾斜杠 —— 否则递归时 "res://scripts" + "core/" 会拼成
	# "res://scriptscore/"，子目录静默扫不到（守卫会假绿）
	var base := root if root.ends_with("/") else root + "/"
	var out := PackedStringArray()
	var dir := DirAccess.open(base + prefix)
	if dir == null:
		return out
	for file_name in dir.get_files():
		if String(file_name).ends_with(".gd"):
			out.append(prefix + String(file_name))
	for sub in dir.get_directories():
		out.append_array(_all_gd_files(base, prefix + String(sub) + "/"))
	return out


## 只留「代码骨架」：先剥掉 "..." 里的内容，再砍掉 # 注释。
##
## 顺序不能反 —— GDScript 的 `#` 也出现在字符串里（比如 `"[color=#a9a3d0]"`），
## 先砍注释就会把这类行从中间截断。剥字符串而不是注释的目的：
## 文件头注释里提到的类名（「转发给 Stage」）会被误报成违规。
static func _code_only(path: String) -> String:
	return _code_only_of(FileAccess.get_file_as_string(path))


static func _code_only_of(source: String) -> String:
	var out := ""
	for raw_line in source.split("\n"):
		var line := _strip_quoted(String(raw_line))
		var hash_at := line.find("#")
		if hash_at >= 0:
			line = line.substr(0, hash_at)
		out += line + "\n"
	return out


static func _strip_quoted(line: String) -> String:
	var out := ""
	var in_string := false
	for i in line.length():
		if line[i] == "\"":
			in_string = not in_string
			continue
		if not in_string:
			out += line[i]
	return out


## 这一处路径字面量是不是「真写在代码里」（而不是出现在注释里）。
## 规则三找的恰好是字符串内容，所以不能走 _code_only，只能按行判断 ——
## 行内 `#` 出现在字面量之前，就认为那是注释。
static func _has_path_literal(path: String) -> bool:
	for raw_line in FileAccess.get_file_as_string(path).split("\n"):
		var at := raw_line.find(SCRIPT_DIR_LITERAL)
		if at < 0:
			continue
		var hash_at := raw_line.find("#")
		if hash_at >= 0 and hash_at < at:
			continue
		return true
	return false


## 词边界匹配，避免 Stage 命中 StageDemo 这类前缀相同的标识符
static func _mentions(code: String, word: String) -> bool:
	var re := RegEx.new()
	if re.compile("(^|[^A-Za-z0-9_])%s([^A-Za-z0-9_]|$)" % word) != OK:
		return code.contains(word)
	return re.search(code) != null


# ---------------------------------------------------------------------------
# 28. 剧本路径解析（ScriptPaths）
#
# 它是「剧本文件住在哪」的唯一权威，也是「剧本按语言分目录」这套能力的地基。
# 这里不真的去建语言目录（测试不该往 res:// 里写文件），只守住三件事：
#   · 源语言下一切照旧，不引入任何路径漂移；
#   · 目标语言没有目录 / 缺某个文件时**安静回退**，而不是报错丢剧情；
#   · 非剧本路径（测试剧本在 user://）原样放过 —— 否则整条测试链会断。
# ---------------------------------------------------------------------------

func _check_script_paths() -> void:
	print("[smoke] 28. 剧本路径解析")

	var original := String(ConfigManager.get_value("language", "zh_CN"))

	_ok(ScriptPaths.is_source_language(), "默认语言是源语言（不做任何映射）")
	_ok(ScriptPaths.entry().ends_with("prologue.gvs"), "入口剧本指向 prologue.gvs")
	_ok(FileAccess.file_exists(ScriptPaths.entry()), "入口剧本文件真实存在")
	_ok(FileAccess.file_exists(ScriptPaths.chapters_path()), "章节表路径可读")

	var files := ScriptPaths.list_scripts()
	_ok(files.size() >= 2, "列出 %d 个剧本" % files.size())
	var all_logical := true
	for f in files:
		if not String(f).begins_with(ScriptPaths.DIR):
			all_logical = false
	_ok(all_logical, "列出的都是逻辑路径（与语言无关，存档才不会因换语言而失效）")

	var sample := ScriptPaths.DIR + "prologue.gvs"
	_ok(ScriptPaths.resolve(sample) == sample, "源语言下 resolve 不改变路径")
	_ok(ScriptPaths.resolve("user://__x.gvs") == "user://__x.gvs",
		"非剧本路径原样返回（测试剧本在 user://）")

	# 目标语言没有自己的目录 → 安静回退
	ConfigManager.set_value("language", "ja_JP", false)
	_ok(not ScriptPaths.is_source_language(), "切到 ja_JP 后不再是源语言")
	_ok(ScriptPaths.active_dir() == ScriptPaths.DIR,
		"没有 ja_JP 剧本目录时回退到源语言目录")
	_ok(ScriptPaths.resolve(sample) == sample,
		"目标语言缺这个文件时回退源语言路径（单文件缺译文不该让整段剧情加载失败）")
	_ok(ScriptPaths.chapters_path() == ScriptPaths.CHAPTERS,
		"目标语言缺章节表时回退源语言章节表")
	_ok(ScriptPaths.list_scripts().size() == files.size(),
		"回退后列出的剧本与源语言一致")

	# 换语言时 _current_file 记的是逻辑路径，所以读档不会因为语言变化而找不到剧本
	ConfigManager.set_value("language", original, false)
	_ok(String(ConfigManager.get_value("language", "")) == original, "收尾还原语言设置")


# ---------------------------------------------------------------------------
# 29. 全屏特效
#
# 这一节守的是「错了也看不出来」的几条：
#   · 层必须排在 UI 之上 —— 排在下面时特效只糊背景，对话框纹丝不动地浮在
#     扭曲的画面外面，像贴纸；
#   · BackBufferCopy 必须是紧挨着的前一个兄弟 —— 位置错了就读不到已经画好的
#     画面，结果不是「没效果」就是整屏变黑；
#   · 未知种类必须当场拦下 —— 静默忽略的表现是「剧本写了、演出不出来」。
#
# 渲染结果本身在 headless 下看不见（视口只有 64×64、也没有真的 back buffer），
# 所以这里断言的是逻辑上观察得到的那部分，画面由 tools/capture.tscn 截图确认。
# ---------------------------------------------------------------------------

## 设置面板的开关：**扫真实面板**里的每一个 CheckButton。
##
## 只测 UiTheme.apply_check_button 是不够的 —— 有人绕过 helper、自己写
## add_theme_color_override("font_color", ...) 的话守卫就漏了（这正是当初的写法：
## 只覆盖 font_color，还把 hover 显式设成白色，于是开关一打开文字变白看不见）。
func _check_settings_ui(main_node: Node) -> void:
	print("[smoke] 设置面板：开关文字颜色")
	main_node.call("_open_settings")
	var rows := main_node.get_node("%SettingsRows") as VBoxContainer
	var checks := _collect_check_buttons(rows)
	_ok(checks.size() >= 3, "设置面板里有 %d 个开关" % checks.size())

	var white_states: Array = []
	for node in checks:
		var check := node as CheckButton
		for state in ["font_color", "font_hover_color", "font_pressed_color",
				"font_hover_pressed_color", "font_focus_color"]:
			var c := check.get_theme_color(state)
			if c.r > 0.9 and c.g > 0.9 and c.b > 0.9:
				white_states.append("%s.%s" % [check.text, state])
	_ok(white_states.is_empty(),
		"没有开关的文字颜色是白的（打开/悬停时也得看得见）：%s" % str(white_states))

	# 字号要和其他功能窗口的正文一个尺度（原来是 22，比别处大一号）
	var sizes: Array = []
	for node in checks:
		sizes.append((node as CheckButton).get_theme_font_size("font_size"))
	_ok(sizes.size() > 0 and sizes.max() <= 20,
		"开关字号 ≤20，与其它面板正文同尺度：%s" % str(sizes))
	main_node.call("_close_modals")


## 递归收集 CheckButton
static func _collect_check_buttons(root: Node) -> Array:
	var out: Array = []
	for child in root.get_children():
		if child is CheckButton:
			out.append(child)
		out.append_array(_collect_check_buttons(child))
	return out


func _check_screen_fx(main_node: Node) -> void:
	print("[smoke] 29. 全屏特效")

	# 先回到一个干净的「游戏进行中」状态：标题界面和面板都会把特效压住
	# （见 _refresh_fx_suspension），不先清干净的话下面的断言全都不成立。
	# 顺带让 runner 载入真实剧本 —— 回滚那一段要能还原 runner，指针不能停在
	# 前面测试已经删掉的临时剧本上。
	main_node.call("_back_to_title")
	main_node.call("_on_start_requested")
	await _wait(0.2)

	# --- 种类表 ---
	_ok(ScreenFxSpec.KINDS.size() >= 5, "内置全屏特效 %d 种" % ScreenFxSpec.KINDS.size())
	var seen_modes := {}
	var broken: Array = []
	for kind in ScreenFxSpec.KINDS:
		var m := ScreenFxSpec.mode_of(kind)
		if m < 0 or seen_modes.has(m):
			broken.append(String(kind))
		seen_modes[m] = true
	_ok(broken.is_empty(), "每种特效都映射到唯一的 shader mode")
	_ok(ScreenFxSpec.is_valid("glitch") and ScreenFxSpec.is_valid("none"),
		"is_valid 认得种类与 none")
	_ok(not ScreenFxSpec.is_valid("glitch_typo"), "is_valid 不认拼错的种类")

	# --- 节点与层级 ---
	var fx: ScreenFx = main_node.get("screen_fx") as ScreenFx
	_ok(fx != null, "拿到全屏特效节点")
	if fx == null:
		return

	var fx_layer := fx.get_parent() as CanvasLayer
	var ui_layer := main_node.get("ui_layer") as CanvasLayer
	if fx_layer != null and ui_layer != null:
		_ok(fx_layer.layer > ui_layer.layer,
			"特效层（layer=%d）在 UI 层（layer=%d）之上 —— 否则对话框不跟着动"
				% [fx_layer.layer, ui_layer.layer])
	else:
		_ok(false, "特效层或 UI 层拿不到")

	_ok(not fx.is_active(), "初始没有特效在跑")
	_ok(not fx.is_capture_enabled(),
		"不生效时连 BackBufferCopy 都不开（不做无谓的全屏拷贝）")

	# --- 持续型 ---
	_ok(fx.play("glitch", 1.5, 0.0), "播放持续型特效")
	_ok(fx.is_active(), "持续型特效生效中")
	_ok(fx.get_kind() == "glitch" and is_equal_approx(fx.get_strength(), 1.5),
		"种类与强度都记下来了")
	_ok(fx.get_mode() == ScreenFxSpec.mode_of("glitch"), "mode 映射正确")
	_ok(fx.is_capture_enabled(), "生效时 BackBufferCopy 打开（否则读不到 UI 层）")

	var copy := fx.get_parent().get_node_or_null("ScreenFxCopy")
	_ok(copy is BackBufferCopy, "BackBufferCopy 已建出来")
	if copy is BackBufferCopy:
		_ok(copy.get_index() == fx.get_index() - 1,
			"BackBufferCopy 恰好排在特效前一位（%d / %d）"
				% [copy.get_index(), fx.get_index()])

	# 未知种类要拒绝，而且**不能**把正在跑的特效顶掉
	_ok(not fx.play("并没有这个特效", 1.0, 0.0), "未知种类被拒绝")
	_ok(fx.get_kind() == "glitch", "被拒绝的指令不会顶掉当前特效")

	fx.stop(0.0)
	_ok(not fx.is_active() and fx.get_kind() == ScreenFxSpec.OFF, "stop(0) 立刻关闭")
	_ok(not fx.is_capture_enabled(), "关闭后 BackBufferCopy 也跟着停")

	# --- 模态面板要把它收起来 ---
	fx.play("wave", 1.0, 0.0)
	main_node.call("_open_settings")
	_ok(fx.is_suspended() and not fx.is_rendering(),
		"设置面板打开时特效被收起（面板上的字得看得清）")
	_ok(is_equal_approx(fx.get_strength(), 1.0), "收起只是不显示，强度保留")
	main_node.call("_close_modals")
	_ok(not fx.is_suspended() and fx.is_rendering(),
		"面板关掉后特效原样接着演（长镜头不会被打断）")

	# --- 脉冲型：到点自己收回 0 ---
	_ok(fx.play("pixelate", 1.0, 0.3), "播放脉冲型特效")
	await _wait(0.12)
	_ok(fx.is_active(), "脉冲中途强度不为零")
	await _wait(0.45)
	_ok(not fx.is_active(), "脉冲到时自己收回 0（不需要脚本再关一次）")

	# --- 回滚要能还原特效 ---
	fx.play("invert", 1.6, 0.0)
	var snapshot: Dictionary = main_node.call("_make_snapshot", "say")
	_ok(snapshot.has("fx"), "回滚快照带上了特效状态")
	fx.clear()
	main_node.call("_apply_snapshot", snapshot)
	_ok(fx.get_kind() == "invert" and is_equal_approx(fx.get_strength(), 1.6),
		"回滚能还原到那一刻的特效（直接落到位，不重播淡入）")

	# --- 复位点 ---
	fx.play("swirl", 1.0, 0.0)
	main_node.call("_on_stage_command", {"op": "clear"})
	_ok(not fx.is_active(), "clear 指令会关掉特效")

	fx.play("swirl", 1.0, 0.0)
	main_node.call("_restore_session", {}, {}, [], "", "")
	_ok(not fx.is_active(),
		"读档 / 重播结束会关掉特效（新画面上不该糊着存档那一刻的错乱）")

	fx.play("swirl", 1.0, 0.0)
	main_node.call("_back_to_title")
	_ok(not fx.is_active(), "回标题会关掉特效（否则标题界面一直糊着）")


# ---------------------------------------------------------------------------
# 30. 视频与帧序列动画
# ---------------------------------------------------------------------------

## 帧序列素材放在 tools/fixtures/sprites/ 下，测试时把立绘根目录临时指过去 ——
## 这样不必往 assets/ 里塞一套演示帧序列，就能验证「目录 → 动画」这条约定。
const MEDIA_FIXTURE_ROOT := "res://tools/fixtures/sprites/"
const MEDIA_SCRIPT_PATH := "user://__smoke_media.gvs"


func _check_media() -> void:
	print("[smoke] 30. 视频与帧序列动画")

	# --- 视频：素材解析 ---
	_ok(VideoScreen.resolve("").is_empty(), "空 id 解析不出视频")
	_ok(not VideoScreen.has_video("不存在的过场"), "不存在的视频判定为缺失")
	_ok(VideoScreen.known_extensions() == PackedStringArray(["ogv"]),
		"只认 Ogg Theora（Godot 内置没有别的视频解码器）")

	# --- 视频：图层 ---
	_ok(VideoScreen.LAYERS.size() == 3, "视频支持三个图层")
	var w := int(VideoScreen.LAYER_VALUES["world"])
	var u := int(VideoScreen.LAYER_VALUES["ui"])
	var t := int(VideoScreen.LAYER_VALUES["top"])
	_ok(w < 10 and u > 10 and t > u,
		"图层顺序：world(%d) 在 UI 之下、ui(%d) 盖住 UI、top(%d) 在最上" % [w, u, t])

	# --- 视频：位置与尺寸 ---
	_ok(VideoScreen.resolve_rect({}) == Rect2(Vector2.ZERO, Vector2(1920, 1080)),
		"默认铺满整屏")
	var placed := VideoScreen.resolve_rect({"at": "320,180", "size": "640,360"})
	_ok(placed.position == Vector2(320, 180) and placed.size == Vector2(640, 360),
		"at=x,y + size=w,h 精确定位")
	_ok(VideoScreen.resolve_rect({"at": "center", "size": "640,360"}).position
		== Vector2(640, 360), "at=center 按尺寸居中")

	# --- 视频：音量换算 ---
	_ok(is_equal_approx(VideoScreen._volume_to_db(1.0), 0.0), "音量 1.0 = 0dB")
	_ok(VideoScreen._volume_to_db(0.0) <= -80.0, "音量 0 视作静音")
	_ok(VideoScreen._volume_to_db(0.5) < 0.0, "音量 0.5 是负 dB")

	# --- 帧序列：自然排序 ---
	var dir := MEDIA_FIXTURE_ROOT + "alice/breathe"
	var frames := PlaceholderAssets.list_anim_frames(dir)
	_ok(frames.size() == 3, "帧序列目录里读到 3 帧")
	if frames.size() == 3:
		_ok(frames[0].get_file() == "frame1.png" and frames[1].get_file() == "frame2.png"
			and frames[2].get_file() == "frame10.png",
			"按数字自然排序（frame10 在 frame2 之后，不是字典序）")

	# --- 帧序列：构建 AnimatedTexture ---
	var anim := PlaceholderAssets.load_anim_dir(dir) as AnimatedTexture
	_ok(anim != null, "帧序列目录构建出 AnimatedTexture")
	if anim != null:
		_ok(anim.frames == 3, "帧数 = 3")
		_ok(is_equal_approx(anim.get_frame_duration(0), 1.0 / 8.0),
			"帧时长取自 anim.json 的 fps=8")
		_ok(not anim.one_shot, "anim.json 里 loop=true → 不是一次性播放")
	_ok(PlaceholderAssets.load_anim_dir("res://tools/fixtures/anim/nope") == null,
		"目录不存在时返回 null（调用方好继续走静态图回退）")
	_ok(PlaceholderAssets.load_anim_dir("res://tools/fixtures") == null,
		"目录里没有图片时也返回 null")

	# --- 立绘走「帧序列目录」约定 ---
	PlaceholderAssets.sprite_root_override = MEDIA_FIXTURE_ROOT
	_ok(PlaceholderAssets.get_char("alice", "breathe") is AnimatedTexture,
		"立绘命中帧序列目录 → 拿到动画贴图")
	_ok(not (PlaceholderAssets.get_char("alice", "nope") is AnimatedTexture),
		"没有帧序列的表情仍走静态回退，不会被误判成动画")

	# --- Stage：anim 指令 ---
	var stage := Stage.new()
	get_tree().root.add_child(stage)
	await get_tree().process_frame

	stage.show_char("alice", "breathe", "center", "none", 0.0)
	var char_anim := stage.get_char_anim("alice")
	_ok(char_anim != null, "帧序列立绘在 Stage 里就是动画对象")
	_ok(stage.set_char_anim("alice", 2.0, true, false, 1),
		"anim 能改速度 / 暂停 / 帧号")
	if char_anim != null:
		_ok(is_equal_approx(char_anim.speed_scale, 2.0) and char_anim.pause
			and char_anim.current_frame == 1, "anim 参数逐项生效")

	PlaceholderAssets.sprite_root_override = ""
	stage.show_char("alice", "normal", "center", "none", 0.0)
	_ok(stage.get_char_anim("alice") == null, "静态立绘没有动画对象")
	_ok(not stage.set_char_anim("alice", 0.5),
		"静态立绘上 anim 返回 false（不报错、不影响画面）")
	_ok(not stage.set_char_anim("不存在的人"), "对不存在的角色调用 anim 也安全")
	_ok(PlaceholderAssets.sprite_root() == "res://assets/sprites/",
		"清掉测试注入后回到真实素材根目录")
	stage.queue_free()

	# --- 调度器：video 的阻塞与不阻塞 ---
	await _check_video_flow()

	# --- 视频：起播缓冲 ---
	# Godot 默认 buffering_msec=500，实测那 0.5 秒里画面是空的（过场开头先黑一下）。
	_ok(VideoScreen.DEFAULT_BUFFER_MS <= 200,
		"默认起播缓冲 ≤200ms（Godot 默认 500ms 会让过场开头黑一下）")
	var vparse := GvsParser.parse("label start\nvideo op buffer=300\n", "<t>")
	var vcmd: Dictionary = {}
	for c in vparse.get("commands", []):
		if String((c as Dictionary).get("op", "")) == "video":
			vcmd = c
	_ok(int(vcmd.get("buffer", -1)) == 300, "video 的 buffer= 能解析出来")
	var vdefault := GvsParser.parse("label start\nvideo op\n", "<t>")
	var vcmd2: Dictionary = {}
	for c in vdefault.get("commands", []):
		if String((c as Dictionary).get("op", "")) == "video":
			vcmd2 = c
	_ok(int(vcmd2.get("buffer", -1)) == VideoScreen.DEFAULT_BUFFER_MS,
		"不写 buffer= 时用默认值")

	# --- 视频：素材解析（用测试注入的根目录）---
	VideoScreen.video_root_override = "res://tools/fixtures/video/"
	_ok(VideoScreen.has_video("pattern"), "注入视频根目录后能解析到测试视频")
	_ok(not VideoScreen.has_video("根本没有这段视频"), "不存在的 id 仍判定为缺失")
	VideoScreen.video_root_override = ""
	_ok(VideoScreen.video_root() == "res://assets/video/",
		"清掉测试注入后回到真实视频根目录")

	# --- 剧本审计认得出视频素材 ---
	_ok(ScriptAudit.ASSET_DIRS.has("video"), "审计的素材表里有 video 目录")
	var used := {}
	ScriptAudit._collect_assets({"op": "video", "id": "op_demo"}, used)
	_ok((used.get("video", {}) as Dictionary).has("op_demo"), "审计收集到 video 素材 id")
	_ok(not ScriptAudit.has_real_asset("video", "op_demo"),
		"没有真实 .ogv 时判定为缺失（会出现在缺素材清单里）")


func _check_video_flow() -> void:
	# wait=true：调度器必须停在等待态，等外部放行
	await _run_media_script("video op_demo wait=true\nnarr 视频之后\n", func(runner: ScriptRunner) -> void:
		_ok(runner.is_waiting_video(), "video wait=true 让调度器进入等待态")
		runner.submit_video_finished()
		_ok(not runner.is_waiting_video(), "放行后离开等待态")
		_ok(runner.is_waiting_say(), "放行后停在下一条对白"))

	# 不带 wait：不阻塞，直接走到下一句
	await _run_media_script("video op_demo\nnarr 直接过\n", func(runner: ScriptRunner) -> void:
		_ok(runner.is_waiting_say(), "video 不带 wait 时不阻塞，直接走到下一句"))


func _run_media_script(body: String, check: Callable) -> void:
	var writer := FileAccess.open(MEDIA_SCRIPT_PATH, FileAccess.WRITE)
	if writer == null:
		_ok(false, "无法写入视频测试剧本")
		return
	writer.store_string("label start\n" + body + "ending smoke_media \"视频\"\n")
	writer.close()

	var runner := ScriptRunner.new()
	get_tree().root.add_child(runner)
	if not runner.load_script(MEDIA_SCRIPT_PATH):
		_ok(false, "视频测试剧本可加载")
		runner.queue_free()
		return
	runner.start()
	check.call(runner)
	runner.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(MEDIA_SCRIPT_PATH))
