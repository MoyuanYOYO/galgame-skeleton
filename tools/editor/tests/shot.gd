extends Node

## 编辑器界面截图
##
## 跑法（**必须带窗口**，headless 没有真实渲染）：
##   godot --path . res://tools/editor/tests/shot.tscn
##
## 输出到 `user://captures/editor_*.png`。

const EditorScene = preload("res://tools/editor/editor.tscn")

var _ed: Control
var _dir := "user://captures"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))

	_ed = EditorScene.instantiate()
	add_child(_ed)
	_ed.size = get_viewport().get_visible_rect().size
	get_viewport().size_changed.connect(func() -> void:
		_ed.size = get_viewport().get_visible_rect().size)

	# 等界面稳定（字体、SubViewport 首帧、索引扫描）
	await _wait(20)

	await _shot("editor_01_source")

	# 剧本块 —— 先把光标放到有演出内容的位置，场景状态条才有东西可显示
	_ed.show_page("script")
	_ed.goto_source(47)
	await _wait(4)
	_ed.show_page("table")
	await _wait(10)
	await _shot("editor_02_table")

	# 分支图
	_ed.show_page("graph")
	await _wait(6)
	await _shot("editor_03_graph")

	# 素材
	_ed.show_page("asset")
	await _wait(6)
	await _shot("editor_04_asset")

	# 立绘合集（点角色卡片打开的那一层）
	var ap: Control = _ed._pages.get("asset")
	if ap != null:
		ap.set("_kind", "char")
		ap.call("rebuild")
		await _wait(4)
		ap.call("_open_char_gallery", "alice")
		await _wait(6)
		await _shot("editor_08_char_gallery")
		ap.set("_gallery", ap.get("_gallery"))
		var gal: Control = ap.get("_gallery")
		if gal != null:
			gal.visible = false

	# 翻译
	_ed.show_page("i18n")
	await _wait(6)
	await _shot("editor_05_i18n")

	# 预览：从 start 标签跑一段，验证 Stage 真的被驱动起来
	_ed.show_page("script")
	_ed.goto_source(15)          # `label start`
	await _wait(4)
	_ed._preview_panel.run_from(15)
	await _wait(40)
	await _shot("editor_07_preview")

	# 跟随光标：光标停在一行有背景的位置，画面应当直接是那一行的样子
	_ed._preview_panel.stop()
	await _wait(4)
	_ed.goto_source(60)
	await _wait(8)
	await _shot("editor_09_follow")

	# 全局搜索
	_ed.show_page("search")
	await _wait(6)
	var sp: Control = _ed._pages.get("search")
	if sp != null:
		sp._query.text = "alice"
		sp.call("_run")
		await _wait(8)
	await _shot("editor_10_search")

	# 剧本块 + 查找条
	_ed.show_page("table")
	await _wait(10)
	var tp: Control = _ed._pages.get("table")
	if tp != null:
		tp.call("open_find")
		tp._find_input.text = "affection"
		tp.call("_refresh_find", true)
		await _wait(8)
	await _shot("editor_11_find")

	# 从**中间某行**开始预览：背景 / 立绘应当是「执行到这一行」的样子（累积状态），
	# 而不是从最近的标签重播（那样前面设的背景会丢）
	_ed.show_page("script")
	_ed.goto_source(60)
	await _wait(6)
	_ed._preview_panel.run_from_caret()
	await _wait(24)
	await _shot("editor_13_preview_from_line")
	_ed._preview_panel.stop()
	await _wait(4)

	# 变量页（完整页；侧栏那一节在每个页面上都能看到）
	_ed.show_page("var")
	await _wait(10)
	await _shot("editor_14_vars")

	# 语音页：两级浏览（角色卡片 → 双击进合集）。
	# 末尾那张「＋ 新建角色」卡片就是建分类目录的入口。
	_ed.show_page("asset")
	await _wait(6)
	var apv: Control = _ed._pages.get("asset")
	apv._kind = "voice"
	apv.rebuild()
	await _wait(10)
	await _shot("editor_16_voice_roles")

	# 空角色的合集：说明行要**整行宽的一段话**，不能是一列竖字
	apv._open_gallery("voice", "xiaolan")
	await _wait(10)
	await _shot("editor_17_voice_gallery_empty")
	apv._gallery.visible = false
	await _wait(4)

	# 再临时造两个角色目录，拍「有内容」的合集（紧凑行卡片）
	var demo := _make_voice_demo()
	apv.rebuild()
	await _wait(10)
	await _shot("editor_15_voice_roles")
	apv._open_gallery("voice", "alice")
	await _wait(10)
	await _shot("editor_18_voice_gallery")
	apv._gallery.visible = false
	_wipe_voice_demo(demo)
	_ed.index.scan()
	apv._kind = "bg"
	apv.rebuild()
	await _wait(4)

	# 快捷键一览
	_ed.call("_open_shortcuts")
	await _wait(8)
	await _shot("editor_12_help")
	_ed._help.hide()

	print("[shot] 完成，输出目录：", ProjectSettings.globalize_path(_dir))
	get_tree().quit(0)


## 造两个临时的语音角色目录（借一段现成的 ogg 当素材），返回目录列表
func _make_voice_demo() -> PackedStringArray:
	var src := ""
	for id in _ed.index.ids("bgm"):
		var p := String(_ed.index.get_entry("bgm", String(id)).get("path", ""))
		if p.ends_with(".ogg"):
			src = p
			break
	var dirs := PackedStringArray()
	if src.is_empty():
		return dirs
	var bytes := FileAccess.get_file_as_bytes(src)
	for spec in [["alice", 3], ["bob", 2]]:
		var pair: Array = spec
		var dir := "res://assets/audio/voice/%s/" % String(pair[0])
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
		dirs.append(dir)
		for i in int(pair[1]):
			var f := FileAccess.open("%sline_%02d.ogg" % [dir, i + 1], FileAccess.WRITE)
			if f != null:
				f.store_buffer(bytes)
				f.close()
	_ed.index.scan()
	return dirs


func _wipe_voice_demo(dirs: PackedStringArray) -> void:
	for d in dirs:
		var abs := ProjectSettings.globalize_path(String(d))
		if not DirAccess.dir_exists_absolute(abs):
			continue
		var files := PackedStringArray()
		var handle := DirAccess.open(abs)
		if handle != null:
			files = handle.get_files()
		handle = null
		for fn in files:
			DirAccess.remove_absolute(abs + String(fn))
		DirAccess.remove_absolute(abs)


func _wait(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_dir, name]
	var err := img.save_png(path)
	print("[shot] %s → %s (%s)" % [name, path, "ok" if err == OK else "err %d" % err])
