extends Control

## 素材管理
##
## 四件事：
##   1. **浏览** 7 类素材（缩略图 + 尺寸/时长）
##   2. **缺失看板** —— 剧本引用了但文件不存在（复用 ScriptAudit.missing_assets）
##   3. **未使用反查** —— 有文件但剧本从没引用（ScriptAudit 不做这一面）
##   4. **导入** —— 选文件 → 规范化命名 → 复制到对应目录
##
## 关于「导入后要不要跑 --import」：Godot 的资源导入必须在编辑器进程里做，
## 运行中的工具窗口无法自行触发。但**预览不需要等它** —— 缩略图走
## `Image.load_from_file()` 直读源文件，所以刚复制进来的素材立刻可见。
## 只有在**运行游戏**时才需要 .import，界面会明确提示这一点。

const EdTheme = preload("res://tools/editor/ed_theme.gd")
const ProjectIndex = preload("res://tools/editor/core/project_index.gd")
const AssetRefs = preload("res://tools/editor/core/asset_refs.gd")
const AssetUndo = preload("res://tools/editor/core/asset_undo.gd")
const ScriptStats = preload("res://scripts/core/script_stats.gd")
const ScriptPaths = preload("res://scripts/core/script_paths.gd")

const THUMB_H := 74
const CARD_W := 168
const COLS := 5

var _ed: Control
var _kind := "bg"
var _search: LineEdit
var _grid: GridContainer
var _grid_scroll: ScrollContainer
var _side: VBoxContainer
var _stat: Label
var _detail: VBoxContainer
var _file_dialog: FileDialog
var _gallery: PanelContainer
var _gallery_grid: GridContainer
var _gallery_title: Label
var _gallery_hint: Label
var _new_char_dialog: ConfirmationDialog
var _new_char_name: LineEdit
## 这个「新建」对话框当前在建哪一类：`char` 或 `voice`（语音的分组目录）。
## 两者共用同一个对话框 —— 差别只有标题、说明和建成之后干什么。
var _new_group_kind := "char"
var _new_group_desc: Label
var _confirm: ConfirmationDialog
var _pending_delete := Callable()

## 重命名对话框（素材 / 角色 / 表情共用）。
## `_rename_ctx` 描述「在改什么」，见 `_ask_rename_asset` / `_ask_rename_expr`。
var _rename_dialog: ConfirmationDialog
var _rename_name: LineEdit
var _rename_ctx: Dictionary = {}

## 导入目标。`flat` = 当前类别的平铺目录（bg / cg / 音效…）；
## `char_expr` = 某个角色的立绘目录 `assets/sprites/<角色>/`。
## 立绘是两级结构，不能和别的类别共用一条「复制到 KIND_DIRS[kind]」的路径。
var _import_mode := "flat"
var _import_kind := "bg"
var _import_char := ""
var _import_group := ""

## 当前打开的立绘合集属于哪个角色（导入 / 删除后要按它刷新）
## 合集当前展示的「组」：立绘 = 角色，语音 = 角色。
## 两者共用同一套两级浏览（网格页看组卡片 → 双击进合集看组内条目）。
var _gallery_kind := ""
var _gallery_group := ""

## 素材操作的撤销栈（重命名 / 删除都进栈）
var _undo = AssetUndo.new()
var _btn_undo: Button

var _thumb_cache: Dictionary = {}


func setup(ed: Control) -> void:
	_ed = ed
	_build()
	# 拖拽导入：Godot 的拖放信号在 **Window** 上（Control 没有 per-node 的拖放目标），
	# 所以这里只能收全窗口的，再由 `_on_files_dropped` 自己判断该不该处理
	# （页面没显示 / 拖到别的页面上就忽略）。
	get_window().files_dropped.connect(_on_files_dropped)


func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# --- 工具条 ---
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_PANEL, 0, 10, 6, EdTheme.BORDER, 1))
	root.add_child(bar)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	bar.add_child(h)

	_stat = EdTheme.label("", EdTheme.FS_SMALL, EdTheme.TEXT_DIM)
	h.add_child(_stat)
	h.add_child(_vsep())

	for kind in ProjectIndex.KINDS:
		var b := EdTheme.chip(String(ProjectIndex.KIND_LABELS.get(kind, kind)))
		var k := String(kind)
		b.pressed.connect(func() -> void:
			_kind = k
			rebuild())
		h.add_child(b)
		_chips[k] = b

	h.add_child(EdTheme.hfill())

	# 撤销：素材操作唯一会「弄丢东西」的地方，所以给一个显式的按钮
	# （不占 Ctrl+Z —— 那个键在别的页面归 ScriptDoc / CodeEdit）
	_btn_undo = EdTheme.chip("↶ 撤销")
	_btn_undo.pressed.connect(_do_undo)
	h.add_child(_btn_undo)

	_search = LineEdit.new()
	_search.placeholder_text = "过滤 id…"
	_search.custom_minimum_size = Vector2(160, 0)
	EdTheme.style_line_edit(_search)
	_search.text_changed.connect(func(_t: String) -> void: _refresh_grid())
	h.add_child(_search)

	# ⚠️ 这里曾经还有「导入素材 / 重新扫描 / 新建角色」三个按钮。
	# 它们和网格末尾的「+」卡片、顶栏的「重新扫描」是同一件事，
	# 留着只会让人不知道该点哪个 —— 已按用户要求删掉。

	# --- 主体 ---
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(scroll)
	_grid_scroll = scroll

	_grid = GridContainer.new()
	_grid.columns = COLS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_grid)

	var side_scroll := ScrollContainer.new()
	side_scroll.custom_minimum_size = Vector2(300, 0)
	side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(side_scroll)

	_side = VBoxContainer.new()
	_side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_side.add_theme_constant_override("separation", 4)
	side_scroll.add_child(_side)

	# 导入对话框
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.title = "选择要导入的素材"
	add_child(_file_dialog)
	_file_dialog.files_selected.connect(_on_files_selected)

	_build_gallery()
	_build_new_char_dialog()
	_build_confirm()
	_build_rename_dialog()


## 删除确认。**所有删除都走这一个** —— 素材是作者的手工劳动，
## 误删一张 4K 背景比多点一次确认贵得多。待执行的动作放在 `_pending_delete` 里，
## 这样「删一张图」和「删一个角色目录」可以共用同一个对话框。
func _build_confirm() -> void:
	_confirm = ConfirmationDialog.new()
	_confirm.title = "删除素材"
	_confirm.ok_button_text = "删除"
	_confirm.cancel_button_text = "取消"
	_confirm.confirmed.connect(func() -> void:
		_confirm.hide()
		var cb := _pending_delete
		_pending_delete = Callable()
		if cb.is_valid():
			cb.call())
	add_child(_confirm)


## 重命名对话框。素材 / 角色 / 表情共用 —— 三者的输入都是「一个新名字」，
## 差别只在 `_rename_ctx` 与 `dialog_text` 里的提示。
func _build_rename_dialog() -> void:
	_rename_dialog = ConfirmationDialog.new()
	_rename_dialog.title = "重命名"
	_rename_dialog.ok_button_text = "重命名"
	_rename_dialog.cancel_button_text = "取消"
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_rename_name = LineEdit.new()
	_rename_name.placeholder_text = "新的 id"
	_rename_name.custom_minimum_size = Vector2(320, 0)
	EdTheme.style_line_edit(_rename_name)
	v.add_child(_rename_name)
	v.add_child(EdTheme.label("只能用 小写字母 / 数字 / 下划线；已存在会拒绝",
		EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))
	_rename_dialog.add_child(v)
	_rename_dialog.confirmed.connect(_do_rename_asset)
	add_child(_rename_dialog)


# ---------------------------------------------------------------------------
# 立绘合集（点角色卡片打开）
# ---------------------------------------------------------------------------

## 盖住整页的立绘合集。
##
## 侧栏的「详情」只能列名字，而立绘是要**看**的 —— 一个角色有几个表情、
## 哪些是动态的，铺成缩略图一眼就清楚。所以点角色卡片时除了填侧栏，
## 还把这层打开。
func _build_gallery() -> void:
	_gallery = PanelContainer.new()
	_gallery.set_anchors_preset(Control.PRESET_FULL_RECT)
	_gallery.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG, 0, 0, 0, EdTheme.BORDER_HI, 1))
	_gallery.visible = false
	add_child(_gallery)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_gallery.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	_gallery_title = EdTheme.label("", EdTheme.FS_TITLE, EdTheme.TEXT)
	head.add_child(_gallery_title)
	head.add_child(EdTheme.hfill())
	var btn_close := EdTheme.chip("关闭")
	btn_close.pressed.connect(func() -> void: _gallery.visible = false)
	head.add_child(btn_close)
	v.add_child(head)

	# 空状态的说明行。
	#
	# ⚠️ **必须摆在网格外面**，不能 `add_child` 进 `_gallery_grid` ——
	# GridContainer 会给它一个「最小宽度」的格子，而带 autowrap 的 Label 最小宽度是 0，
	# 于是它被压成一条竖线、**一个字一行**（用户报的「界面还是长」就是它）。
	# 放在网格上面，它是整行宽、正常换行的一段话。
	_gallery_hint = EdTheme.label("", EdTheme.FS_SMALL, EdTheme.WARN)
	_gallery_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_gallery_hint.visible = false
	v.add_child(_gallery_hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)

	_gallery_grid = GridContainer.new()
	_gallery_grid.columns = 6
	_gallery_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gallery_grid.add_theme_constant_override("h_separation", 10)
	_gallery_grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_gallery_grid)


func _open_char_gallery(cid: String) -> void:
	_open_gallery("char", cid)


## 打开某个「组」的合集。
##
## 立绘的组 = 角色（组内是表情），语音的组 = 角色（组内是语音）——
## 两级结构共用这一套：网格页看组卡片，双击进来就是组内条目。
## 组内条目一律走 `_entry_card`，末尾挂一张「导入到本组」的卡片。
func _open_gallery(kind: String, group: String) -> void:
	if _gallery == null:
		return
	for c in _gallery_grid.get_children():
		_gallery_grid.remove_child(c)
		c.queue_free()

	_gallery_kind = kind
	_gallery_group = group
	if _gallery_hint != null:
		_gallery_hint.visible = false
		_gallery_hint.text = ""
	# 语音条目是紧凑行，一行摆**两个**（卡片宽一点，台词名才不会被时长挤没）；
	# 立绘有缩略图，一行摆六个
	_gallery_grid.columns = 2 if kind == "voice" else 6
	if kind == "char":
		_fill_char_gallery(group)
	else:
		_fill_voice_gallery(group)

	_gallery_grid.add_child(_add_card(kind, group))
	_gallery.visible = true


