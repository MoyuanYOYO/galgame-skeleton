extends Node

## 编辑器「工具操作」验收
##
##   1. 新建剧本 —— data/scripts/<名字>.gvs + 最小骨架，并直接打开
##   2. 立绘合集 —— 点角色卡片打开该角色的全部表情
##   3. 新建角色 —— assets/sprites/<角色>/ + 占位立绘
##   4. 重命名 / 删除剧本 —— 含 jump_file 引用同步、入口剧本保护
##   5. 素材面板的「+」卡片与卡片右上角删除
##
## ⚠️ 这些都会**真的往项目里建 / 删文件**（那正是被测行为本身），
## 所以每条结束都必须清理干净并重扫索引 —— 否则测试会往仓库里留垃圾。
##
## 跑法（要带窗口）：
##   godot --path . res://tools/editor/tests/editor_tools_test.tscn

const EditorScene = preload("res://tools/editor/editor.tscn")
const ScriptPaths = preload("res://scripts/core/script_paths.gd")
const ScriptStats = preload("res://scripts/core/script_stats.gd")
const LineIndex = preload("res://tools/editor/core/line_index.gd")

const TMP_SCRIPT := "__tmp_new_script"
const TMP_CHAR := "__tmp_char"
const TMP_ASSET := "__tmp_asset"

var _ed: Control
var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 编辑器 工具操作验收 ===")
	_ed = EditorScene.instantiate()
	add_child(_ed)
	_ed.size = get_viewport().get_visible_rect().size
	await _wait(1.0)
	_ok(_ed.doc != null, "编辑器已打开入口剧本")
	if _ed.doc == null:
		_finish()
		return

	await _test_new_script()
	await _test_char_gallery()
	await _test_new_char()
	await _test_rename_and_delete()
	await _test_asset_ops()
	await _test_asset_rename()
	await _test_search_and_follow()
	await _test_table_and_preview()

	_ed.queue_free()
	await _wait(0.3)
	_finish()


# ---------------------------------------------------------------------------
# 1. 新建剧本
# ---------------------------------------------------------------------------

func _test_new_script() -> void:
	_sec("新建剧本")
	var path := "res://data/scripts/%s.gvs" % TMP_SCRIPT
	_remove_file(path)

	_ed._new_name.text = TMP_SCRIPT
	_ed._create_script()
	await _wait(0.6)

	_ok(FileAccess.file_exists(path), "文件建出来了（%s）" % path)
	var text := FileAccess.get_file_as_string(path)
	_ok(text.contains("label start"), "骨架里有 label start")
	_ok(text.contains(TMP_SCRIPT), "骨架里写了文件名")
	_ok(text.contains("chapters.json"), "骨架里提示了「怎么接进主流程」")
	_ok(_ed.doc.path == path, "创建后直接打开了它（实得 %s）" % _ed.doc.path)
	_ok(_file_button_exists("%s.gvs" % TMP_SCRIPT), "左侧「剧本」列表里出现了它")

	# 重名不能覆盖
	_ed._new_name.text = TMP_SCRIPT
	_ed._create_script()
	await _wait(0.3)
	_ok(_ed._notice.text.contains("已存在"), "重名被拒（实得 %s）" % _ed._notice.text)

	# 非法名字不能建
	_ed._new_name.text = "中文 名字!!"
	_ed._create_script()
	await _wait(0.3)
	_ok(_ed._notice.text.contains("小写字母"), "非法名字被拒（实得 %s）" % _ed._notice.text)
	_ok(not FileAccess.file_exists("res://data/scripts/__.gvs"), "没有建出乱七八糟的文件")

	# 清理：先切回入口剧本（避免 doc 指向已删除的文件），再删
	_ed._open(ScriptPaths.entry())
	await _wait(0.5)
	_remove_file(path)
	_ok(not FileAccess.file_exists(path), "临时剧本已删除")


# ---------------------------------------------------------------------------
# 2. 立绘合集
# ---------------------------------------------------------------------------

func _test_char_gallery() -> void:
	_sec("立绘合集")
	_ed.show_page("asset")
	await _wait(0.8)
	var ap: Control = _ed._pages.get("asset")
	_ok(ap != null, "素材面板已创建")
	if ap == null:
		return

	ap._kind = "char"
	ap.rebuild()
	await _wait(0.5)
	_ok(not ap._gallery.visible, "默认不显示合集")

	ap._open_char_gallery("alice")
	await _wait(0.4)
	_ok(ap._gallery.visible, "调用后合集打开了")
	_ok(ap._gallery_title.text.contains("alice"),
		"标题里有角色名（实得 %s）" % ap._gallery_title.text)
	var entry: Dictionary = _ed.index.get_entry("char", "alice")
	var want: int = (entry.get("exprs", {}) as Dictionary).size() \
		+ (entry.get("animated", {}) as Dictionary).size()
	# 末尾多一张「导入立绘」的 + 卡片
	_ok(ap._gallery_grid.get_child_count() == want + 1,
		"每个表情一张卡片 + 末尾一张 + 卡片（实得 %d，期望 %d）"
			% [ap._gallery_grid.get_child_count(), want + 1])
	_ok(_has_label_text(_last_child(ap._gallery_grid), "导入立绘"),
		"合集末尾的 + 卡片写着「导入立绘」")

	# ⚠️ 合集的卡片是 PanelContainer —— Container 会把**每个**子节点撑满内容区。
	# ✕ 必须走「垫一层普通 Control 当锚点坐标系」那条路，否则会被拉成整张卡那么大
	# （实测 156×109：既看不见，又把整张卡变成删除热区）。
	var gcard: Node = ap._gallery_grid.get_child(0)
	var gbadge: Button = null
	for d in _all_descendants(gcard):
		if d is Button and (d as Button).text == "✕":
			gbadge = d
	_ok(gbadge != null, "合集卡片上有 ✕ 徽章")
	if gbadge != null:
		_ok(gbadge.size.x < 40.0 and gbadge.size.y < 40.0,
			"✕ 没被 PanelContainer 撑满整卡（实得 %.0f×%.0f）"
				% [gbadge.size.x, gbadge.size.y])

	# 真实路径：点角色卡片也要能打开（用户报的「打不开」）
	ap._gallery.visible = false
	await _wait(0.2)
	var card := _first_button(ap._grid)
	_ok(card != null, "网格里有角色卡片")
	if card != null:
		# 单击 = 看详情（不进合集）——进合集会把整个网格换掉，
		# 想连着看几个角色的表情数就得反复进出
		card.pressed.emit()
		await _wait(0.4)
		_ok(not ap._gallery.visible, "单击角色卡片**不**进合集")
		var link := _find_button(ap._detail, "进入立绘合集 →")
		_ok(link != null, "详情里有「进入立绘合集」入口（双击是隐藏操作，得留个明路）")
		if link != null:
			link.pressed.emit()
			await _wait(0.4)
			_ok(ap._gallery.visible, "点详情里的入口能进合集")
			ap._gallery.visible = false
			await _wait(0.2)

		# 双击才进合集。Button 没有双击信号，所以走 gui_input 的 double_click
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		mb.pressed = true
		mb.double_click = true
		card.gui_input.emit(mb)
		await _wait(0.4)
		_ok(ap._gallery.visible, "双击角色卡片打开合集")

	# 关闭
	var close := _find_button(ap._gallery, "关闭")
	_ok(close != null, "合集里有「关闭」")
	if close != null:
		close.pressed.emit()
		await _wait(0.2)
		_ok(not ap._gallery.visible, "关闭有效")