func _fill_char_gallery(cid: String) -> void:
	var entry: Dictionary = _ed.index.get_entry("char", cid)
	if entry.is_empty():
		_ed._notice_flash("%s 不在素材索引里" % cid, EdTheme.WARN)
		_gallery.visible = false
		return
	var exprs: Dictionary = entry.get("exprs", {})
	var anim: Dictionary = entry.get("animated", {})
	_gallery_title.text = "立绘合集 · %s（静态 %d · 动态 %d）" % [
		cid, exprs.size(), anim.size()]

	var names: Array = exprs.keys()
	names.sort()
	for k in names:
		var d: Dictionary = exprs[k]
		_gallery_grid.add_child(_expr_card(
			cid, String(k), String(k), String(d.get("path", "")), false))

	var anames: Array = anim.keys()
	anames.sort()
	for k in anames:
		var d2: Dictionary = anim[k]
		# 动态立绘的 path 是**目录**，缩略图要用第一帧
		var frames: Array = d2.get("frames", [])
		var first := String(frames[0]) if frames.size() > 0 else ""
		_gallery_grid.add_child(_expr_card(cid,
			"%s（%d 帧）" % [String(k), int(d2.get("frame_count", 0))],
			String(k), String(d2.get("path", "")), true))

	if _gallery_grid.get_child_count() == 0:
		_gallery_hint.text = ("这个角色还没有任何立绘。往 %s 里放 <表情>.png，"
			+ "或建一个 <表情>/ 目录放帧序列。") % String(entry.get("path", ""))
		_gallery_hint.visible = true


## 语音合集：某个角色目录下的全部语音。
##
## 语音没有缩略图，卡片上显示的是「叶子名 + 时长」—— 作者对着一堆
## `alice/line01.ogg` 最需要知道的就是「哪条还没配 / 哪条特别长」。
func _fill_voice_gallery(group: String) -> void:
	var ids := _voice_ids_of(group)
	_gallery_title.text = "语音合集 · %s（%d 条 · %s）" % [
		_voice_group_label(group), ids.size(), _fmt_duration(_voice_seconds_of(ids))]

	for id in ids:
		_gallery_grid.add_child(_voice_card(id))

	if ids.is_empty():
		_gallery_hint.text = ("这个角色还没有语音。往 %s 里放 <台词>.ogg（文件名就是 id），"
			+ "或用下面的「＋」导入 —— 导入时会自动建目录。") % _voice_dir_of(group)
		_gallery_hint.visible = true


## 某个组里的全部语音 id（按 id 排序）
func _voice_ids_of(group: String) -> PackedStringArray:
	var out := PackedStringArray()
	for id in _ed.index.ids("voice"):
		var sid := String(id)
		var slash := sid.find("/")
		var g := "" if slash <= 0 else sid.substr(0, slash)
		if g == group:
			out.append(sid)
	return out


func _voice_dir_of(group: String) -> String:
	# 走索引 —— 空目录也算「已建」，路径由 `_scan_grouped` 记下来
	return String(_ed.index.group_dir("voice", group))


func _voice_group_label(group: String) -> String:
	return "未分组" if group.is_empty() else group


func _voice_seconds_of(ids: PackedStringArray) -> float:
	var t := 0.0
	for id in ids:
		var e: Dictionary = _ed.index.get_entry("voice", String(id))
		t += float(e.get("duration", 0.0))
	return t


static func _fmt_duration(sec: float) -> String:
	var s := int(round(sec))
	if s < 60:
		return "%d 秒" % s
	return "%d 分 %02d 秒" % [s / 60, s % 60]


## 紧凑时长（`3:31`）。**紧凑行卡片里用这个** ——
## 「3 分 31 秒」比它宽 40px，而那条卡片总共才 168px 起，名字会被挤没。
static func _fmt_clock(sec: float) -> String:
	var s := int(round(sec))
	return "%d:%02d" % [s / 60, s % 60]


## 语音卡片：**一行一条的紧凑卡片**（没有缩略图，用大卡片会留一大片空白）。
##
## 内容 = ♪ + 叶子名 + 时长 + ✎/✕。整条可点 → 右侧详情。
func _voice_card(id: String) -> Control:
	var entry: Dictionary = _ed.index.get_entry("voice", id)
	var path := String(entry.get("path", ""))
	var leaf := id.substr(id.find("/") + 1) if id.contains("/") else id
	var dur := _fmt_clock(float(entry.get("duration", 0.0)))

	var card := Button.new()
	card.custom_minimum_size = Vector2(CARD_W, 30)
	card.add_theme_stylebox_override("normal",
		EdTheme.sb(EdTheme.BG_ELEV, 6, 6, 3, EdTheme.BORDER, 1))
	card.add_theme_stylebox_override("hover",
		EdTheme.sb(EdTheme.BG_HOVER, 6, 6, 3, EdTheme.ACCENT, 1))
	card.add_theme_stylebox_override("pressed",
		EdTheme.sb(EdTheme.BG_ACTIVE, 6, 6, 3, EdTheme.ACCENT, 1))
	card.tooltip_text = "%s\n时长 %s\n剧本里写：voice %s" % [path, dur, id]
	card.pressed.connect(func() -> void: _show_detail("voice", id))
	_tag_card(card, "voice", id)

	# 和立绘卡片同一个坑：Container 会把子节点撑满，所以垫一层 overlay 摆内容
	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_PASS
	# ⚠️ overlay 必须自己铺满卡片—— Button / PanelContainer 都不是 Container，
	# 不给它 anchors 的话它就是 0×0，里面那些 `SIZE_EXPAND_FILL`
	# + `clip_text` 的 Label 会被压成 0 宽、什么都看不见
	# （语音卡片的台词名就这么消失过）。
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	card.add_child(overlay)

	var h := HBoxContainer.new()
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 6
	h.offset_right = -4
	h.add_theme_constant_override("separation", 6)
	overlay.add_child(h)

	var icon := EdTheme.label("♪", EdTheme.FS_SMALL, EdTheme.ACCENT)
	icon.custom_minimum_size = Vector2(14, 0)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(icon)

	var name_l := EdTheme.mono_label(leaf, EdTheme.FS_SMALL, EdTheme.TEXT)
	name_l.clip_text = true
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_l.tooltip_text = id
	h.add_child(name_l)

	var dur_l := EdTheme.label(dur, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	dur_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(dur_l)

	h.add_child(_badge("✎", "重命名", EdTheme.ACCENT,
		func() -> void: _ask_rename_asset("voice", id)))
	h.add_child(_badge("✕", "删除", EdTheme.ERR,
		func() -> void: _ask_delete_asset("voice", id)))
	return card


## 语音页的「角色卡片」。和立绘页的角色卡片是同一层东西，
## 只是没有缩略图（换成 ♪ + 条数 + 总时长），而且**未建目录的角色也列出来**。
##
## `exists = false` 表示「立绘里有这个角色，但还没有语音目录」——
## 用暗色 + 虚线边标出来，双击进去导语音时会自动建目录。
## 不列出来的话，作者没法知道还有谁没配音（用户反馈）。
func _voice_role_card(group: String, exists: bool = true) -> Control:
	var ids := _voice_ids_of(group)
	var label := _voice_group_label(group)
	var secs := _voice_seconds_of(ids)

	var card := Button.new()
	card.custom_minimum_size = Vector2(CARD_W, 46)
	card.add_theme_stylebox_override("normal", EdTheme.sb(
		EdTheme.BG_ELEV if exists else EdTheme.BG, 6, 6, 3,
		EdTheme.BORDER if exists else EdTheme.BORDER_HI, 1))
	card.add_theme_stylebox_override("hover",
		EdTheme.sb(EdTheme.BG_HOVER, 6, 6, 3, EdTheme.ACCENT, 1))
	card.add_theme_stylebox_override("pressed",
		EdTheme.sb(EdTheme.BG_ACTIVE, 6, 6, 3, EdTheme.ACCENT, 1))
	card.tooltip_text = "%s\n%s\n单击看详情 · 双击进入语音合集" % [
		_voice_dir_of(group),
		"%d 条语音 · %s" % [ids.size(), _fmt_duration(secs)] if exists
			else "还没有语音目录（进去导语音时会自动建）"]

	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_PASS
	# ⚠️ overlay 必须自己铺满卡片—— Button / PanelContainer 都不是 Container，
	# 不给它 anchors 的话它就是 0×0，里面那些 `SIZE_EXPAND_FILL`
	# + `clip_text` 的 Label 会被压成 0 宽、什么都看不见
	# （语音卡片的台词名就这么消失过）。
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	card.add_child(overlay)

	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 8
	v.offset_right = -52
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 1)
	overlay.add_child(v)

	var name_l := EdTheme.mono_label("♪ %s" % label, EdTheme.FS_SMALL,
		EdTheme.TEXT if exists else EdTheme.TEXT_DIM)
	name_l.clip_text = true
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(name_l)

	var meta := EdTheme.label(
		"%d 条 · %s" % [ids.size(), _fmt_duration(secs)] if exists
			else "还没有语音目录",
		EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	meta.clip_text = true
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(meta)

	card.pressed.connect(func() -> void: _show_detail("voice_role", group))
	card.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton:
			var mb := e as InputEventMouseButton
			if mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT:
				_open_gallery("voice", group))
	overlay.add_child(_card_actions(
		func() -> void: _ask_rename_voice_role(group),
		func() -> void: _ask_delete_voice_role(group)))
	# 拖拽导入要认得出「拖到了哪个角色上」
	card.set_meta("voice_role", group)
	return card


## 立绘合集里的一张卡片（静态 / 动态立绘）。
##
## `label` 是显示用的（动态立绘会带「（N 帧）」后缀），`expr` 是**真正的表情 id** ——
## 重命名 / 删除必须用后者，拿显示文本去改文件名会改出一个带「（12 帧）」的文件名。
func _expr_card(cid: String, label: String, expr: String, path: String,
		animated: bool) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(CARD_W, THUMB_H + 46)
	card.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_ELEV, 8, 6, 6, EdTheme.BORDER, 1))
	card.tooltip_text = "%s\n%s" % [path, "帧序列（动态立绘）" if animated else "静态立绘"]

	# ⚠️ **PanelContainer 会把每一个子节点都撑满内容区**（Container 的排版行为），
	# 所以徽章不能直接挂在 card 上 —— 实测它被拉成 156×109 的整卡大小，
	# 既看不见也把整张卡变成了操作热区。
	# 中间垫一层普通 Control 当「锚点坐标系」：card 只放它一个（撑满内容区），
	# 里面的 VBox 和徽章各按各的锚点摆。
	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_PASS
	# ⚠️ overlay 必须自己铺满卡片—— Button / PanelContainer 都不是 Container，
	# 不给它 anchors 的话它就是 0×0，里面那些 `SIZE_EXPAND_FILL`
	# + `clip_text` 的 Label 会被压成 0 宽、什么都看不见
	# （语音卡片的台词名就这么消失过）。
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	card.add_child(overlay)

	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 3)
	overlay.add_child(v)

	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(0, THUMB_H)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb.texture = _thumbnail(path)
	v.add_child(thumb)

	var name_l := EdTheme.mono_label(label, EdTheme.FS_SMALL, EdTheme.TEXT)
	name_l.clip_text = true
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(name_l)
	var kind_l := EdTheme.label("动态 · 帧序列" if animated else "静态",
		EdTheme.FS_SMALL, EdTheme.ACCENT if animated else EdTheme.TEXT_FAINT)
	kind_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(kind_l)

	overlay.add_child(_card_actions(
		func() -> void: _ask_rename_expr(cid, expr, path, animated),
		func() -> void: _ask_delete_expr(cid, expr, path, animated)))
	return card


# ---------------------------------------------------------------------------
# 新建角色
# ---------------------------------------------------------------------------

func _build_new_char_dialog() -> void:
	_new_char_dialog = ConfirmationDialog.new()
	_new_char_dialog.ok_button_text = "创建"
	_new_char_dialog.cancel_button_text = "取消"
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_new_group_desc = EdTheme.label("", EdTheme.FS_SMALL, EdTheme.TEXT_DIM)
	v.add_child(_new_group_desc)
	_new_char_name = LineEdit.new()
	_new_char_name.custom_minimum_size = Vector2(300, 0)
	EdTheme.style_line_edit(_new_char_name)
	v.add_child(_new_char_name)
	v.add_child(EdTheme.label("只能用 小写字母 / 数字 / 下划线；已存在会拒绝",
		EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))
	_new_char_dialog.add_child(v)
	# 标题与说明按类别现设 —— 建的是立绘角色还是语音分组，这里是唯一的分岔点
	_new_char_dialog.confirmed.connect(_on_new_group_confirmed)
	add_child(_new_char_dialog)


func _on_new_group_confirmed() -> void:
	if _new_group_kind == "voice":
		_create_voice_role()
	else:
		_create_char()


func _open_new_char_dialog() -> void:
	_open_new_group_dialog("char")


## 语音页的「新建角色」—— 这就是「语音的分类 / 子文件夹」入口。
##
## ⚠️ 之前**没有这个入口**：语音页只在「磁盘上已经有子目录」时才显示角色卡片，
## 于是新项目里根本没有办法建第一个分类（用户反馈「我没见到分类」）。
func _open_new_role_dialog() -> void:
	_open_new_group_dialog("voice")


func _open_new_group_dialog(kind: String) -> void:
	_new_group_kind = kind
	_new_char_name.text = ""
	if kind == "voice":
		_new_char_dialog.title = "新建角色（语音分类）"
		_new_group_desc.text = ("会建出 assets/audio/voice/<角色 id>/ 目录。\n"
			+ "建好之后在里面导语音，剧本里写 voice <角色 id>/<文件名>。")
		_new_char_name.placeholder_text = "例如 alice"
	else:
		_new_char_dialog.title = "新建角色"
		_new_group_desc.text = "会建出 assets/sprites/<角色 id>/ 目录"
		_new_char_name.placeholder_text = "例如 carol"
	_new_char_dialog.popup_centered()
	_new_char_name.call_deferred("grab_focus")


## 建一个语音角色目录。
##
## 和立绘不同，**不放占位文件** —— 语音没有「默认表情」那种东西，
## 塞一段假音频进项目只会让人以为配音已经做好了。
func _create_voice_role() -> void:
	var gid := _normalize_id(_new_char_name.text)
	if gid.is_empty():
		_ed._notice_flash("角色 id 只能用 小写字母 / 数字 / 下划线", EdTheme.ERR)
		return
	var dir_path := _voice_dir_of(gid)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path)):
		_ed._notice_flash("assets/audio/voice/%s/ 已存在" % gid, EdTheme.ERR)
		return
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path)) != OK:
		_ed._notice_flash("建目录失败：%s" % dir_path, EdTheme.ERR)
		return

	_after_asset_change()
	# 直接进这个角色的合集 —— 建完就该往里导语音，不用再找一遍
	_kind = "voice"
	rebuild()
	_open_gallery("voice", gid)
	_ed._notice_flash("已建 %s —— 用合集末尾的「＋」把语音导进来" % dir_path, EdTheme.OK)


## 新建一个角色。
##
## **会顺手放一张 `normal.png` 占位**，从已有角色里复制。两个原因：
##
##   1. `normal` 是**默认表情** —— 剧本写 `show <角色>`（不带 `expr=`）时取的就是它。
##      不放的话，游戏跑到 `show 新角色` 会掉进 `PlaceholderAssets`，
##      画面里蹦出一个程序化生成的火柴人，而不是「这个人还没画」。
##   2. 新角色的卡片立刻有缩略图可看，不是一张空白卡片。
##
## ⚠️ 注意**空目录本身是会出现在索引里的**（`_scan_chars` 给每个目录都建条目，
## 只是 `exists = false`），所以「不放就看不见这个角色」是错的 ——
## 真正的代价是上面两条。占位图记得换成自己的。
func _create_char() -> void:
	var cid := _normalize_id(_new_char_name.text)
	if cid.is_empty():
		_ed._notice_flash("角色 id 只能用 小写字母 / 数字 / 下划线", EdTheme.ERR)
		return
	var dir_path := String(ProjectIndex.KIND_DIRS["char"]) + cid + "/"
	var abs_dir := ProjectSettings.globalize_path(dir_path)
	if DirAccess.dir_exists_absolute(abs_dir):
		_ed._notice_flash("assets/sprites/%s/ 已存在" % cid, EdTheme.ERR)
		return
	if DirAccess.make_dir_recursive_absolute(abs_dir) != OK:
		_ed._notice_flash("建目录失败：%s" % dir_path, EdTheme.ERR)
		return

	var placeholder := ""
	var src_char := ""
	for other in _ed.index.char_ids():
		var e: Dictionary = _ed.index.get_entry("char", String(other))
		var exprs: Dictionary = e.get("exprs", {})
		if exprs.has("normal"):
			placeholder = String((exprs["normal"] as Dictionary).get("path", ""))
			src_char = String(other)
			break

	var copied := false
	if not placeholder.is_empty():
		var bytes := FileAccess.get_file_as_bytes(placeholder)
		if not bytes.is_empty():
			var f := FileAccess.open(dir_path + "normal.png", FileAccess.WRITE)
			if f != null:
				f.store_buffer(bytes)
				f.close()
				copied = true

	_kind = "char"
	_after_asset_change()
	_open_char_gallery(cid)
	if copied:
		_ed._notice_flash("已新建角色 %s（先用 %s/normal.png 占位，记得换成自己的立绘）"
			% [cid, src_char], EdTheme.OK)
	else:
		_ed._notice_flash("已建目录 assets/sprites/%s/ —— 放 <表情>.png 进去就会出现" % cid,
			EdTheme.WARN)


var _chips: Dictionary = {}


func _vsep() -> Control:
	var s := VSeparator.new()
	s.add_theme_stylebox_override("separator", EdTheme.sb(EdTheme.BORDER, 0, 0, 0))
	s.custom_minimum_size = Vector2(1, 0)
	return s


func on_shown() -> void:
	rebuild()


# ---------------------------------------------------------------------------
# 重建
# ---------------------------------------------------------------------------

func rebuild() -> void:
	if _ed == null or _grid == null:
		return
	for k in _chips.keys():
		EdTheme.style_chip(_chips[k] as Button, String(k) == _kind)
	_refresh_grid()
	_refresh_side()
	_refresh_undo_button()


func _refresh_undo_button() -> void:
	if _btn_undo == null:
		return
	var can := _undo.can_undo()
	_btn_undo.disabled = not can
	_btn_undo.tooltip_text = ("撤销：%s" % _undo.peek_label()) if can \
		else "没有可撤销的素材操作"
	EdTheme.style_chip(_btn_undo, false)
	_btn_undo.add_theme_color_override("font_color",
		EdTheme.TEXT_DIM if can else EdTheme.TEXT_FAINT)


## 撤销最近一次素材操作。
##
## 步骤是**倒着**执行的（先撤引用改写，再把文件挪回来），
## 所以中途不会出现「文件已经挪回去、剧本还指着新名字」的窗口期。
func _do_undo() -> void:
	if not _undo.can_undo():
		_ed._notice_flash("没有可撤销的素材操作", EdTheme.TEXT_FAINT)
		return
	var label := _undo.undo()
	# 剧本可能被还原过 → 让编辑器手里的文档跟上
	if _ed.doc != null and not _ed.doc.path.is_empty():
		_ed._reload_from_disk("已撤销素材操作：%s" % label)
	_gallery.visible = false
	_after_asset_change()
	_ed._notice_flash("已撤销：%s" % label, EdTheme.OK)


## 撤销时要记下内容的文件：**全部剧本 + 全部收藏表**。
## 记多不记少 —— 漏记一个文件 = 撤销之后剧本引用还是断的。
func _undo_targets() -> PackedStringArray:
	var out := PackedStringArray()
	for p in ScriptStats.script_files():
		out.append(ScriptPaths.resolve(String(p)))
	for kind in AssetRefs.REGISTRIES.keys():
		for p2 in (AssetRefs.REGISTRIES[kind] as Array):
			out.append(String(p2))
	return out


## 把一个目录树里所有文件的内容记进撤销栈（空目录也要记，否则撤不回来）
func _record_dir(path: String) -> void:
	if not _safe_target(path):
		return
	var abs := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	var files := PackedStringArray()
	var dirs := PackedStringArray()
	var d := DirAccess.open(abs)
	if d != null:
		files = d.get_files()
		dirs = d.get_directories()
	d = null
	_undo.record_dir(path)
	for f in files:
		_undo.record_content(path + String(f))
	for sub in dirs:
		_record_dir(path + String(sub) + "/")


func _refresh_grid() -> void:
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()

	var filter := _search.text.strip_edges().to_lower()
	var index = _ed.index
	var ids: PackedStringArray = index.char_ids() if _kind == "char" else index.ids(_kind)
	# 语音是两级素材（角色/台词），用**紧凑行卡片**、一行摆三个 ——
	# 大卡片（168×120）对纯文字条目会留一大片空白，一屏放不下几条
	# （用户反馈「角色语音界面 ui 做得太长」）。
	_grid.columns = 3 if _kind == "voice" else COLS

	var total := 0
	var shown := 0
	var role_count := 0
	if _kind == "voice":
		var roles := _voice_roles()
		role_count = roles.size()
		for r in roles:
			var role: Dictionary = r
			var gid := String(role["group"])
			if not filter.is_empty() \
					and not _voice_group_label(gid).to_lower().contains(filter):
				continue
			total += 1
			shown += 1
			_grid.add_child(_voice_role_card(gid, bool(role["exists"])))
	else:
		for id in ids:
			var sid := String(id)
			total += 1
			if not filter.is_empty() and not sid.to_lower().contains(filter):
				continue
			shown += 1
			if _kind == "char":
				_grid.add_child(_char_card(sid))
			else:
				_grid.add_child(_asset_card(_kind, sid))

	# 剧本引用了、但文件不存在的 —— 也放进网格（标红），
	# 否则作者会以为「剧本里的 id 打错了」而不是「素材还没放」
	var missing: Dictionary = index.missing()
	var miss_list: Array = missing.get(_kind, [])
	for id in miss_list:
		var sid := String(id)
		if not filter.is_empty() and not sid.to_lower().contains(filter):
			continue
		shown += 1
		total += 1
		_grid.add_child(_missing_card(_kind, sid))

	# 末尾的「+」：导入入口长在素材流的尾巴上，不用回工具条找。
	# 过滤时也照样显示 —— 它永远在最后一格，不会插进筛选结果中间。
	_grid.add_child(_add_card())

	if _kind == "voice":
		var unbuilt := 0
		for r in _voice_roles():
			if not bool((r as Dictionary)["exists"]):
				unbuilt += 1
		_stat.text = "语音 · %d 个角色（%d 条）%s" % [role_count, ids.size(),
			"" if unbuilt <= 0 else "· %d 个还没建目录" % unbuilt]
	else:
		_stat.text = "%s · %d 个%s" % [
			String(ProjectIndex.KIND_LABELS.get(_kind, _kind)), total,
			"" if shown == total else "（显示 %d）" % shown]