# ---------------------------------------------------------------------------
# 3. 新建角色
# ---------------------------------------------------------------------------

func _test_new_char() -> void:
	_sec("新建角色")
	var ap: Control = _ed._pages.get("asset")
	var dir_path := "res://assets/sprites/%s/" % TMP_CHAR
	_remove_dir(dir_path)

	ap._new_char_name.text = TMP_CHAR
	ap._create_char()
	await _wait(0.9)

	_ok(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path)),
		"目录建出来了（%s）" % dir_path)
	_ok(FileAccess.file_exists(dir_path + "normal.png"),
		"放了占位立绘 normal.png（不放的话新角色不会出现在索引里）")
	_ok(_ed.index.char_ids().has(TMP_CHAR), "新角色进了素材索引")
	_ok(ap._gallery.visible and ap._gallery_title.text.contains(TMP_CHAR),
		"顺手打开了它的立绘合集（实得 %s）" % ap._gallery_title.text)

	# 重名拒绝
	ap._new_char_name.text = TMP_CHAR
	ap._create_char()
	await _wait(0.3)
	_ok(_ed._notice.text.contains("已存在"), "重名被拒（实得 %s）" % _ed._notice.text)

	# 清理
	_remove_dir(dir_path)
	_ed.index.scan()
	_ed._refresh_index_summary()
	await _wait(0.4)
	_ok(not _ed.index.char_ids().has(TMP_CHAR), "清理后索引里也没有了")


# ---------------------------------------------------------------------------
# 4. 重命名 / 删除剧本
# ---------------------------------------------------------------------------

func _test_rename_and_delete() -> void:
	_sec("重命名 / 删除剧本")
	var a := "res://data/scripts/%s.gvs" % TMP_SCRIPT
	var b := "res://data/scripts/%s_b.gvs" % TMP_SCRIPT
	var ref := "res://data/scripts/%s_ref.gvs" % TMP_SCRIPT
	for p in [a, b, ref]:
		_remove_file(p)
	_write(a, "label start\nnarr （A。）\n")
	_write(ref, "label start\njump_file %s start\n" % a)
	ScriptStats.clear_cache()
	_ed._refresh_files()
	await _wait(0.4)
	_ok(_file_button_exists("%s.gvs" % TMP_SCRIPT), "临时剧本出现在左栏")

	# --- 重命名：文件、文档路径、jump_file 引用三处都要跟上 ---
	_ed._open(a)
	await _wait(0.5)
	_ed._open_rename(a)
	_ok(_ed._rename_dialog.visible, "「重命名」对话框弹出来了")
	_ok(_ed._rename_name.text == TMP_SCRIPT, "输入框预填了当前名字（实得 %s）" % _ed._rename_name.text)
	_ed._rename_name.text = "%s_b" % TMP_SCRIPT
	_ed._do_rename()
	await _wait(0.6)
	_ok(FileAccess.file_exists(b), "文件已改名（%s）" % b)
	_ok(not FileAccess.file_exists(a), "旧名字的文件没有了")
	_ok(_ed.doc.path == b, "文档跟着换到新路径（实得 %s）" % _ed.doc.path)
	_ok(FileAccess.get_file_as_string(ref).contains(b),
		"别的剧本里的 jump_file 引用被同步（%s）" % FileAccess.get_file_as_string(ref).strip_edges())
	_ok(_file_button_exists("%s_b.gvs" % TMP_SCRIPT), "左栏跟着刷新出新名字")

	# --- 入口剧本保护：改名 / 删除都要被拦下 ---
	_ed._open_rename(ScriptPaths.entry())
	await _wait(0.3)
	_ok(_ed._notice.text.contains("入口剧本"),
		"入口剧本拒绝改名（实得 %s）" % _ed._notice.text)
	_ok(not _ed._rename_dialog.visible, "拒绝时对话框不弹")
	_ed._open_delete(ScriptPaths.entry())
	await _wait(0.3)
	_ok(_ed._notice.text.contains("入口剧本"),
		"入口剧本拒绝删除（实得 %s）" % _ed._notice.text)

	# --- 删除：当前打开的剧本也能删（先自动切走） ---
	_ed._open(b)
	await _wait(0.5)
	_ed._open_delete(b)
	_ok(_ed._delete_dialog.visible, "「删除」对话框弹出来了")
	_ed._do_delete()
	await _wait(0.6)
	_ok(not FileAccess.file_exists(b), "文件已删除")
	_ok(_ed.doc.path != b, "文档已切走（现在 %s）" % _ed.doc.path)
	_ok(not _file_button_exists("%s_b.gvs" % TMP_SCRIPT), "左栏里也没有了")

	# 清理
	_remove_file(ref)
	ScriptStats.clear_cache()
	_ed._refresh_files()
	await _wait(0.3)
	_ok(not FileAccess.file_exists(ref), "临时引用剧本已清理")


# ---------------------------------------------------------------------------
# 5. 素材面板：「+」卡片与卡片右上角删除
# ---------------------------------------------------------------------------