## 语音页要列的角色。
##
## 三个来源，缺一不可：
##   1. 已经有语音目录的角色（**空目录也算** —— 否则「新建角色 → 返回」时
##      那个文件夹就像没建成功，用户报过这个）；
##   2. 「未分组」（根目录下的散文件，有才显示）；
##   3. **立绘里有、但还没建语音目录的角色** —— 标成「未建」，
##      点进去导语音时会自动建目录。不列出来的话，作者没法知道
##      还有谁没配音（用户报的「语音界面不会显示已有角色」）。
func _voice_roles() -> Array:
	var index = _ed.index
	var out: Array = []
	var built: Array = []
	for g in index.groups("voice"):
		built.append(String(g))
		out.append({"group": String(g), "exists": true})

	var loose := false
	for id in index.ids("voice"):
		if not String(id).contains("/"):
			loose = true
			break
	if loose:
		out.append({"group": "", "exists": true})

	var pending: Array = []
	for cid in index.char_ids():
		var s := String(cid)
		if not built.has(s):
			pending.append(s)
	pending.sort()
	for s in pending:
		out.append({"group": String(s), "exists": false})
	return out


func _refresh_side() -> void:
	for c in _side.get_children():
		_side.remove_child(c)
		c.queue_free()

	var index = _ed.index

	_side.add_child(_side_title("缺失素材"))
	var missing: Dictionary = index.missing()
	var miss_total := 0
	for kind in missing.keys():
		var k := String(kind)
		for id in (missing[kind] as Array):
			miss_total += 1
			var sid := String(id)
			_side.add_child(_side_link("%s / %s" % [k, sid], EdTheme.ERR,
				func() -> void: _jump_to_first_use(k, sid)))
	if miss_total == 0:
		_side.add_child(_side_row("剧本引用的素材都在", EdTheme.OK))

	_side.add_child(_side_title("未被引用"))
	var unused: Dictionary = index.unused()
	var un_total := 0
	for kind in unused.keys():
		var k2 := String(kind)
		for id in (unused[kind] as Array):
			un_total += 1
			if un_total <= 24:
				var sid2 := String(id)
				_side.add_child(_side_link("%s / %s" % [k2, sid2], EdTheme.TEXT_FAINT,
					func() -> void: _focus_card(k2, sid2)))
	if un_total == 0:
		_side.add_child(_side_row("没有多余文件", EdTheme.OK))
	elif un_total > 24:
		_side.add_child(_side_row("…还有 %d 个" % (un_total - 24), EdTheme.TEXT_FAINT))

	_side.add_child(_side_title("素材检查"))
	var health: Array = index.health()
	if health.is_empty():
		_side.add_child(_side_row("没有问题", EdTheme.OK))
	else:
		for issue in health:
			var it: Dictionary = issue
			var lv := String(it.get("level", "warn"))
			var ik := String(it.get("kind", ""))
			var iid := String(it.get("id", ""))
			_side.add_child(_side_link(String(it.get("message", "")),
				EdTheme.ERR if lv == "error" else EdTheme.WARN,
				func() -> void: _goto_issue(ik, iid)))

	_side.add_child(_side_title("详情"))
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 2)
	_side.add_child(_detail)
	_side.add_child(_side_row("点一张卡片看详情", EdTheme.TEXT_FAINT))


## 跳到「剧本里第一次引用它的那一行」。
## 缺失素材点一下就能知道剧本里到底怎么写的 —— 比让作者自己搜快得多。
func _jump_to_first_use(kind: String, id: String) -> void:
	var hits := AssetRefs.find_asset(kind, id)
	if hits.is_empty():
		_ed._notice_flash("剧本里没有引用 %s（可能是收藏表里的？）" % id, EdTheme.WARN)
		return
	var h: Dictionary = hits[0]
	_ed._open_at_file(String(h.get("file", "")))
	_ed.goto_source(int(h.get("line", 1)))


## 素材检查里的一条 → 定位到出问题的素材
func _goto_issue(kind: String, id: String) -> void:
	if kind == "char" and id.contains("/"):
		# 「角色/表情」形式的问题 → 打开那个角色的立绘合集
		var cid := id.split("/")[0]
		_kind = "char"
		rebuild()
		_open_char_gallery(cid)
		return
	if not kind.is_empty() and not id.is_empty():
		_focus_card(kind, id)


func _side_title(t: String) -> Control:
	var l := EdTheme.label(t, EdTheme.FS_SMALL, EdTheme.ACCENT)
	l.custom_minimum_size = Vector2(0, 26)
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	return l


## 侧栏一行文字。
##
## 注意**不要**同时设 `clip_text` 和 `autowrap_mode` —— 两者一起用会让
## Label 的高度算成 0，整行静默消失（标题能显示、内容全空就是这个原因）。
## 这里要自动换行，所以只留 autowrap。
func _side_row(t: String, c: Color) -> Control:
	var l := EdTheme.label(t, EdTheme.FS_SMALL, c)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.tooltip_text = t
	return l


## 侧栏里**可点击**的一行。
##
## 缺失素材点一下跳到剧本里引用它的那一行，未使用 / 有问题的点一下定位到网格里的卡片 ——
## 以前这些只是死文字，作者看到「缺 3 项素材」还得自己去剧本里搜。
##
## ⚠️ 用 Button 而不是「Label + 手接 gui_input」：Button 自带 hover / 焦点 / 键盘可达。
func _side_link(text: String, color: Color, cb: Callable) -> Control:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.tooltip_text = text
	b.add_theme_font_override("font", EdTheme.ui())
	b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	b.add_theme_color_override("font_color", color)
	b.add_theme_color_override("font_hover_color", EdTheme.ACCENT)
	b.add_theme_color_override("font_pressed_color", EdTheme.ACCENT)
	b.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 3, 4, 1))
	b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 4, 1))
	b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 4, 1))
	b.pressed.connect(cb)
	return b


# ---------------------------------------------------------------------------
# 卡片
# ---------------------------------------------------------------------------

func _asset_card(kind: String, id: String) -> Control:
	var index = _ed.index
	var entry: Dictionary = index.get_entry(kind, id)

	var card := Button.new()
	card.custom_minimum_size = Vector2(CARD_W, THUMB_H + 46)
	card.add_theme_stylebox_override("normal",
		EdTheme.sb(EdTheme.BG_ELEV, 8, 6, 6, EdTheme.BORDER, 1))
	card.add_theme_stylebox_override("hover",
		EdTheme.sb(EdTheme.BG_HOVER, 8, 6, 6, EdTheme.ACCENT, 1))
	card.add_theme_stylebox_override("pressed",
		EdTheme.sb(EdTheme.BG_ACTIVE, 8, 6, 6, EdTheme.ACCENT, 1))

	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 3)
	card.add_child(v)

	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(0, THUMB_H)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var path := String(entry.get("path", ""))
	var tex := _thumbnail(path)
	if tex != null:
		thumb.texture = tex
	else:
		# 音频 / 视频没有缩略图，用一个色块 + 类型字
		var ph := ColorRect.new()
		ph.color = EdTheme.BG_PANEL
		ph.custom_minimum_size = Vector2(0, THUMB_H)
		ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(ph)
		var mark := EdTheme.label(_kind_mark(kind), EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
		mark.set_anchors_preset(Control.PRESET_CENTER)
		mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ph.add_child(mark)
	if tex != null:
		v.add_child(thumb)

	var name_l := EdTheme.mono_label(id, EdTheme.FS_SMALL, EdTheme.TEXT)
	name_l.clip_text = true
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(name_l)

	var meta := _meta_text(kind, entry)
	var meta_l := EdTheme.label(meta, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	meta_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(meta_l)

	card.tooltip_text = "%s\n%s" % [path, meta]
	card.pressed.connect(func() -> void: _show_detail(kind, id))
	card.add_child(_card_actions(
		func() -> void: _ask_rename_asset(kind, id),
		func() -> void: _ask_delete_asset(kind, id)))
	_tag_card(card, kind, id)
	return card


func _char_card(cid: String) -> Control:
	var index = _ed.index
	var entry: Dictionary = index.get_entry("char", cid)

	var card := Button.new()
	card.custom_minimum_size = Vector2(CARD_W, THUMB_H + 46)
	card.add_theme_stylebox_override("normal",
		EdTheme.sb(EdTheme.BG_ELEV, 8, 6, 6, EdTheme.BORDER, 1))
	card.add_theme_stylebox_override("hover",
		EdTheme.sb(EdTheme.BG_HOVER, 8, 6, 6, EdTheme.ACCENT, 1))
	card.add_theme_stylebox_override("pressed",
		EdTheme.sb(EdTheme.BG_ACTIVE, 8, 6, 6, EdTheme.ACCENT, 1))

	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 3)
	card.add_child(v)

	var exprs: Dictionary = entry.get("exprs", {})
	var first_path := ""
	for k in exprs.keys():
		first_path = String((exprs[k] as Dictionary).get("path", ""))
		break
	var tex := _thumbnail(first_path)
	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(0, THUMB_H)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb.texture = tex
	v.add_child(thumb)

	var name_l := EdTheme.mono_label(cid, EdTheme.FS_SMALL, EdTheme.TEXT)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(name_l)

	var anim: Dictionary = entry.get("animated", {})
	var meta := "%d 表情" % exprs.size()
	if anim.size() > 0:
		meta += " · %d 动态" % anim.size()
	var meta_l := EdTheme.label(meta, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	meta_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(meta_l)

	card.tooltip_text = "%s\n表情：%s\n（点一下打开立绘合集）" % [String(entry.get("path", "")),
		", ".join(exprs.keys())]
	card.tooltip_text = "%s\n单击看详情 · 双击进入立绘合集" % String(entry.get("path", ""))
	# 单击 = 看详情，**双击** = 进合集。
	#
	# 为什么不是单击直接进：进合集会把网格整个换掉，作者想连着看几个角色的
	# 表情数 / 目录就得反复进出。分开之后「看」和「进」各归各的。
	# Button 没有双击信号，所以双击走 `gui_input`（`double_click` 标志）——
	# 双击的第一次按下仍然会触发 `pressed`（顺便更新详情），这是可以接受的。
	card.pressed.connect(func() -> void: _show_detail("char", cid))
	card.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton:
			var mb := e as InputEventMouseButton
			if mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT:
				_open_char_gallery(cid))
	card.add_child(_card_actions(
		func() -> void: _ask_rename_asset("char", cid),
		func() -> void: _ask_delete_asset("char", cid)))
	_tag_card(card, "char", cid)
	return card


## 卡片右上角的操作徽章：`✎` 重命名 + `✕` 删除。
##
## 为什么两个都常驻而不是塞进 `⋯` 菜单：卡片只有 168px 宽，两个 22px 的徽章
## 加起来 44px，放得下；而且重命名和删除是素材页最常用的两个动作，
## 藏一层菜单就多一次点击、还难发现。样式刻意做得低调（半透明深底 + 淡色字形），
## 悬停才变亮 —— 一屏 20 张卡片也不会显得吵。
##
## ⚠️ **必须是卡片的最后一个子节点**：它才盖在缩略图之上、先拿到鼠标事件，
## 点它不会连带触发卡片自己的 `pressed`（打开详情 / 立绘合集）。
## ⚠️ **不要给徽章设 `flat = true`** —— 那会让 Button 走空样式盒，
## 下面的 normal / hover 覆盖全部失效。
func _card_actions(rename_cb: Callable, delete_cb: Callable) -> Control:
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	row.offset_left = -48
	row.offset_top = 2
	row.offset_right = -2
	row.offset_bottom = 22
	row.add_theme_constant_override("separation", 0)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(_badge("✎", "重命名", EdTheme.ACCENT, rename_cb))
	row.add_child(_badge("✕", "删除", EdTheme.ERR, delete_cb))
	return row


func _badge(glyph: String, tip: String, hot: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = glyph
	b.custom_minimum_size = Vector2(22, 20)
	b.tooltip_text = tip
	b.add_theme_font_override("font", EdTheme.ui())
	b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	b.add_theme_color_override("font_color", EdTheme.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", hot)
	b.add_theme_color_override("font_pressed_color", hot)
	b.add_theme_stylebox_override("normal",
		EdTheme.sb(Color(0.09, 0.09, 0.11, 0.55), 4, 2, 1))
	b.add_theme_stylebox_override("hover",
		EdTheme.sb(EdTheme.BG_HOVER, 4, 2, 1, hot, 1))
	b.add_theme_stylebox_override("pressed",
		EdTheme.sb(EdTheme.BG_ACTIVE, 4, 2, 1, hot, 1))
	b.pressed.connect(cb)
	return b


## 把「这张卡片代表哪个素材」记在节点 meta 上。
##
## 拖放要用它做命中测试（Godot 没有 per-control 的拖放目标，只能自己按鼠标坐标
## 找落在哪张卡上）；侧栏「未被引用」点击后要滚动到卡片也用它。
func _tag_card(card: Control, kind: String, id: String) -> void:
	card.set_meta("asset_kind", kind)
	card.set_meta("asset_id", id)


## 当前网格里代表某个素材的卡片
func _card_of(kind: String, id: String) -> Control:
	if _grid == null:
		return null
	for c in _grid.get_children():
		if c is Control and c.has_meta("asset_id") \
				and String(c.get_meta("asset_id")) == id \
				and String(c.get_meta("asset_kind")) == kind:
			return c
	return null


## 鼠标现在压在哪张卡片上（拖放落点判定用）
func _card_under_mouse() -> Dictionary:
	if _grid == null:
		return {}
	var pos := get_global_mouse_position()
	for c in _grid.get_children():
		if not (c is Control) or not c.has_meta("asset_id"):
			continue
		if (c as Control).get_global_rect().has_point(pos):
			return {"kind": String(c.get_meta("asset_kind")),
				"id": String(c.get_meta("asset_id"))}
	return {}


## 鼠标下面是不是某张语音角色卡片；是就返回那个组名（不是角色卡片返回空串）
func _voice_role_under_mouse() -> String:
	if _grid == null:
		return ""
	var pos := get_global_mouse_position()
	for c in _grid.get_children():
		if not (c is Control) or not c.has_meta("voice_role"):
			continue
		if (c as Control).get_global_rect().has_point(pos):
			return String(c.get_meta("voice_role"))
	return ""


## 把某张卡片滚进视口并高亮一下（侧栏点「未被引用」时用）
func _focus_card(kind: String, id: String) -> void:
	var card := _card_of(kind, id)
	if card == null and kind == "voice":
		# 语音是两级浏览：组内条目不在网格页上 —— 直接把那个角色的合集打开
		var slash := id.find("/")
		if slash > 0:
			_ed.show_page("asset")
			_kind = "voice"
			rebuild()
			_open_gallery("voice", id.substr(0, slash))
			_show_detail("voice", id)
			return
	if card == null:
		_ed._notice_flash("%s 不在当前网格里（换个类别或清掉过滤词）" % id, EdTheme.WARN)
		return
	if _grid_scroll != null:
		_grid_scroll.ensure_control_visible(card)
	_show_detail(kind, id)


# ---------------------------------------------------------------------------
# 拖拽导入
# ---------------------------------------------------------------------------

## 文件被拖到窗口上。
##
## Godot 只有窗口级的 `files_dropped`，所以这里得自己判断该不该管：
##   - 当前不是素材页 → 忽略（别的页面拖文件没有意义）
##   - 立绘合集开着 → 导进那个角色
##   - 立绘页 → 看鼠标落在哪张角色卡片上（落空就提示，不瞎猜）
##   - 其它类别 → 导进当前类别
func _on_files_dropped(files: PackedStringArray) -> void:
	if not visible or files.is_empty():
		return
	if _gallery.visible and not _gallery_group.is_empty():
		# 合集里拖进来 → 导到当前这个组
		if _gallery_kind == "char":
			_import_char_exprs(files, _gallery_group)
		else:
			_import_flat(files, "voice", _gallery_group)
		return
	if _kind == "char":
		var hit := _card_under_mouse()
		if not hit.is_empty() and String(hit.get("kind", "")) == "char":
			_import_char_exprs(files, String(hit["id"]))
			return
		_ed._notice_flash("立绘是两级目录 —— 把文件拖到某个角色卡片上，或点 + 新建角色",
			EdTheme.WARN)
		return
	if _kind == "voice":
		# 拖到某个角色卡片上 → 导进那个角色；拖在空白处 → 进「未分组」
		var role := _voice_role_under_mouse()
		_import_flat(files, "voice", role)
		return
	_import_flat(files, _kind)


## 网格末尾的「+」卡片 —— 导入入口就长在素材流的尾巴上。
##
## 三种含义（由参数决定）：
##   - `cid` 非空   → 往**那个角色**的目录导入立绘表情（立绘合集里用）
##   - `_kind == "char"` → **新建角色**（角色是目录，表情要在角色合集里导）
##   - 其它类别     → 往**当前类别**的目录导入文件
func _add_card(kind: String = "", group: String = "") -> Control:
	var k := kind if not kind.is_empty() else _kind
	var caption := ""
	var tip := ""
	if k == "char" and not group.is_empty():
		caption = "导入立绘"
		tip = "把图片复制进 assets/sprites/%s/，文件名就是表情名" % group
	elif k == "char":
		caption = "新建角色"
		tip = "在 assets/sprites/ 下建一个新角色（立绘是两级目录：角色/表情）"
	elif k == "voice" and not group.is_empty():
		caption = "导入到 %s" % group
		tip = "把文件复制进 %s，id 会是 %s/<文件名>" % [_voice_dir_of(group), group]
	elif k == "voice":
		# 语音页的「＋」= **建分类目录**，不是导散文件。
		# 散文件只能靠拖拽进（会落到「未分组」），免得作者顺手把语音全堆在根目录。
		caption = "新建角色"
		tip = ("在 %s 下建一个角色目录（就是语音的分类 / 子文件夹），\n"
			+ "建好之后进去导语音，id 会是 <角色>/<文件名>。\n\n"
			+ "（想放不归角色的共用语音，把文件拖到空白处 → 进「未分组」）"
			) % String(ProjectIndex.KIND_DIRS["voice"])
	else:
		caption = "导入素材"
		tip = "把文件复制进 %s，并规范化命名" % String(ProjectIndex.KIND_DIRS[k])

	var card := Button.new()
	# 语音是紧凑行卡片，导入卡片也跟着矮下来 —— 混着一个 120px 的大方块
	# 会让整页又「长」回去
	var compact := k == "voice"
	card.custom_minimum_size = Vector2(CARD_W, 30 if compact else THUMB_H + 46)
	card.add_theme_stylebox_override("normal",
		EdTheme.sb(Color(0, 0, 0, 0), 8, 6, 6, EdTheme.BORDER_HI, 1))
	card.add_theme_stylebox_override("hover",
		EdTheme.sb(EdTheme.BG_HOVER, 8, 6, 6, EdTheme.ACCENT, 1))
	card.add_theme_stylebox_override("pressed",
		EdTheme.sb(EdTheme.BG_ACTIVE, 8, 6, 6, EdTheme.ACCENT, 1))
	card.tooltip_text = tip

	if compact:
		var h := HBoxContainer.new()
		h.set_anchors_preset(Control.PRESET_FULL_RECT)
		h.offset_left = 8
		h.offset_right = -6
		h.add_theme_constant_override("separation", 6)
		card.add_child(h)
		var plus_c := EdTheme.label("＋", EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
		plus_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(plus_c)
		var cap_c := EdTheme.label(caption, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
		cap_c.clip_text = true
		cap_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(cap_c)
	else:
		var v := VBoxContainer.new()
		v.set_anchors_preset(Control.PRESET_FULL_RECT)
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.alignment = BoxContainer.ALIGNMENT_CENTER
		v.add_theme_constant_override("separation", 2)
		card.add_child(v)

		var plus := EdTheme.label("＋", 30, EdTheme.TEXT_FAINT)
		plus.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		plus.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(plus)

		var cap := EdTheme.label(caption, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(cap)

	if k == "char" and not group.is_empty():
		card.pressed.connect(func() -> void: _open_char_import(group))
	elif k == "char":
		card.pressed.connect(_open_new_char_dialog)
	elif k == "voice" and not group.is_empty():
		card.pressed.connect(func() -> void: _open_import(group))
	elif k == "voice":
		card.pressed.connect(_open_new_role_dialog)
	else:
		card.pressed.connect(func() -> void: _open_import())
	return card


func _missing_card(kind: String, id: String) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(CARD_W, THUMB_H + 46)
	card.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_ELEV, 8, 6, 6, EdTheme.ERR, 1))

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	card.add_child(v)

	v.add_child(EdTheme.label("缺失", EdTheme.FS_SMALL, EdTheme.ERR))
	var name_l := EdTheme.mono_label(id, EdTheme.FS_SMALL, EdTheme.TEXT)
	name_l.clip_text = true
	v.add_child(name_l)
	v.add_child(EdTheme.label("剧本引用了", EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))
	v.add_child(EdTheme.label("但文件不存在", EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))
	return card


static func _kind_mark(kind: String) -> String:
	match kind:
		"bg":
			return "[BG]"
		"cg":
			return "[CG]"
		"se":
			return "[SE]"
		"bgm":
			return "[BGM]"
		"voice":
			return "[VOICE]"
		"video":
			return "[VIDEO]"
	return "[?]"


func _meta_text(kind: String, entry: Dictionary) -> String:
	if kind == "video":
		return "Ogg Theora"
	var dur := float(entry.get("duration", 0.0))
	if dur > 0.0:
		return _fmt_time(dur)
	var s: Vector2i = entry.get("size", Vector2i.ZERO)
	if s.x > 0:
		return "%d×%d" % [s.x, s.y]
	return String(entry.get("ext", "")).to_upper()


static func _fmt_time(sec: float) -> String:
	var m := int(sec) / 60
	var s := int(sec) % 60
	return "%d:%02d" % [m, s]


# ---------------------------------------------------------------------------
# 缩略图
# ---------------------------------------------------------------------------

## 缩略图走直读 —— 不依赖 .import，所以刚导入的素材立刻有图。
## 大图会先缩到 THUMB_H 的 2 倍再转纹理，避免为了一张卡片解出整张 4K 图。
func _thumbnail(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _thumb_cache.has(path):
		return _thumb_cache[path]

	var tex: Texture2D = null
	var img: Image = Image.load_from_file(path)
	if img != null:
		var w := int(float(img.get_width()) * (THUMB_H * 2.0) / maxf(float(img.get_height()), 1.0))
		if w > 0 and img.get_height() > THUMB_H * 2:
			img.resize(maxi(w, 1), THUMB_H * 2, Image.INTERPOLATE_LANCZOS)
		tex = ImageTexture.create_from_image(img)
	elif ResourceLoader.exists(path):
		tex = load(path) as Texture2D

	_thumb_cache[path] = tex
	return tex


# ---------------------------------------------------------------------------
# 详情
# ---------------------------------------------------------------------------

func _show_detail(kind: String, id: String) -> void:
	if _detail == null:
		return
	for c in _detail.get_children():
		_detail.remove_child(c)
		c.queue_free()

	var index = _ed.index
	var entry: Dictionary = index.get_entry(kind, id)

	if kind == "char":
		var exprs: Dictionary = entry.get("exprs", {})
		var anim: Dictionary = entry.get("animated", {})
		_detail.add_child(_side_row("目录 %s" % String(entry.get("path", "")), EdTheme.TEXT_DIM))
		_detail.add_child(_side_row("静态表情 %d：%s" % [exprs.size(), ", ".join(exprs.keys())],
			EdTheme.TEXT_DIM))
		if anim.size() > 0:
			_detail.add_child(_side_row("帧序列 %d：%s" % [anim.size(), ", ".join(anim.keys())],
				EdTheme.ACCENT))
	elif kind == "voice_role":
		var vids := _voice_ids_of(id)
		var built: bool = _ed.index.group_exists("voice", id)
		_detail.add_child(_side_row("目录 %s%s" % [_voice_dir_of(id),
			"" if built else "（还没有建）"], EdTheme.TEXT_DIM))
		if built:
			_detail.add_child(_side_row("语音 %d 条 · 共 %s" % [vids.size(),
				_fmt_duration(_voice_seconds_of(vids))], EdTheme.TEXT_DIM))
		else:
			_detail.add_child(_side_row(
				"立绘里有这个角色，但还没有语音目录 —— 双击卡片进去导语音时会自动建。",
				EdTheme.WARN))
		_detail.add_child(_side_row("剧本里写：voice %s/<台词>" % _voice_group_label(id),
			EdTheme.TEXT_FAINT))
	else:
		var s: Vector2i = entry.get("size", Vector2i.ZERO)
		var dur := float(entry.get("duration", 0.0))
		_detail.add_child(_side_row("文件 %s" % String(entry.get("path", "")), EdTheme.TEXT_DIM))
		if s.x > 0:
			_detail.add_child(_side_row("尺寸 %d × %d" % [s.x, s.y], EdTheme.TEXT_DIM))
		if dur > 0.0:
			_detail.add_child(_side_row("时长 %s" % _fmt_time(dur), EdTheme.TEXT_DIM))

	# 打开原图 / 在资源管理器中定位 —— 缩略图只有 74px 高，
	# 要看清楚一张 1920×1080 的立绘有没有画歪，只能交给系统看图程序。
	var target := String(entry.get("path", ""))
	if kind == "voice_role":
		target = _voice_dir_of(id)
	if not target.is_empty():
		# 两级素材在详情里给一个显式的入口 ——
		# 「双击卡片进合集」是隐藏操作，光靠 tooltip 不够
		if kind == "char":
			_detail.add_child(_detail_button("进入立绘合集 →",
				func() -> void: _open_gallery("char", id)))
		elif kind == "voice_role":
			_detail.add_child(_detail_button("进入语音合集 →",
				func() -> void: _open_gallery("voice", id)))
		else:
			_detail.add_child(_detail_button("用系统看图程序打开",
				func() -> void: OS.shell_open(ProjectSettings.globalize_path(target))))
		_detail.add_child(_detail_button("在资源管理器中显示",
			func() -> void: _reveal_in_explorer(target)))

	# 被哪些剧本行引用
	var uses: Array = _usages_of(kind, id)
	_detail.add_child(_side_row("被引用 %d 处" % uses.size(),
		EdTheme.OK if uses.size() > 0 else EdTheme.WARN))
	for u in uses.slice(0, 12):
		var uu: Dictionary = u
		var btn := Button.new()
		btn.text = "%s 第 %d 行" % [String(uu.get("file", "")), int(uu.get("line", 0))]
		btn.flat = true
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_override("font", EdTheme.mono())
		btn.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
		btn.add_theme_color_override("font_color", EdTheme.ACCENT)
		btn.add_theme_color_override("font_hover_color", Color.WHITE)
		btn.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 3, 6, 1))
		btn.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 6, 1))
		btn.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 6, 1))
		var f := String(uu.get("file", ""))
		var ln := int(uu.get("line", 0))
		btn.pressed.connect(func() -> void:
			_ed._open_at_file(f)
			_ed.goto_source(ln))
		_detail.add_child(btn)