func _test_asset_ops() -> void:
	_sec("素材：+ 卡片与删除")
	_ed.show_page("asset")
	await _wait(0.6)
	var ap: Control = _ed._pages.get("asset")
	_ok(ap != null, "素材面板存在")
	if ap == null:
		return

	# 背景页：末尾一张「导入素材」的 + 卡片
	ap._kind = "bg"
	ap.rebuild()
	await _wait(0.5)
	var bg_total: int = _ed.index.count("bg")
	var bg_miss: int = (_ed.index.missing().get("bg", []) as Array).size()
	_ok(ap._grid.get_child_count() == bg_total + bg_miss + 1,
		"网格 = 素材数 + 缺失数 + 1 张 + 卡片（实得 %d，素材 %d 缺失 %d）"
			% [ap._grid.get_child_count(), bg_total, bg_miss])
	_ok(_has_label_text(_last_child(ap._grid), "导入素材"), "背景页的 + 卡片写着「导入素材」")

	# 立绘页：+ 卡片是「新建角色」（不是导入）
	ap._kind = "char"
	ap.rebuild()
	await _wait(0.4)
	_ok(_has_label_text(_last_child(ap._grid), "新建角色"), "立绘页的 + 卡片写着「新建角色」")

	# --- 造一张临时背景，走「点 ✕ → 确认 → 删除」这条真实路径 ---
	_ed.index.scan()
	var src := _pick_bg_source()
	_ok(not src.is_empty(), "有可复制的背景素材（%s）" % src)
	var tmp := "res://assets/bg/%s.png" % TMP_ASSET
	_remove_file(tmp)
	_write_bytes(tmp, FileAccess.get_file_as_bytes(src))
	_ed.index.scan()
	ap._kind = "bg"
	ap.rebuild()
	await _wait(0.5)
	_ok(_ed.index.has("bg", TMP_ASSET), "临时背景进了索引")

	var card := _find_card_by_label(ap._grid, TMP_ASSET)
	_ok(card != null, "网格里找到了它的卡片")
	if card != null:
		_ok(_find_badge(card, "✎") != null, "卡片右上角有 ✎ 重命名")
		_ok(_find_badge(card, "✕") != null, "卡片右上角有 ✕ 删除")

	ap._ask_delete_asset("bg", TMP_ASSET)
	await _wait(0.3)
	_ok(ap._confirm.visible, "删除确认框弹出来了")
	_ok(ap._confirm.dialog_text.contains(TMP_ASSET), "确认框里写了要删的文件")
	# 走真实的确认信号（不是直接调 _pending_delete）—— 保证接线没接错
	ap._confirm.confirmed.emit()
	await _wait(0.5)
	_ok(not FileAccess.file_exists(tmp), "确认后文件真的删掉了")
	_ok(not _ed.index.has("bg", TMP_ASSET), "索引里也没有了")
	_ok(ap._grid.get_child_count() == bg_total + bg_miss + 1,
		"网格回到「素材数 + 缺失数 + 1」（实得 %d）" % ap._grid.get_child_count())

	# --- 删除可撤销：素材是作者的手工劳动，误删必须能一键找回 ---
	ap._do_undo()
	await _wait(0.5)
	_ok(FileAccess.file_exists(tmp), "⚠ 撤销后删掉的文件回来了")
	_ok(_ed.index.has("bg", TMP_ASSET), "索引里也回来了")
	_ok(_file_bytes(tmp) == _file_bytes(src), "内容与源文件逐字节相同")
	ap._do_undo()
	await _wait(0.4)
	_ok(FileAccess.file_exists(tmp), "没有更早的操作时再点撤销不会乱删东西")

	# 取消删除不能删东西
	ap._ask_delete_asset("bg", TMP_ASSET)
	await _wait(0.3)
	ap._pending_delete = Callable()     # 等价于用户点了「取消」
	ap._confirm.hide()
	await _wait(0.2)
	_ok(FileAccess.file_exists(tmp), "取消后文件还在")

	_remove_file(tmp)
	_ed.index.scan()
	_ed._refresh_index_summary()
	ap.rebuild()
	await _wait(0.4)
	_ok(not _ed.index.has("bg", TMP_ASSET), "临时背景已清理")


# ---------------------------------------------------------------------------
# 6. 素材重命名（含剧本引用同步）
# ---------------------------------------------------------------------------

func _test_asset_rename() -> void:
	_sec("素材重命名")
	var ap: Control = _ed._pages.get("asset")
	var old_id := "%s_old" % TMP_ASSET
	var new_id := "%s_new" % TMP_ASSET
	var src_path := "res://assets/bg/%s.png" % old_id
	var dst_path := "res://assets/bg/%s.png" % new_id
	var ref := "res://data/scripts/%s_ref.gvs" % TMP_SCRIPT
	for p in [src_path, dst_path, ref]:
		_remove_file(p)

	# 造一张临时背景 + 一个引用它的剧本
	_ed.index.scan()
	var src := _pick_bg_source()
	_ok(not src.is_empty(), "有可复制的背景素材（%s）" % src)
	_write_bytes(src_path, FileAccess.get_file_as_bytes(src))
	_write(ref, "label start\nbg %s fade=0.5\nnarr （引用。）\n" % old_id)
	ScriptStats.clear_cache()
	_ed.index.scan()
	ap._kind = "bg"
	ap.rebuild()
	_ed._refresh_files()
	await _wait(0.6)
	_ok(_ed.index.has("bg", old_id), "临时背景进了索引")

	# 卡片上要有 ✎ 与 ✕ 两个徽章
	var card := _find_card_by_label(ap._grid, old_id)
	_ok(card != null, "找到了它的卡片")
	if card != null:
		_ok(_find_badge(card, "✎") != null, "卡片右上角有 ✎ 重命名")
		_ok(_find_badge(card, "✕") != null, "卡片右上角有 ✕ 删除")

	# 走真实的按钮 → 对话框 → 改名
	ap._ask_rename_asset("bg", old_id)
	await _wait(0.3)
	_ok(ap._rename_dialog.visible, "重命名对话框弹出来了")
	_ok(ap._rename_name.text == old_id, "输入框预填了当前 id（实得 %s）" % ap._rename_name.text)
	_ok(ap._rename_dialog.dialog_text.contains("引用"),
		"提示里说了会同步剧本引用（实得 %s）" % ap._rename_dialog.dialog_text)
	ap._rename_name.text = new_id
	ap._do_rename_asset()
	await _wait(0.6)

	_ok(FileAccess.file_exists(dst_path), "文件已改名（%s）" % dst_path)
	_ok(not FileAccess.file_exists(src_path), "旧文件没有了")
	_ok(_ed.index.has("bg", new_id), "索引里是新 id")
	_ok(not _ed.index.has("bg", old_id), "索引里没有旧 id")
	var ref_text := FileAccess.get_file_as_string(ref)
	_ok(ref_text.contains("bg %s fade=0.5" % new_id),
		"⚠ 剧本里的引用被同步（实得 %s）" % ref_text.strip_edges())
	_ok(not ref_text.contains(old_id), "旧 id 在剧本里也没有残留")

	# --- 撤销：文件与剧本引用必须**一起**回滚 ---
	# 「撤了一半」（文件回来了、引用还指着新名字）比不能撤销更糟，所以两边都断言。
	_ok(ap._btn_undo.disabled == false, "「↶ 撤销」按钮亮了")
	ap._do_undo()
	await _wait(0.7)
	_ok(FileAccess.file_exists(src_path), "撤销后旧文件回来了")
	_ok(not FileAccess.file_exists(dst_path), "新文件没有了")
	_ok(_ed.index.has("bg", old_id), "索引回到旧 id")
	_ok(not _ed.index.has("bg", new_id), "索引里没有新 id")
	var back := FileAccess.get_file_as_string(ref)
	_ok(back.contains("bg %s fade=0.5" % old_id),
		"⚠ 剧本引用也回滚了（实得 %s）" % back.strip_edges())
	_ok(not back.contains(new_id), "剧本里没有新 id 残留")
	_ok(ap._btn_undo.disabled, "撤销后按钮变灰（栈空了）")

	# 清理
	_remove_file(src_path)
	_remove_file(dst_path)
	_remove_file(ref)
	ScriptStats.clear_cache()
	_ed.index.scan()
	_ed._refresh_index_summary()
	ap.rebuild()
	_ed._refresh_files()
	await _wait(0.5)
	_ok(not _ed.index.has("bg", new_id), "临时素材已清理")
	_ok(not FileAccess.file_exists(ref), "临时引用剧本已清理")