## 详情里的一颗操作按钮（与「被引用」列表里的跳转链接同一套观感）
func _detail_button(text: String, cb: Callable) -> Control:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_override("font", EdTheme.ui())
	b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	b.add_theme_color_override("font_color", EdTheme.ACCENT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 3, 4, 1))
	b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 4, 1))
	b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 4, 1))
	b.pressed.connect(cb)
	return b


## 在系统文件管理器里定位这个文件。
##
## Windows 靠 `explorer /select,<路径>` 能选中文件本身；其它平台没有可移植的写法，
## 退回「打开所在目录」。`create_process` 失败时也退回打开目录，别让按钮点了没反应。
func _reveal_in_explorer(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	if OS.get_name() == "Windows":
		var win_path := abs.replace("/", "\\")
		if OS.create_process("explorer.exe", ["/select," + win_path]) > 0:
			return
	OS.shell_open(abs.get_base_dir())


## 找出引用了某个素材的剧本行（**跨全部剧本**，不只当前打开的那个）。
##
## 以前这里只扫 `_ed.doc.lines` —— 于是「被引用 N 处」只算当前文件，
## 作者看着「0 处」以为能安全删掉，其实别的剧本里还有一堆引用。
## 现在统一走 `AssetRefs`，与重命名 / 删除用的是同一套判定，不会各说各话。
func _usages_of(kind: String, id: String) -> Array:
	return AssetRefs.find_asset(kind, id)


## 改素材会**连带改剧本文件**（同步引用）—— 手里有未保存改动时先拦住：
## 不然磁盘被我们改过之后，编辑器那份内存里的改动会撞上冲突框，作者一脸茫然。
func _guard_dirty() -> bool:
	if _ed.doc != null and _ed.doc.is_dirty():
		_ed._notice_flash("先保存当前剧本（Ctrl+S）再改素材", EdTheme.WARN)
		return false
	return true


## 剧本被改过了 → 让编辑器把手里的文档立刻跟上去。
##
## 不静默等 500ms 轮询：作者刚点了「重命名」，期望马上在源码页看到新 id。
func _sync_open_doc(hits: Array) -> void:
	if _ed.doc == null or _ed.doc.path.is_empty():
		return
	# ⚠️ `_ed` 是 untyped 的 Control，`_ed.doc.path` 推不出类型 ——
	# 写 `var cur := ...` 会直接编译不过（Cannot infer the type）。
	var cur: String = _ed.doc.path.get_file()
	for h in hits:
		if String((h as Dictionary).get("file", "")) == cur:
			_ed._reload_from_disk("素材改名：剧本引用已同步")
			return


# ---------------------------------------------------------------------------
# 重命名
# ---------------------------------------------------------------------------

## `kind` 为 "char" 时改的是**角色 id**。
func _ask_rename_asset(kind: String, id: String) -> void:
	if not _guard_dirty():
		return
	var entry: Dictionary = _ed.index.get_entry(kind, id)
	var path := String(entry.get("path", ""))
	if path.is_empty():
		return
	var n := 0
	var tip := ""
	if kind == "char":
		n = AssetRefs.find_asset("char", id).size()
		tip = ("会把 assets/sprites/%s/ 整个目录改名，并同步剧本里 %d 处引用：\n"
			+ "立绘指令、对白前缀、affection 好感度、if 条件里的角色名。\n\n"
			+ "⚠ 存档里的好感度是按旧 id 记的，改名后不会跟着变"
			+ "（存档是玩家数据，工具不碰）。") % [id, n]
	else:
		n = AssetRefs.find_asset(kind, id).size()
		tip = "会改掉剧本里 %d 处引用。" % n
		if id.contains("/"):
			tip += "\n\n这是个分组素材（%s），只改「/」后面的名字，组名不动。" \
				% id.split("/")[0]
		if kind in AssetRefs.REGISTRIES:
			var names := []
			for p2 in (AssetRefs.REGISTRIES[kind] as Array):
				names.append(String(p2).get_file())
			tip += "收藏表（%s）里的 id 与图片路径也会一起同步。" % ", ".join(names)
	# 分组素材的输入框只填叶子名（`alice/line01` 里填 `line01`）
	var current := id
	var slash := id.find("/")
	if slash > 0:
		current = id.substr(slash + 1)
	_open_rename_dialog({"mode": "asset", "kind": kind, "id": id, "path": path}, current, tip)


func _ask_rename_expr(cid: String, expr: String, path: String, animated: bool) -> void:
	if not _guard_dirty():
		return
	var n := AssetRefs.find_expr(cid, expr).size()
	var tip := "会改掉剧本里 %d 处引用（show 的 expr= / expr 指令 / 对白前缀 %s@%s:）。" % [
		n, cid, expr]
	if animated:
		tip += "\n\n这是个帧序列目录，整目录一起改名。"
	_open_rename_dialog(
		{"mode": "expr", "cid": cid, "expr": expr, "path": path, "animated": animated},
		expr, tip)


func _open_rename_dialog(ctx: Dictionary, current: String, tip: String) -> void:
	_rename_ctx = ctx
	_rename_dialog.title = "重命名"
	_rename_dialog.dialog_text = tip
	_rename_name.text = current
	_rename_name.select_all()
	_rename_dialog.popup_centered()
	# 弹窗刚 popup 时还没拿到焦点，直接 grab_focus 会被系统抢回去
	_rename_name.call_deferred("grab_focus")


func _do_rename_asset() -> void:
	var ctx := _rename_ctx
	_rename_ctx = {}
	_rename_dialog.hide()
	if ctx.is_empty():
		return
	var name := _normalize_id(_rename_name.text)
	if name.is_empty():
		_ed._notice_flash("id 只能用 小写字母 / 数字 / 下划线", EdTheme.ERR)
		return
	match String(ctx.get("mode", "")):
		"asset":
			_rename_asset(String(ctx["kind"]), String(ctx["id"]), String(ctx["path"]), name)
		"expr":
			_rename_expr(String(ctx["cid"]), String(ctx["expr"]), String(ctx["path"]),
				bool(ctx.get("animated", false)), name)
		"voice_role":
			_rename_voice_role(String(ctx["id"]), name)


func _rename_asset(kind: String, old_id: String, old_path: String, new_name: String) -> void:
	# 分组素材（语音 `alice/line01`）只改**叶子名**，组名不动 ——
	# 跨组改名等于挪文件，那是另一件事（要连目录一起搬）。
	var group := ""
	var leaf_old := old_id
	var slash := old_id.find("/")
	if slash > 0:
		group = old_id.substr(0, slash)
		leaf_old = old_id.substr(slash + 1)
	var new_id := new_name if group.is_empty() else "%s/%s" % [group, new_name]
	if new_id == old_id:
		return

	var dir_path := String(ProjectIndex.KIND_DIRS[kind])
	if not group.is_empty():
		dir_path = dir_path + group + "/"
	var new_path := ""
	var moves: Array = []

	# 先开记录、先把「可能被改到的文本」抄下来，再动文件系统 ——
	# 顺序反了就撤不回去了（撤销栈里得是**改动前**的内容）
	_undo.begin("重命名 %s → %s" % [old_id, new_id])
	_undo.record_texts(_undo_targets())

	if kind == "char":
		new_path = dir_path + new_id + "/"
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(new_path)):
			_undo.cancel()
			_ed._notice_flash("assets/sprites/%s/ 已存在" % new_id, EdTheme.ERR)
			return
		if DirAccess.rename_absolute(ProjectSettings.globalize_path(old_path),
				ProjectSettings.globalize_path(new_path)) != OK:
			_undo.cancel()
			_ed._notice_flash("重命名目录失败：%s" % old_path, EdTheme.ERR)
			return
		moves.append([old_path, new_path])
	else:
		moves = _rename_files(dir_path, leaf_old, new_name, _exts_of(kind))
		if moves.is_empty():
			_undo.cancel()
			_ed._notice_flash("没找到 %s 的文件，可能已被外部改动" % leaf_old, EdTheme.ERR)
			return
		new_path = dir_path + new_name + "." + old_path.get_extension()

	for m in moves:
		var pair: Array = m
		_undo.record_move(String(pair[0]), String(pair[1]))

	var r := AssetRefs.rewrite_asset(kind, old_id, new_id)
	var reg := AssetRefs.rewrite_registry(kind, old_id, new_id, old_path, new_path)
	_undo.commit()

	_sync_open_doc(r.get("hits", []))
	_after_asset_change()
	if kind == "char" and _gallery.visible:
		_gallery.visible = false
	var extra := "" if reg == 0 else "，收藏表 %d 个文件" % reg
	_ed._notice_flash("已把 %s 改名为 %s（剧本 %d 处引用%s）" % [
		old_id, new_id, int(r.get("lines", 0)), extra], EdTheme.OK)


func _rename_expr(cid: String, old_expr: String, path: String, animated: bool,
		new_expr: String) -> void:
	if new_expr == old_expr:
		return
	var dir_path := String(ProjectIndex.KIND_DIRS["char"]) + cid + "/"
	var moves: Array = []

	_undo.begin("重命名 %s/%s → %s" % [cid, old_expr, new_expr])
	_undo.record_texts(_undo_targets())

	if animated:
		var new_dir := dir_path + new_expr + "/"
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(new_dir)):
			_undo.cancel()
			_ed._notice_flash("%s/%s 已存在" % [cid, new_expr], EdTheme.ERR)
			return
		if DirAccess.rename_absolute(ProjectSettings.globalize_path(path),
				ProjectSettings.globalize_path(new_dir)) != OK:
			_undo.cancel()
			_ed._notice_flash("重命名目录失败：%s" % path, EdTheme.ERR)
			return
		moves.append([path, new_dir])
	else:
		moves = _rename_files(dir_path, old_expr, new_expr, ProjectIndex.IMAGE_EXT)
		if moves.is_empty():
			_undo.cancel()
			_ed._notice_flash("没找到 %s/%s 的文件，可能已被外部改动" % [cid, old_expr], EdTheme.ERR)
			return

	for m in moves:
		var pair: Array = m
		_undo.record_move(String(pair[0]), String(pair[1]))

	var r := AssetRefs.rewrite_expr(cid, old_expr, new_expr)
	_undo.commit()

	_sync_open_doc(r.get("hits", []))
	_after_asset_change()
	if _gallery.visible and _gallery_group == cid:
		_open_gallery("char", cid)
	_ed._notice_flash("已把 %s 的立绘 %s 改名为 %s（剧本 %d 处引用）" % [
		cid, old_expr, new_expr, int(r.get("lines", 0))], EdTheme.OK)


## 把目录里所有「文件名（去后缀）= old_id」且后缀在 `exts` 里的文件改成 new_id。
## **同名多后缀一起改** —— 素材检查会把「同 id 多个文件」报成冲突，
## 只改其中一个会让冲突更乱。
##
## 返回实际发生的改名列表 `[[from, to], ...]`（撤销栈要拿它做反向操作）。
func _rename_files(dir_path: String, old_id: String, new_id: String, exts: Array) -> Array:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return []
	var targets: Array = []
	for fn in dir.get_files():
		var f := String(fn)
		if f.get_basename() != old_id:
			continue
		if not exts.has(f.get_extension().to_lower()):
			continue
		targets.append(f)

	var moves: Array = []
	for t in targets:
		var f := String(t)
		var ext := f.get_extension()
		var dst_name := "%s.%s" % [new_id, ext]
		if FileAccess.file_exists(dir_path + dst_name):
			continue
		if DirAccess.rename_absolute(ProjectSettings.globalize_path(dir_path + f),
				ProjectSettings.globalize_path(dir_path + dst_name)) != OK:
			continue
		moves.append([dir_path + f, dir_path + dst_name])
		_move_sidecar(dir_path + f, dir_path + dst_name)
	return moves


## `.import` / `.uid` 旁文件跟着走 —— 留下旧的会让 Godot 以为旧资源还在。
## 返回实际挪动的 [from, to] 列表（撤销用）。
func _move_sidecar(old_path: String, new_path: String) -> Array:
	var moves: Array = []
	for suffix in [".import", ".uid"]:
		if FileAccess.file_exists(old_path + suffix):
			if DirAccess.rename_absolute(ProjectSettings.globalize_path(old_path + suffix),
					ProjectSettings.globalize_path(new_path + suffix)) == OK:
				moves.append([old_path + suffix, new_path + suffix])
	return moves


static func _exts_of(kind: String) -> Array:
	if kind in ["bg", "cg"]:
		return ProjectIndex.IMAGE_EXT
	if kind == "video":
		return ProjectIndex.VIDEO_EXT
	if kind in ["se", "bgm", "voice"]:
		return ProjectIndex.AUDIO_EXT
	return ProjectIndex.IMAGE_EXT


# ---------------------------------------------------------------------------
# 删除
# ---------------------------------------------------------------------------

## 网格里的卡片点 ✕ → 先确认。立绘卡删的是**整个角色目录**，
## 所以文案里把路径和立绘数量都写出来，让作者看清要删掉什么。
##
## **删除不做静默的引用清理**（与删除剧本同一套判断）：删完之后剧本里那些
## `bg classroom` 会变成死链，而剧本不报错、只是画面黑掉 ——
## 所以这里必须先把「会留下几处死链」说清楚。
func _ask_delete_asset(kind: String, id: String) -> void:
	if not _guard_dirty():
		return
	var n := AssetRefs.find_asset(kind, id).size()
	var tail := "" if n == 0 else "\n\n⚠ 剧本里还有 %d 处引用会变成死链（缺素材看板会列出来）。" % n
	if kind == "char":
		var entry: Dictionary = _ed.index.get_entry("char", id)
		var cnt: int = (entry.get("exprs", {}) as Dictionary).size() \
			+ (entry.get("animated", {}) as Dictionary).size()
		_confirm.title = "删除角色"
		_confirm.dialog_text = "删除角色 %s？\n\n会整个删掉 %s（%d 个立绘）。%s" % [
			id, String(entry.get("path", "")), cnt, tail]
		_pending_delete = func() -> void: _delete_char(id)
	else:
		var e: Dictionary = _ed.index.get_entry(kind, id)
		var path := String(e.get("path", ""))
		if path.is_empty():
			return
		_confirm.title = "删除素材"
		_confirm.dialog_text = "删除 %s？\n\n%s%s" % [path.get_file(), path, tail]
		_pending_delete = func() -> void: _delete_asset_file(path)
	_confirm.popup_centered()


func _ask_delete_expr(cid: String, expr: String, path: String, animated: bool) -> void:
	if not _guard_dirty():
		return
	var n := AssetRefs.find_expr(cid, expr).size()
	var detail := "整帧序列目录会一起删掉" if animated else path.get_file()
	var tail := "" if n == 0 else "\n\n⚠ 剧本里还有 %d 处引用会变成死链。" % n
	_confirm.title = "删除立绘"
	_confirm.dialog_text = "删除 %s 的立绘「%s」？\n\n%s%s" % [cid, expr, detail, tail]
	_pending_delete = func() -> void: _delete_expr(cid, path, animated)
	_confirm.popup_centered()


func _delete_asset_file(path: String) -> void:
	_undo.begin("删除 %s" % path.get_file())
	_undo.record_content(path)
	_undo.record_content(path + ".import")
	_undo.record_content(path + ".uid")
	_remove_file(path)
	_undo.commit()
	_after_asset_change()
	_ed._notice_flash("已删除 %s（可用「↶ 撤销」找回）" % path.get_file(), EdTheme.OK)


func _delete_expr(cid: String, path: String, animated: bool) -> void:
	_undo.begin("删除 %s/%s" % [cid, path.get_file()])
	if animated:
		_record_dir(path)
		_delete_dir_recursive(path)
	else:
		_undo.record_content(path)
		_undo.record_content(path + ".import")
		_undo.record_content(path + ".uid")
		_remove_file(path)
	_undo.commit()
	_after_asset_change()
	if _gallery.visible and _gallery_group == cid:
		_open_gallery("char", cid)
	_ed._notice_flash("已删除 %s 的立绘 %s（可用「↶ 撤销」找回）" % [cid, path.get_file()],
		EdTheme.OK)


func _delete_char(id: String) -> void:
	var entry: Dictionary = _ed.index.get_entry("char", id)
	var dir_path := String(entry.get("path", ""))
	if dir_path.is_empty():
		return
	_undo.begin("删除角色 %s" % id)
	_record_dir(dir_path)
	_delete_dir_recursive(dir_path)
	_undo.commit()
	_after_asset_change()
	_gallery.visible = false
	_ed._notice_flash("已删除角色 %s（可用「↶ 撤销」找回）" % id, EdTheme.OK)


# ---------------------------------------------------------------------------
# 语音角色（组）的改名 / 删除
# ---------------------------------------------------------------------------

func _ask_rename_voice_role(group: String) -> void:
	if group.is_empty():
		_ed._notice_flash("「未分组」是散在根目录的文件 —— 先归到某个角色下再改名",
			EdTheme.WARN)
		return
	if not _ed.index.group_exists("voice", group):
		_ed._notice_flash("%s 还没有语音目录，没什么可改名的" % group, EdTheme.WARN)
		return
	if not _guard_dirty():
		return
	var n := 0
	for id in _voice_ids_of(group):
		n += AssetRefs.find_asset("voice", String(id)).size()
	var tip := ("会把 assets/audio/voice/%s/ 整个目录改名，并同步剧本里 %d 处引用"
		% [group, n]) + "（`voice <角色>/<台词>` 里的角色名）。"
	_open_rename_dialog({"mode": "voice_role", "id": group}, group, tip)


## 改角色目录名 + 同步全部成员 id（`alice/line01` → `bob/line01`）。
##
## 成员是**逐条**改的（`AssetRefs.rewrite_asset` 一次只认一个 id），
## 所以先把「全部剧本 + 收藏表」抄进撤销栈再动手 —— 顺序反了就撤不回去。
func _rename_voice_role(group: String, new_name: String) -> void:
	if new_name == group:
		return
	var root := String(ProjectIndex.KIND_DIRS["voice"])
	var old_dir := root + group + "/"
	var new_dir := root + new_name + "/"
	if not _safe_target(old_dir) or not _safe_target(new_dir):
		_ed._notice_flash("拒绝对素材根目录动手（这是保护，不是 bug）", EdTheme.ERR)
		return
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(new_dir)):
		_ed._notice_flash("assets/audio/voice/%s/ 已存在" % new_name, EdTheme.ERR)
		return

	_log_op("rename-dir", "%s → %s" % [old_dir, new_dir])
	var ids := _voice_ids_of(group)
	_undo.begin("重命名语音角色 %s → %s" % [group, new_name])
	_undo.record_texts(_undo_targets())
	_undo.record_move(old_dir, new_dir)
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(old_dir),
			ProjectSettings.globalize_path(new_dir)) != OK:
		_undo.cancel()
		_ed._notice_flash("重命名目录失败：%s" % old_dir, EdTheme.ERR)
		return

	var hits: Array = []
	var lines := 0
	for id in ids:
		var sid := String(id)
		var new_id := "%s/%s" % [new_name, sid.substr(sid.find("/") + 1)]
		var r := AssetRefs.rewrite_asset("voice", sid, new_id)
		lines += int(r.get("lines", 0))
		hits.append_array(r.get("hits", []))
	_undo.commit()

	_sync_open_doc(hits)
	_after_asset_change()
	if _gallery.visible:
		_open_gallery("voice", new_name)
	_ed._notice_flash("已把语音角色 %s 改名为 %s（%d 条 · 剧本 %d 处引用）"
		% [group, new_name, ids.size(), lines], EdTheme.OK)