# ---------------------------------------------------------------------------
# 7. 全局搜索 / 剧本块查找 / 预览跟随光标
# ---------------------------------------------------------------------------

func _test_search_and_follow() -> void:
	_sec("全局搜索")
	_ed.show_page("search")
	await _wait(0.6)
	var sp: Control = _ed._pages.get("search")
	_ok(sp != null, "搜索页已创建")
	if sp != null:
		sp._query.text = "affection"
		sp._run()
		await _wait(0.4)
		_ok(sp._results.size() > 0, "有命中（%d 处）" % sp._results.size())
		_ok(sp._hint.text.contains("命中"), "提示里有命中数（实得 %s）" % sp._hint.text)
		# 跨文件才是这个功能的重点
		var files := {}
		for r in sp._results:
			files[String((r as Dictionary).get("file", ""))] = true
		_ok(files.size() >= 2, "命中来自 %d 个剧本（跨文件搜索）" % files.size())
		_ok(_list_has_button(sp._list, "prologue.gvs"), "结果里列出了 prologue.gvs")

		sp._query.text = "绝不可能出现的字符串_zzz"
		sp._run()
		await _wait(0.3)
		_ok(sp._results.is_empty(), "搜不到时结果为空")
		_ok(sp._hint.text.contains("没有命中"), "并明确说「没有命中」（实得 %s）" % sp._hint.text)

	_sec("剧本块内查找")
	_ed.show_page("table")
	await _wait(0.8)
	var table: Control = _ed._pages.get("table")
	_ok(table != null, "剧本块已创建")
	if table != null:
		_ok(not table.is_find_open(), "查找条默认不显示")
		table.open_find()
		await _wait(0.3)
		_ok(table.is_find_open(), "Ctrl+F 打开了查找条")
		table._find_input.text = "affection"
		table._refresh_find(true)
		await _wait(0.4)
		_ok(table._find_hits.size() > 0, "找到了 affection（%d 处）" % table._find_hits.size())
		_ok(table._find_info.text.contains("/"),
			"显示了「第 N / M 处」（实得 %s）" % table._find_info.text)
		var first: int = table._current_no
		_ok(table._find_hits.has(first), "当前行就落在命中上")
		table._step_find(1)
		await _wait(0.4)
		_ok(table._current_no != first or table._find_hits.size() == 1,
			"再找一处会跳到别的行（%d → %d）" % [first, table._current_no])
		table._step_find(-1)
		await _wait(0.4)
		_ok(table._current_no == first, "往回找回到原处（实得 %d）" % table._current_no)
		table.close_find()
		_ok(not table.is_find_open(), "关闭有效")

	_sec("预览跟随光标")
	_ed.show_page("script")
	await _wait(0.4)
	var pv: Control = _ed._preview_panel
	_ok(pv._follow, "跟随光标默认开着")
	# 找一行真的设了背景的
	var bg_line := 0
	var want_bg := ""
	for l in _ed.doc.lines:
		var line := l as LineIndex.Line
		if line.head == "bg" and line.args.size() > 0:
			bg_line = line.no
			want_bg = String(line.args[0])
			break
	_ok(bg_line > 0, "剧本里有 bg 指令（第 %d 行 → %s）" % [bg_line, want_bg])
	if bg_line > 0:
		_ed.goto_source(bg_line)
		await _wait(0.6)
		var st: Dictionary = pv._stage.get_state()
		_ok(String(st.get("bg", "")) == want_bg,
			"⚠ 光标移过去，画面直接换成那一行的背景（实得 %s）" % String(st.get("bg", "")))

		# 关掉跟随 → 光标再动，画面不该跟着变
		pv._chip_follow.button_pressed = false
		await _wait(0.3)
		_ok(not pv._follow, "可以关掉跟随")
		_ed.goto_source(1)
		await _wait(0.5)
		var st2: Dictionary = pv._stage.get_state()
		_ok(String(st2.get("bg", "")) == want_bg, "关掉之后画面不再跟着光标变")
		pv._chip_follow.button_pressed = true
		await _wait(0.3)


func _list_has_button(node: Node, needle: String) -> bool:
	for d in _all_descendants(node):
		if d is Button and (d as Button).text.contains(needle):
			return true
	return false


# ---------------------------------------------------------------------------
# 8. 表格字段提交 / 素材变了要重刷下拉 / 从此处预览精确到行
# ---------------------------------------------------------------------------

const TMP_TBL := "__tmp_tbl_script"
const TMP_CHAR2 := "__tmp_char2"
const TMP_VOICE_GROUP := "__tmp_role"
const TMP_VOICE_NAME := "__tmp_v1"

var _tbl_path := "res://data/scripts/%s.gvs" % TMP_TBL


func _test_table_and_preview() -> void:
	_sec("数值框失焦要提交")
	_remove_file(_tbl_path)
	_write(_tbl_path, "label start\nbg classroom fade=0.8\nnarr （旁白。）\n")
	ScriptStats.clear_cache()
	_ed._refresh_files()
	_ed._open(_tbl_path)
	await _wait(0.7)
	_ok(_ed.doc.path == _tbl_path, "打开了临时剧本（不动真剧本）")

	_ed.show_page("table")
	await _wait(1.0)
	var table: Control = _ed._pages.get("table")
	_ok(table != null, "剧本块已创建")
	if table != null:
		var row: Control = table._row_by_no.get(2, null)
		_ok(row != null, "找到了第 2 行（bg）的控件")
		var edit: LineEdit = null
		for d in _all_descendants(row):
			if d is LineEdit and (d as LineEdit).text.is_valid_float() \
					and is_equal_approx((d as LineEdit).text.to_float(), 0.8):
				edit = d
				break
		_ok(edit != null, "找到了 fade 的数值框（%s）" % ("0.80" if edit == null else edit.text))
		if edit != null:
			# ⚠️ `_ed` 是 untyped 的 Control，`_ed.doc.text_at()` 推不出类型 ——
			# 写 `:=` 会直接编译不过（Cannot infer the type）
			var before: String = _ed.doc.text_at(2)
			edit.text = "1.5"
			# 等价于「改完直接点别处」—— 这正是用户报的那条路径
			edit.focus_exited.emit()
			await _wait(0.5)
			var after: String = _ed.doc.text_at(2)
			_ok(after != before, "⚠ 失焦后源代码更新了（%s → %s）" % [before, after])
			_ok(after.contains("fade=1.5"), "写进去的是新值（实得 %s）" % after)
			_ok(_ed.doc.is_dirty(), "改动进了文档（未保存状态）")

	_sec("素材变了 → 剧本块的下拉要跟上")
	# 先造一个新角色（带 normal.png）
	var dir_path := "res://assets/sprites/%s/" % TMP_CHAR2
	_remove_dir(dir_path)
	# ⚠️ 顺序有讲究：**先把索引刷成「没有这个角色」**，再让表建好，
	# 最后才建目录 —— 这样「旧表缺新角色」这个前提一定成立。
	# 反过来的话，前一个用例留下的 scan() 可能刚好扫到了它，
	# 断言就会随执行顺序飘。
	_ed.index.scan()

	if table != null:
		table.rebuild()
		await _wait(0.8)

		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
		_write_bytes(dir_path + "normal.png",
			FileAccess.get_file_as_bytes("res://assets/sprites/alice/normal.png"))
		_ok(not _ed.index.has("char", TMP_CHAR2), "索引还没重扫，所以还不知道有新角色")
		_ok(not _char_option_has(table, TMP_CHAR2),
			"旧表的下拉里没有新角色（用户看到的就是这个）")

		# 导入 / 新建角色之后走的那条路
		_ed.show_page("asset")
		await _wait(0.6)
		var ap: Control = _ed._pages.get("asset")
		_ok(ap != null, "素材页已创建")
		if ap != null:
			ap._after_asset_change()
			await _wait(0.4)
		_ok(not table._is_built(), "剧本块被作废（下次显示会整表重建）")

		_ed.show_page("table")
		await _wait(1.4)
		_ok(_char_option_has(table, TMP_CHAR2),
			"⚠ 重建后下拉里有新角色了（用户报的 bug）")

	_sec("从此处预览：精确到行 + 累积画面")
	# ⚠️ 先切回入口剧本 —— 上面把临时剧本改脏了，不切走的话
	# ① 重写文件会与内存里的文档打架；② `_open` 见到 `doc.path == path` 会直接 return，
	# 根本不会重新读盘。
	_ed._open(ScriptPaths.entry())
	await _wait(0.7)
	_write(_tbl_path, "\n".join(PackedStringArray([
		"label start",
		"bg classroom",
		"show alice expr=normal at=left",
		"alice@normal: 第一句。",
		"alice@smile: 第二句。",
		"narr [bounce height=13]弹跳[/bounce] · [wait=0.7]停顿",
		"ending e \"E\"",
	])) + "\n")
	ScriptStats.clear_cache()
	_ed._refresh_files()
	_ed._open(_tbl_path)
	await _wait(0.8)

	var pv: Control = _ed._preview_panel
	pv.run_from(5)                     # `alice@smile: 第二句。`
	await _wait(1.0)
	_ok(pv.is_running(), "预览起来了")
	# ⚠️ 不要断言状态文字 —— 第一条指令是对白时，调度器会把它改成
	# 「点击画面继续」（那才是该给用户的提示）。「从哪一行开始」由下面两条证明：
	# 第一句台词就是目标行那句、且前面设的背景还在。
	_ok(pv._dlg_text.text == "第二句。",
		"⚠ 第一句就是第 5 行那句，不是从标签重播（实得 %s）" % pv._dlg_text.text)
	var st: Dictionary = pv._stage.get_state()
	_ok(String(st.get("bg", "")) == "classroom",
		"⚠ 前面第 2 行设的背景还在（实得 %s）" % String(st.get("bg", "")))
	var expr := ""
	for c in st.get("chars", []):
		if String((c as Dictionary).get("char", "")) == "alice":
			expr = String((c as Dictionary).get("expr", ""))
	_ok(expr == "smile", "⚠ 表情是第 5 行要的 smile（实得 %s）" % expr)
	pv.stop()
	await _wait(0.3)

	# 文件末尾之后的空白行：没有可执行指令 → 不跑，并说明原因
	pv.run_from(999)
	await _wait(0.4)
	_ok(not pv.is_running(), "行号超出文件末尾时不跑（不悄悄退回按标签重播）")
	_ok(pv._status.text.contains("没有可执行的指令"),
		"并说明原因（实得 %s）" % pv._status.text)

	_sec("预览里的文字特效")
	_ok(pv._dlg_text.custom_effects.size() > 0,
		"预览的对话框登记了自定义特效（%d 个）" % pv._dlg_text.custom_effects.size())
	pv.run_from(6)                     # `narr [bounce ...]弹跳[/bounce] · [wait=0.7]停顿`
	await _wait(0.8)
	var shown: String = pv._dlg_text.get_parsed_text()
	_ok(not shown.contains("[bounce"),
		"⚠ 特效标签没漏成正文（实得 %s）" % shown)
	_ok(shown.contains("弹跳"), "特效里的文字还在（实得 %s）" % shown)
	_ok(not shown.contains("[wait="), "⚠ 节奏标记 [wait=] 被剥掉了（实得 %s）" % shown)
	_ok(shown.contains("停顿"), "节奏标记后面的文字还在（实得 %s）" % shown)
	pv.stop()
	await _wait(0.3)

	_sec("语音按角色分组")
	var vdir := "res://assets/audio/voice/%s/" % TMP_VOICE_GROUP
	_remove_dir(vdir)
	# 借一段现成的 ogg 当素材（内容不重要，索引只认文件名与后缀）
	var vsrc := ""
	for id in _ed.index.ids("bgm"):
		vsrc = String(_ed.index.get_entry("bgm", String(id)).get("path", ""))
		break
	if vsrc.is_empty() or not vsrc.ends_with(".ogg"):
		# 没有 ogg 就跳过这一段，别用假数据把测试变成自欺欺人
		_ok(true, "（没有可借用的 .ogg，跳过语音分组验收）")
	else:
		# ① 还没有任何分类目录时，界面要**指到建分类的入口** ——
		#    之前这里根本没有入口，用户反馈「我没见到分类」
		_ed.show_page("asset")
		await _wait(0.6)
		var ap2: Control = _ed._pages.get("asset")
		ap2._kind = "voice"
		ap2.rebuild()
		await _wait(0.6)
		_ok(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(vdir)),
			"一开始没有角色目录")
		# 「＋」卡片的文字在子 Label 上（Button 自身 text 是空的），所以查 Label
		_ok(_has_label_text(ap2._grid, "新建角色"),
			"⚠ 语音页的「＋」卡片写着「新建角色」（建分类的入口）")
		# ⚠️ 立绘里有、但还没建语音目录的角色也要列出来，标成「未建」——
		# 不列的话作者没法知道还有谁没配音（用户反馈「不显示已有角色」）
		var pend := _role_card(ap2, "alice")
		_ok(pend != null, "⚠ 立绘角色 alice 也出现在语音页（还没建目录）")
		_ok(not _ed.index.group_exists("voice", "alice"), "它确实还没有语音目录")
		_ok(ap2._stat.text.contains("还没建目录"),
			"状态条说明有几个还没建（实得 %s）" % ap2._stat.text)

		# ⚠️ 空合集的说明必须摆在**网格外面**。摆进 GridContainer 的话，
		# 带 autowrap 的 Label 最小宽度是 0 → 被压成一条竖线、一个字一行
		# （用户报的「界面还是长」）。
		ap2._open_gallery("voice", "alice")
		await _wait(0.4)
		_ok(ap2._gallery_hint.visible, "空合集显示了说明行")
		_ok(ap2._gallery_hint.get_parent() is VBoxContainer,
			"⚠ 说明行挂在网格外面（实得父节点 %s）" % ap2._gallery_hint.get_parent().get_class())
		_ok(ap2._gallery_hint.autowrap_mode != TextServer.AUTOWRAP_OFF,
			"说明行允许换行（长句不会顶出去）")
		ap2._gallery.visible = false
		await _wait(0.2)

		# ② 用界面建分类目录
		ap2._open_new_role_dialog()
		await _wait(0.3)
		_ok(ap2._new_group_kind == "voice", "对话框切到语音模式")
		_ok(ap2._new_char_dialog.title.contains("语音"),
			"标题说明这是语音分类（实得 %s）" % ap2._new_char_dialog.title)
		ap2._new_char_name.text = TMP_VOICE_GROUP
		ap2._on_new_group_confirmed()
		await _wait(0.8)
		_ok(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(vdir)),
			"⚠ 建出了分类目录 %s" % vdir)
		_ok(ap2._gallery.visible and ap2._gallery_kind == "voice",
			"建完直接进那个角色的合集（下一步就是导语音）")

		# ②b ⚠️ **空目录也要有卡片** —— 用户报过「新建角色返回时不显示新建的
		#     角色文件夹」：`groups()` 原来是从 id 反推的，空目录没有 id，凭空消失
		ap2._gallery.visible = false
		_ed.index.scan()
		ap2.rebuild()
		await _wait(0.5)
		_ok(_ed.index.groups("voice").has(TMP_VOICE_GROUP),
			"空目录也算一个组（实得 %s）" % str(_ed.index.groups("voice")))
		_ok(_role_card(ap2, TMP_VOICE_GROUP) != null,
			"⚠ 空目录的角色卡片在（用户报的 bug）")
		_ok(_ed.index.group_exists("voice", TMP_VOICE_GROUP), "group_exists 认它")

		# ③ 往里放一条语音（等价于在合集里点「＋」导入）
		_write_bytes(vdir + TMP_VOICE_NAME + ".ogg", FileAccess.get_file_as_bytes(vsrc))
		_ed.index.scan()
		ap2._gallery.visible = false
		ap2.rebuild()
		await _wait(0.5)

		var vid := "%s/%s" % [TMP_VOICE_GROUP, TMP_VOICE_NAME]
		_ok(_ed.index.has("voice", vid),
			"⚠ 分组素材的 id 是「组/文件名」（实得 %s）" % str(_ed.index.ids("voice")))
		_ok(_ed.index.groups("voice").has(TMP_VOICE_GROUP),
			"groups() 认出了这一组（实得 %s）" % str(_ed.index.groups("voice")))
		_ok(not _ed.index.conflicts.any(func(c: Dictionary) -> bool:
			return String(c.get("id", "")) == vid),
			"「组/文件名」不算命名不规范")

		# 两级浏览：网格页只列角色，双击进合集看组内语音
		var rc := _role_card(ap2, TMP_VOICE_GROUP)
		_ok(rc != null, "语音页出现角色卡片（不再把一堆语音平铺在一个界面）")
		_ok(not _grid_has_card(ap2, vid), "组内语音**不**直接铺在网格页")
		if rc != null:
			rc.pressed.emit()
			await _wait(0.4)
			_ok(not ap2._gallery.visible, "单击角色卡片只更新详情（不进合集）")
			var link := _find_button(ap2._detail, "进入语音合集 →")
			_ok(link != null, "详情里有「进入语音合集 →」入口")
			var mb := InputEventMouseButton.new()
			mb.button_index = MOUSE_BUTTON_LEFT
			mb.pressed = true
			mb.double_click = true
			rc.gui_input.emit(mb)
			await _wait(0.5)
			_ok(ap2._gallery.visible, "双击角色卡片打开语音合集")
			_ok(ap2._gallery_kind == "voice", "合集是语音合集（实得 %s）" % ap2._gallery_kind)
			_ok(ap2._gallery_title.text.contains(TMP_VOICE_GROUP),
				"标题里有角色名（实得 %s）" % ap2._gallery_title.text)
			_ok(_gallery_has_card(ap2, vid), "合集里有那条语音")
			# ⚠️ 卡片里的台词名要**真的有宽度** —— 卡片里垫的那层 overlay 不给
			# anchors 就是 0×0，里面 `SIZE_EXPAND_FILL` + `clip_text` 的 Label
			# 会被压成 0 宽、整条名字看不见。文字断言查不出来，只能量几何。
			var vcard := _gallery_card_of(ap2, vid)
			_ok(vcard != null, "拿到了那张语音卡片")
			if vcard != null:
				var name_l := _label_containing(vcard, TMP_VOICE_NAME)
				_ok(name_l != null, "卡片里有台词名的 Label")
				if name_l != null:
					_ok(name_l.size.x > 20,
						"⚠ 台词名有实际宽度（实得 %.0f）" % name_l.size.x)
			_ok(_has_label_text(_last_child(ap2._gallery_grid), "导入到 %s" % TMP_VOICE_GROUP),
				"合集末尾的 + 卡片写着「导入到 <角色>」")
			ap2._gallery.visible = false
			await _wait(0.2)

		# 组内语音改名：只改叶子名，组名不动
		ap2._ask_rename_asset("voice", vid)
		await _wait(0.3)
		_ok(ap2._rename_name.text == TMP_VOICE_NAME,
			"输入框里只有叶子名（实得 %s）" % ap2._rename_name.text)
		ap2._rename_name.text = TMP_VOICE_NAME + "_b"
		ap2._do_rename_asset()
		await _wait(0.7)
		var vid2 := "%s/%s_b" % [TMP_VOICE_GROUP, TMP_VOICE_NAME]
		_ok(_ed.index.has("voice", vid2),
			"改名后 id 是 %s（实得 %s）" % [vid2, str(_ed.index.ids("voice"))])
		_ok(FileAccess.file_exists(vdir + TMP_VOICE_NAME + "_b.ogg"), "文件在组目录里换了名")
		_ok(not FileAccess.file_exists(vdir + TMP_VOICE_NAME + ".ogg"), "旧文件没了")

		# 角色改名：目录整个改，成员 id 跟着换
		var vgroup2 := TMP_VOICE_GROUP + "_b"
		ap2._ask_rename_voice_role(TMP_VOICE_GROUP)
		await _wait(0.3)
		_ok(ap2._rename_name.text == TMP_VOICE_GROUP,
			"角色改名的输入框里是角色名（实得 %s）" % ap2._rename_name.text)
		ap2._rename_name.text = vgroup2
		ap2._do_rename_asset()
		await _wait(0.8)
		var vid3 := "%s/%s_b" % [vgroup2, TMP_VOICE_NAME]
		_ok(_ed.index.has("voice", vid3),
			"⚠ 角色改名后成员 id 跟着换（实得 %s）" % str(_ed.index.ids("voice")))
		_ok(DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path("res://assets/audio/voice/%s/" % vgroup2)),
			"目录也换了名")
		vid = vid3
		vdir = "res://assets/audio/voice/%s/" % vgroup2

		# 删掉整个角色目录
		ap2._ask_delete_voice_role(vgroup2)
		await _wait(0.3)
		_ok(ap2._confirm.visible, "删除角色要先确认")
		ap2._confirm.confirmed.emit()
		await _wait(0.7)
		_ok(not FileAccess.file_exists(vdir + TMP_VOICE_NAME + "_b.ogg"), "整个角色目录删掉了")
		ap2._do_undo()
		await _wait(0.6)
		_ok(FileAccess.file_exists(vdir + TMP_VOICE_NAME + "_b.ogg"),
			"⚠ 删角色也能撤销找回")
		_ok(_ed.index.has("voice", vid), "索引里也回来了")

		# 回到背景页，角色卡片应当不见
		ap2._kind = "bg"
		ap2.rebuild()
		await _wait(0.4)
		_ok(not _grid_has_card(ap2, vid), "背景页没有语音卡片")

		# 清理
		_remove_dir(vdir)
		_ed.index.scan()
		_ed._refresh_index_summary()
		_ed.invalidate_asset_views()
		await _wait(0.3)
		_ok(not _ed.index.has("voice", vid), "临时语音已清理")

	_sec("变量清单在侧栏")
	_ok(_ed._var_box != null, "侧栏有变量清单容器")
	var vrows: int = _ed._var_box.get_child_count()
	_ok(vrows > 0, "侧栏列出了变量（%d 条）" % vrows)
	# 有问题的要排在前面。
	# ⚠️ 先把要用的信息**抄出来**再断言 —— `_var_box` 会被 `_push_issues()` 整批
	# 重建（旧子节点 queue_free 后当帧仍在树上），跨 await 去取 `get_child(0)`
	# 会撞上「Trying to cast a freed object」。
	var first_text := ""
	var first_marked := false
	if vrows > 0:
		var first := _ed._var_box.get_child(0) as Button
		if first != null:
			first_text = first.text
			first_marked = first.text.begins_with("✕") or first.text.begins_with("⚠")
	_ok(first_marked, "⚠ 有问题的变量排在清单最前面（实得 %s）" % first_text)

	# demo 剧本里 rhythm_qte_cleared 是「读了但没人设过」——应该标 ✕
	var has_err := false
	var target: Button = null
	for c in _ed._var_box.get_children():
		var b2 := c as Button
		if b2 != null and b2.text.contains("rhythm_qte_cleared"):
			has_err = b2.text.begins_with("✕")
			target = b2
	_ok(has_err, "⚠ 真问题（rhythm_qte_cleared 只读不写）在侧栏被标出来")

	# 点一条要能跳到剧本里
	var jumped := false
	if target != null:
		target.pressed.emit()
		await _wait(0.6)
		jumped = _ed.doc.text_at(_ed.caret_line).contains("rhythm_qte_cleared")
	_ok(jumped, "点一条变量跳到它在剧本里的位置（第 %d 行）" % _ed.caret_line)

	_sec("破坏性操作不许碰素材根目录")
	var apx: Control = _ed._pages.get("asset")
	if apx == null:
		_ed.show_page("asset")
		await _wait(0.5)
		apx = _ed._pages.get("asset")
	# ⚠️ 语音的「未分组」组名是**空串**。只要有一条路径把空串当组名传下去，
	# `_voice_dir_of("")` 就是素材根目录本身 —— 删一次就把整个分类目录清空。
	# 这道闸挡的就是它（真实发生过一次整目录被抹平）。
	_ok(not apx._safe_target("res://assets/audio/voice/"), "语音根目录被挡住")
	_ok(not apx._safe_target("res://assets/sprites/"), "立绘根目录被挡住")
	_ok(not apx._safe_target(""), "空路径被挡住")
	_ok(apx._safe_target("res://assets/audio/voice/alice/"), "组目录放行")
	_ok(apx._safe_target("res://assets/audio/voice/alice/line_01.ogg"), "组内文件放行")

	# 光测纯函数不够 —— 得验「闸门真的接在删除函数上」。
	# ⚠️ 但那次调用的失败后果是**把真素材删光**，所以先把整个语音目录挪走，
	# 用空目录 + 哨兵来验；无论结果如何都还原回去。
	var voice_abs := ProjectSettings.globalize_path("res://assets/audio/voice/")
	# ⚠️ 备份目录必须和项目**同盘** —— `DirAccess.rename_absolute` 跨盘会失败
	# （`user://` 在 C:，项目在 D:，实测报不出错但返回非 OK）
	var bak_abs := ProjectSettings.globalize_path("res://tools/editor/tests/__voice_bak/")
	_remove_dir("res://tools/editor/tests/__voice_bak/")
	var moved := DirAccess.rename_absolute(voice_abs, bak_abs) == OK
	_ok(moved, "（测试准备）把真语音目录挪到一边")
	if moved:
		DirAccess.make_dir_recursive_absolute(voice_abs)
		_write("res://assets/audio/voice/__sentinel.txt", "sentinel")
		apx._delete_dir_recursive("res://assets/audio/voice/")
		apx._record_dir("res://assets/audio/voice/")
		apx._delete_voice_role("")
		await _wait(0.3)
		_ok(FileAccess.file_exists("res://assets/audio/voice/__sentinel.txt"),
			"⚠ 传素材根目录给删除函数会被挡住（哨兵还在）")
		# 还原
		_remove_file("res://assets/audio/voice/__sentinel.txt")
		DirAccess.remove_absolute(voice_abs)
		_ok(DirAccess.rename_absolute(bak_abs, voice_abs) == OK, "（测试收尾）语音目录还原")
		_ed.index.scan()
		await _wait(0.3)

	# 清理
	_ed._open(ScriptPaths.entry())
	await _wait(0.6)
	_remove_file(_tbl_path)
	_remove_dir(dir_path)
	ScriptStats.clear_cache()
	_ed.index.scan()
	_ed._refresh_index_summary()
	_ed.invalidate_asset_views()
	_ed._refresh_files()
	await _wait(0.5)
	_ok(not FileAccess.file_exists(_tbl_path), "临时剧本已清理")
	_ok(not _ed.index.char_ids().has(TMP_CHAR2), "临时角色已清理")