func _ask_delete_voice_role(group: String) -> void:
	if group.is_empty():
		_ed._notice_flash("「未分组」不是一个目录 —— 逐条删，或先归到某个角色下",
			EdTheme.WARN)
		return
	if not _ed.index.group_exists("voice", group):
		_ed._notice_flash("%s 还没有语音目录，没什么可删的" % group, EdTheme.WARN)
		return
	if not _guard_dirty():
		return
	var ids := _voice_ids_of(group)
	var n := 0
	for id in ids:
		n += AssetRefs.find_asset("voice", String(id)).size()
	var tail := "" if n == 0 else "\n\n⚠ 剧本里还有 %d 处引用会变成死链。" % n
	_confirm.title = "删除语音角色"
	_confirm.dialog_text = "删除角色 %s？\n\n会整个删掉 %s（%d 条语音）。%s" % [
		_voice_group_label(group), _voice_dir_of(group), ids.size(), tail]
	_pending_delete = func() -> void: _delete_voice_role(group)
	_confirm.popup_centered()


func _delete_voice_role(group: String) -> void:
	if group.is_empty():
		_ed._notice_flash("「未分组」不是一个目录 —— 逐条删，或先归到某个角色下",
			EdTheme.WARN)
		return
	var dir_path := _voice_dir_of(group)
	if not _safe_target(dir_path):
		_ed._notice_flash("拒绝对素材根目录动手（这是保护，不是 bug）", EdTheme.ERR)
		return
	_undo.begin("删除语音角色 %s" % group)
	_record_dir(dir_path)
	_delete_dir_recursive(dir_path)
	_undo.commit()
	_after_asset_change()
	if _gallery.visible:
		_gallery.visible = false
	_ed._notice_flash("已删除语音角色 %s（可用「↶ 撤销」找回）" % group, EdTheme.OK)


## 破坏性操作的最后一道闸：**不许对素材根目录动手**。
##
## 语音的「未分组」组名是**空串**。只要有一条路径把空串当组名传下去，
## `_voice_dir_of("")` 就是 `assets/audio/voice/` 本身 —— 删一次就把整个分类目录
## 连同里面所有语音清空（实测发生过：一次误删把整目录抹平了，
## 好在 Godot 的导入缓存里还有原始字节才救回来）。
## 代价太大，所以在真正落盘的地方硬挡，不靠调用方自觉。
##
## 返回 true 表示「可以动」。
static func _safe_target(path: String) -> bool:
	if path.is_empty():
		return false
	var p := path
	if not p.ends_with("/"):
		p += "/"
	for kind in ProjectIndex.KIND_DIRS.keys():
		if p == String(ProjectIndex.KIND_DIRS[kind]):
			push_error("[素材] 拒绝对素材根目录动手：%s" % p)
			return false
	return true


## 破坏性素材操作的流水（`user://asset_ops.log`）。
##
## 素材被误删过一次而**查不出是谁干的**（测试？编辑器？资源管理器？），
## 所以留一条带时间戳的记录 —— 下次直接翻日志，不用再靠推理。
static func _log_op(op: String, path: String) -> void:
	var f := FileAccess.open("user://asset_ops.log", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://asset_ops.log", FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("%s  %s  %s" % [Time.get_datetime_string_from_system(), op, path])
	f.close()


## 删一个文件，连带 .import / .uid 旁文件 —— 只删本体的话，
## 残留的 .import 会让 Godot 下次扫描时以为这个资源还在。
func _remove_file(path: String) -> void:
	_log_op("delete-file", path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for suffix in [".import", ".uid"]:
		if FileAccess.file_exists(path + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))


## 递归删目录（角色的整个目录 / 动态立绘的帧序列目录）。
## ⚠️ 先关掉 DirAccess 句柄再删目录本身 —— 句柄还开着时删不掉。
func _delete_dir_recursive(path: String) -> void:
	# ⚠️ 最深的落盘点，也放一道闸 —— 递归调用时每层都过一遍，成本可以忽略
	if not _safe_target(path):
		return
	_log_op("delete-dir", path)
	var abs := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	var files := PackedStringArray()
	var dirs := PackedStringArray()
	var d := DirAccess.open(abs)
	if d != null:
		files = d.get_files()
		dirs = d.get_directories()
	d = null
	for f in files:
		DirAccess.remove_absolute(abs + String(f))
	for sub in dirs:
		_delete_dir_recursive(path + String(sub) + "/")
	DirAccess.remove_absolute(abs)


## 素材文件变了之后的统一收尾：重扫索引、清缩略图缓存、重建网格。
##
## 还要顺手作废剧本块的缓存 —— 它的素材 / 表情下拉是建行时生成的，
## 不做这一步，刚导入的素材不会出现在已有行的下拉里。
func _after_asset_change() -> void:
	_thumb_cache.clear()
	_ed.index.scan()
	_ed._refresh_index_summary()
	_ed.invalidate_asset_views()
	rebuild()


# ---------------------------------------------------------------------------
# 导入
# ---------------------------------------------------------------------------

func _open_import(target_group: String = "") -> void:
	# 立绘是两级目录（角色/表情），平铺导入会落到 assets/sprites/ 根下 ——
	# 所以立绘页的「+」走新建角色，加表情要到角色合集里导。
	if _kind == "char":
		_open_new_char_dialog()
		return
	_import_mode = "flat"
	_import_kind = _kind
	_import_char = ""
	_import_group = target_group
	_file_dialog.clear_filters()
	var exts := "*.png,*.jpg,*.jpeg,*.webp" if _kind in ["bg", "cg"] else \
		("*.ogv" if _kind == "video" else "*.ogg,*.mp3,*.wav")
	_file_dialog.add_filter(exts, String(ProjectIndex.KIND_LABELS.get(_kind, _kind)))
	var dir_hint := String(ProjectIndex.KIND_DIRS[_kind])
	if _kind == "voice" and not target_group.is_empty():
		dir_hint = dir_hint + target_group + "/"
	_file_dialog.title = "导入到 %s" % dir_hint
	_file_dialog.popup_centered_ratio(0.7)


func _open_char_import(cid: String) -> void:
	_import_mode = "char_expr"
	_import_char = cid
	_import_kind = "char"
	_file_dialog.clear_filters()
	_file_dialog.add_filter("*.png,*.jpg,*.jpeg,*.webp", "立绘图片")
	_file_dialog.title = "导入 %s 的立绘（文件名 = 表情名）" % cid
	_file_dialog.popup_centered_ratio(0.7)


func _on_files_selected(paths: PackedStringArray) -> void:
	if _import_mode == "char_expr":
		_import_char_exprs(paths, _import_char)
	else:
		_import_flat(paths, _import_kind,
			_import_group if _import_kind == "voice" else "")


func _import_flat(paths: PackedStringArray, kind: String, group: String = "") -> void:
	# 分组素材（语音）要落到 `<根>/<组>/` 下，id 才是 `<组>/<文件名>`
	var dir_path := String(ProjectIndex.KIND_DIRS[kind])
	if not group.is_empty():
		dir_path = dir_path + group + "/"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var copied := 0
	var skipped: Array = []

	for src in paths:
		var s := String(src)
		var base := _normalize_id(s.get_file().get_basename())
		var ext := s.get_extension().to_lower()
		if base.is_empty():
			skipped.append(s)
			continue
		var dst_name := "%s.%s" % [base, ext]
		if FileAccess.file_exists(dir_path + dst_name):
			# 已存在就换个名字，不覆盖 —— 覆盖会静默毁掉作者已有的素材
			dst_name = _unique_in_dir(dir_path, base, ext)
		if not _copy_file(s, dir_path + dst_name):
			skipped.append(s)
			continue
		copied += 1

	_after_import(copied, skipped, "%s%s" % [
		String(ProjectIndex.KIND_LABELS.get(kind, kind)),
		"" if group.is_empty() else " · %s" % group])


## 往某个角色的目录里导立绘：文件名（去后缀）就是表情 id。
func _import_char_exprs(paths: PackedStringArray, cid: String) -> void:
	var dir_path := String(ProjectIndex.KIND_DIRS["char"]) + cid + "/"
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path)):
		_ed._notice_flash("assets/sprites/%s/ 不存在，先新建角色" % cid, EdTheme.ERR)
		return
	var copied := 0
	var skipped: Array = []

	for src in paths:
		var s := String(src)
		var base := _normalize_id(s.get_file().get_basename())
		var ext := s.get_extension().to_lower()
		if base.is_empty() or not ProjectIndex.IMAGE_EXT.has(ext):
			skipped.append(s)
			continue
		var dst_name := "%s.%s" % [base, ext]
		if FileAccess.file_exists(dir_path + dst_name):
			dst_name = _unique_in_dir(dir_path, base, ext)
		if not _copy_file(s, dir_path + dst_name):
			skipped.append(s)
			continue
		copied += 1

	_after_import(copied, skipped, "%s 的立绘" % cid)
	if _gallery.visible and _gallery_group == cid:
		_open_gallery("char", cid)


func _after_import(copied: int, skipped: Array, what: String) -> void:
	_after_asset_change()
	var msg := "导入 %d 个文件到 %s" % [copied, what]
	if skipped.size() > 0:
		msg += "（%d 个跳过）" % skipped.size()
	if copied > 0:
		msg += " · 运行游戏前记得让 Godot 重新导入资源"
	_ed._notice_flash(msg, EdTheme.OK if copied > 0 else EdTheme.WARN)


static func _copy_file(src: String, dst: String) -> bool:
	var bytes := FileAccess.get_file_as_bytes(src)
	if bytes.is_empty():
		return false
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	f.close()
	return true


## 目录内不重名的文件名。
## ⚠️ 不能用 `ProjectIndex.unique_file_name` —— 那个按**类别目录**拼路径，
## 而立绘要多一层 `<角色>/`，直接用它会把文件判成「不冲突」然后覆盖掉。
static func _unique_in_dir(dir_path: String, base: String, ext: String) -> String:
	var cand := "%s.%s" % [base, ext]
	var n := 2
	while FileAccess.file_exists(dir_path + cand):
		cand = "%s_%d.%s" % [base, n, ext]
		n += 1
	return cand


## 文件名 → 规范 id：小写、空格与连字符转下划线、去掉其它非法字符
static func _normalize_id(name: String) -> String:
	var s := name.to_lower().strip_edges()
	s = s.replace(" ", "_").replace("-", "_")
	var out := ""
	for i in s.length():
		var c := s[i]
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_":
			out += c
	return out