## 表格里任何一个下拉里有没有这一项（用来验「新素材有没有进旧行的下拉」）
func _char_option_has(table: Control, item_text: String) -> bool:
	for d in _all_descendants(table._body):
		if d is OptionButton:
			var o := d as OptionButton
			for i in o.item_count:
				if o.get_item_text(i) == item_text:
					return true
	return false


## 素材网格里有没有代表某个 id 的卡片（卡片上存了 asset_id meta）
func _grid_has_card(ap: Control, id: String) -> bool:
	for c in ap._grid.get_children():
		if c.has_meta("asset_id") and String(c.get_meta("asset_id")) == id:
			return true
	return false


## 合集网格里有没有代表某个 id 的卡片
func _gallery_has_card(ap: Control, id: String) -> bool:
	for c in ap._gallery_grid.get_children():
		if c.has_meta("asset_id") and String(c.get_meta("asset_id")) == id:
			return true
	return false


## 语音页里代表某个角色的卡片
func _role_card(ap: Control, group: String) -> Button:
	for c in ap._grid.get_children():
		if c is Button and c.has_meta("voice_role") \
				and String(c.get_meta("voice_role")) == group:
			return c as Button
	return null


## 合集网格里代表某个 id 的卡片节点
func _gallery_card_of(ap: Control, id: String) -> Control:
	for c in ap._gallery_grid.get_children():
		if c.has_meta("asset_id") and String(c.get_meta("asset_id")) == id:
			return c as Control
	return null


## 卡片里那个文字包含 `text` 的 Label（用来量它的实际宽度）
func _label_containing(node: Node, text: String) -> Label:
	for d in _all_descendants(node):
		if d is Label and (d as Label).text.contains(text):
			return d as Label
	return null


# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------

func _file_button_exists(name: String) -> bool:
	for c in _ed._file_list.get_children():
		for d in _all_descendants(c):
			if d is Button and not (d is OptionButton) and (d as Button).text == name:
				return true
	return false


## 递归列出节点及其所有后代
func _all_descendants(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		out.append(child)
		out.append_array(_all_descendants(child))
	return out


func _last_child(node: Node) -> Node:
	var n := node.get_child_count()
	return node.get_child(n - 1) if n > 0 else null


func _has_label_text(node: Node, text: String) -> bool:
	if node == null:
		return false
	for d in _all_descendants(node):
		if d is Label and (d as Label).text == text:
			return true
	return false


## 在网格里按名字标签找回那张卡片
func _find_card_by_label(grid: Node, text: String) -> Control:
	for c in grid.get_children():
		if c is Control and _has_label_text(c, text):
			return c
	return null


## 只在直接子节点里找按钮
func _find_direct_button(node: Node, text: String) -> Button:
	for c in node.get_children():
		if c is Button and not (c is OptionButton) and (c as Button).text == text:
			return c
	return null


## 卡片右上角的操作徽章。它们在卡片里的一个 HBoxContainer 里，
## 所以**要递归找**，不能只看直接子节点。
func _find_badge(card: Node, glyph: String) -> Button:
	for d in _all_descendants(card):
		if d is Button and (d as Button).text == glyph:
			return d
	return null


## 找一张真实背景素材（跳过测试自己造的 __tmp_* 文件）当复制源。
## ⚠️ 必须用**刚重扫过**的索引 —— 拿删掉之前的旧索引会选到一个已经不存在的文件，
## `get_file_as_bytes` 返回空、复制静默失败，后面全跟着挂。
func _pick_bg_source() -> String:
	for id in _ed.index.ids("bg"):
		var sid := String(id)
		if sid.begins_with("__tmp"):
			continue
		return String(_ed.index.get_entry("bg", sid).get("path", ""))
	return ""


func _first_button(node: Node) -> Button:
	for c in node.get_children():
		if c is Button and not (c is OptionButton) and not (c is CheckButton):
			return c
	return null


func _find_button(node: Node, text: String) -> Button:
	for c in node.get_children():
		if c is Button and not (c is OptionButton) and (c as Button).text == text:
			return c
		var r := _find_button(c, text)
		if r != null:
			return r
	return null


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	if bytes.is_empty():
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(bytes)
	f.close()


func _file_bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path)


## 删一个文件（连 Godot 可能生成的 .import / .uid 一起）
func _remove_file(path: String) -> void:
	for p in [path, path + ".import", path + ".uid"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _remove_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	var d := DirAccess.open(abs)
	if d != null:
		for f in d.get_files():
			DirAccess.remove_absolute(abs + String(f))
		for sub in d.get_directories():
			_remove_dir(path + String(sub) + "/")
	DirAccess.remove_absolute(abs)


# ---------------------------------------------------------------------------

func _finish() -> void:
	print("")
	if _fail == 0:
		print("=== ALL OK  %d 项 ===" % _pass)
		get_tree().quit(0)
	else:
		print("=== FAILED  %d 通过 / %d 失败 ===" % [_pass, _fail])
		get_tree().quit(1)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  OK    %s" % msg)
	else:
		_fail += 1
		print("  FAIL  %s" % msg)


func _sec(t: String) -> void:
	print("\n-- %s --" % t)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
