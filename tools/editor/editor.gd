extends Control

## GVS 编辑器 —— 主控
##
## 跑法：
##   godot --path . res://tools/editor/editor.tscn
##
## 定位：**项目内的独立工具场景**，与游戏共享同一套代码
## （GvsParser / ScriptAudit / Stage / UiTheme），但不是游戏的一部分 ——
## 游戏跑 main.tscn 时完全不加载它，导出游戏包时可以整个目录排除。
##
## 职责：
##   - 建三栏布局，管理页面切换
##   - 持有文档 / 索引 / 文件监听三个核心对象
##   - 把「文档变了」这件事广播给所有面板
##   - 处理外部改动（AI 直接改 .gvs 之后界面自动跟上）
##
## 架构上刻意不放在 `scripts/` 下 —— 那里有 smoke 第 27 节的架构守卫
## （core/autoload 不许引用表现层、ui/stage 不许引用编排层）。
## 编辑器天然要同时引用 `Stage`（预览）与 `GvsParser`（core），
## 放在 `tools/editor/` 既避开守卫，语义上也正确：它是工具，不是游戏代码。

const EdTheme = preload("res://tools/editor/ed_theme.gd")
const ScriptDoc = preload("res://tools/editor/core/script_doc.gd")
const ProjectIndex = preload("res://tools/editor/core/project_index.gd")
const FileWatcher = preload("res://tools/editor/core/file_watcher.gd")
const ScriptPaths = preload("res://scripts/core/script_paths.gd")
const ScriptStats = preload("res://scripts/core/script_stats.gd")

const ScriptPanel = preload("res://tools/editor/panels/script_panel.gd")
const IssuePanel = preload("res://tools/editor/panels/issue_panel.gd")
const PreviewPanel = preload("res://tools/editor/panels/preview_panel.gd")
const TablePanel = preload("res://tools/editor/panels/table_panel.gd")
const GraphPanel = preload("res://tools/editor/panels/graph_panel.gd")
const AssetPanel = preload("res://tools/editor/panels/asset_panel.gd")
const I18nPanel = preload("res://tools/editor/panels/i18n_panel.gd")
const SearchPanel = preload("res://tools/editor/panels/search_panel.gd")
const VarPanel = preload("res://tools/editor/panels/var_panel.gd")
const VarIndex = preload("res://tools/editor/core/var_index.gd")

## 核心对象
var doc: ScriptDoc
var index: ProjectIndex
var watcher: FileWatcher

## 当前光标行（1 基）
var caret_line: int = 1

var _topbar: Control
var _file_list: VBoxContainer
var _chapter_list: VBoxContainer
var _index_box: VBoxContainer
var _var_box: VBoxContainer
var _page_holder: Control
var _right_pane: Control
var _status: Label
var _title_label: Label
var _notice: Label
var _main_split: VSplitContainer
var _bottombar: Control
var _btn_issues: Button
var _help: AcceptDialog

var _pages: Dictionary = {}
var _chips: Dictionary = {}
var _current_page := "script"
var _script_panel
var _issue_panel
var _preview_panel

var _last_doc_revision := -1
var _notice_until := 0
var _conflict: ConfirmationDialog
var _new_dialog: ConfirmationDialog
var _new_name: LineEdit
var _rename_dialog: ConfirmationDialog
var _rename_name: LineEdit
var _rename_src := ""
var _delete_dialog: ConfirmationDialog
var _delete_src := ""


func _ready() -> void:
	# 编辑器比游戏需要更大的工作区
	if DisplayServer.get_name() != "headless":
		var screen := DisplayServer.screen_get_usable_rect().size
		var want := Vector2i(1680, 980)
		DisplayServer.window_set_size(Vector2i(
			mini(want.x, screen.x - 60), mini(want.y, screen.y - 60)))
		DisplayServer.window_set_title("GVS 编辑器 — Galgame Skeleton")

	doc = ScriptDoc.new()
	# **关掉自动写盘**：编辑时只改内存，Ctrl+S 才落盘。
	# 代价是工具手里会有未保存改动，所以外部改动不能再「静默整体重载」，
	# 必须弹冲突提示（见 `_on_external_change` / `_save`）。
	doc.auto_save = false
	index = ProjectIndex.new()
	index.scan()
	watcher = FileWatcher.new()

	_build()
	_build_conflict_dialog()
	_build_new_script_dialog()
	_build_rename_dialog()
	_build_delete_dialog()

	_script_panel.refresh_speakers(index.char_ids())

	# 打开入口剧本
	var entry := ScriptPaths.entry()
	_open(entry, true)

	_refresh_files()
	_refresh_index_summary()
	_issue_panel.refresh(true)
	_push_issues()

	# 面板建好后必须显式切一次首页 —— `_build_body()` 里所有页面初始都是
	# visible = false，不切的话中间会是一片空白
	show_page("script")


## 保存冲突：磁盘上的文件被别人改过，或者我们手里有未保存改动
func _build_conflict_dialog() -> void:
	_conflict = ConfirmationDialog.new()
	_conflict.title = "保存冲突"
	_conflict.ok_button_text = "覆盖磁盘"
	_conflict.cancel_button_text = "加载外部版本"
	_conflict.confirmed.connect(func() -> void: _save(true))
	_conflict.canceled.connect(_discard_and_reload)
	add_child(_conflict)


## 「新建剧本」对话框 —— 一个输入框 + 两条说明
func _build_new_script_dialog() -> void:
	_new_dialog = ConfirmationDialog.new()
	_new_dialog.title = "新建剧本"
	_new_dialog.ok_button_text = "创建"
	_new_dialog.cancel_button_text = "取消"
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.add_child(EdTheme.label("会创建 data/scripts/<名字>.gvs，并带一个最小骨架",
		EdTheme.FS_SMALL, EdTheme.TEXT_DIM))
	_new_name = LineEdit.new()
	_new_name.placeholder_text = "例如 chapter2"
	_new_name.custom_minimum_size = Vector2(300, 0)
	EdTheme.style_line_edit(_new_name)
	v.add_child(_new_name)
	v.add_child(EdTheme.label("只能用 小写字母 / 数字 / 下划线；已存在会拒绝",
		EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))
	_new_dialog.add_child(v)
	_new_dialog.confirmed.connect(_create_script)
	add_child(_new_dialog)


func _open_new_script_dialog() -> void:
	_new_name.text = ""
	_new_dialog.popup_centered()


# ---------------------------------------------------------------------------
# 重命名 / 删除剧本
# ---------------------------------------------------------------------------

func _build_rename_dialog() -> void:
	_rename_dialog = ConfirmationDialog.new()
	_rename_dialog.title = "重命名剧本"
	_rename_dialog.ok_button_text = "重命名"
	_rename_dialog.cancel_button_text = "取消"
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_rename_name = LineEdit.new()
	_rename_name.placeholder_text = "新的文件名（不含 .gvs）"
	_rename_name.custom_minimum_size = Vector2(300, 0)
	EdTheme.style_line_edit(_rename_name)
	v.add_child(_rename_name)
	v.add_child(EdTheme.label("只能用 小写字母 / 数字 / 下划线；已存在会拒绝",
		EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))
	_rename_dialog.add_child(v)
	_rename_dialog.confirmed.connect(_do_rename)
	add_child(_rename_dialog)


func _build_delete_dialog() -> void:
	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.title = "删除剧本"
	_delete_dialog.ok_button_text = "删除"
	_delete_dialog.cancel_button_text = "取消"
	_delete_dialog.confirmed.connect(_do_delete)
	add_child(_delete_dialog)


func _open_rename(path: String) -> void:
	# 手动保存模式下，手里有未保存改动时去改文件名会把改动弄丢 —— 先拦住
	if doc != null and doc.is_dirty():
		_notice_flash("先保存当前剧本（Ctrl+S）再重命名", EdTheme.WARN)
		return
	if path == ScriptPaths.entry():
		_notice_flash("入口剧本 %s 写死在 ScriptPaths.entry()，改名后游戏会找不到入口"
			% path.get_file(), EdTheme.ERR)
		return
	_rename_src = path
	_rename_name.text = path.get_file().get_basename()
	_rename_name.select_all()
	_rename_dialog.dialog_text = ("把 %s 改成别的名字。\n"
		+ "chapters.json / cg.json / 各剧本里的 jump_file 路径会一并改掉。") % path.get_file()
	_rename_dialog.popup_centered()


func _do_rename() -> void:
	var old := _rename_src
	_rename_src = ""
	_rename_dialog.hide()
	if old.is_empty():
		return
	var name := sanitize_script_name(_rename_name.text)
	if name.is_empty():
		_notice_flash("文件名只能用 小写字母 / 数字 / 下划线", EdTheme.ERR)
		return
	var new_path := "res://data/scripts/%s.gvs" % name
	if new_path == old:
		return
	if FileAccess.file_exists(new_path):
		_notice_flash("%s 已存在，换个名字" % new_path.get_file(), EdTheme.ERR)
		return

	var abs_old := ProjectSettings.globalize_path(old)
	var abs_new := ProjectSettings.globalize_path(new_path)
	if DirAccess.rename_absolute(abs_old, abs_new) != OK:
		_notice_flash("重命名失败：%s" % old, EdTheme.ERR)
		return
	for suffix in [".import", ".uid"]:
		if FileAccess.file_exists(old + suffix):
			DirAccess.rename_absolute(ProjectSettings.globalize_path(old + suffix),
				ProjectSettings.globalize_path(new_path + suffix))

	var n := _rewrite_script_refs(old, new_path)
	ScriptStats.clear_cache()

	# 改的是当前打开的文件 → 文档要跟着换路径，否则下一次保存会写回旧名字
	if doc != null and doc.path == old:
		watcher.unwatch(old)
		doc.load_from_disk(new_path)
		watcher.watch(new_path)
		_script_panel.load_doc()
		_script_panel.refresh_labels(doc.labels())
		_last_doc_revision = doc.revision
		_title_label.text = new_path.get_file()

	_refresh_files()
	_refresh_status()
	_issue_panel.refresh(true)
	_push_issues()
	_notice_flash("已重命名为 %s（同步了 %d 处引用）" % [new_path.get_file(), n], EdTheme.OK)


func _open_delete(path: String) -> void:
	if doc != null and doc.is_dirty():
		_notice_flash("先保存当前剧本（Ctrl+S）再删除", EdTheme.WARN)
		return
	if path == ScriptPaths.entry():
		_notice_flash("入口剧本 %s 写死在 ScriptPaths.entry()，删了游戏就起不来"
			% path.get_file(), EdTheme.ERR)
		return
	if doc != null and doc.path == path and _first_other_script(path).is_empty():
		_notice_flash("这是最后一个剧本，不能删", EdTheme.ERR)
		return
	_delete_src = path
	var refs := _count_script_refs(path)
	var tail := "" if refs == 0 else \
		"\n\n⚠ 还有 %d 处引用指向它（chapters.json / cg.json / jump_file），删除后会变成死链。" % refs
	_delete_dialog.dialog_text = "删除 %s？%s" % [path.get_file(), tail]
	_delete_dialog.popup_centered()


func _do_delete() -> void:
	var path := _delete_src
	_delete_src = ""
	_delete_dialog.hide()
	if path.is_empty():
		return
	# 删的是当前打开的那个 → 先切走（`_open` 会先 flush / 保存）
	if doc != null and doc.path == path:
		var other := _first_other_script(path)
		if other.is_empty():
			_notice_flash("这是最后一个剧本，不能删", EdTheme.ERR)
			return
		_open(other)

	watcher.unwatch(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for suffix in [".import", ".uid"]:
		if FileAccess.file_exists(path + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))
	ScriptStats.clear_cache()

	_refresh_files()
	_refresh_status()
	_issue_panel.refresh(true)
	_push_issues()
	_notice_flash("已删除 %s" % path.get_file(), EdTheme.OK)


## 文件名 → 合法剧本名（小写字母 / 数字 / 下划线）。
## 新建与重命名共用一份，免得两边的规则慢慢漂开。
static func sanitize_script_name(raw: String) -> String:
	var s := raw.strip_edges().to_lower()
	var out := ""
	for i in s.length():
		var c := s[i]
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_":
			out += c
	return out


## 数一数有多少处引用指向这个剧本文件。
## 删除前拿来提示「删了会留下几条死链」—— 不做静默清理：
## 章节条目、重播片段、跳转都是创作决定，工具替作者删容易删错。
func _count_script_refs(path: String) -> int:
	var n := 0
	for p in [ScriptPaths.CHAPTERS, "res://data/collection/cg.json"]:
		if FileAccess.file_exists(p) and FileAccess.get_file_as_string(p).contains(path):
			n += 1
	for p in ScriptStats.script_files():
		var s := String(p)
		if s == path:
			continue
		var t := FileAccess.get_file_as_string(ScriptPaths.resolve(s))
		if not t.is_empty() and t.contains(path):
			n += 1
	return n


## 把指向某个剧本的引用从 old_path 改到 new_path，返回改动过的文件数。
##
## 三处：chapters.json 的 file、cg.json 的 file（重播片段）、各 .gvs 里的
## `jump_file <路径>`。**用纯文本替换而不是重新序列化 JSON** ——
## 那两个 json 是人工维护的（带 `_comment`、带缩进），重新 dump 会把格式和注释一起冲掉。
func _rewrite_script_refs(old_path: String, new_path: String) -> int:
	var changed := 0
	var targets: Array = [ScriptPaths.CHAPTERS, "res://data/collection/cg.json"]
	for p in targets:
		var sp := String(p)
		if not FileAccess.file_exists(sp):
			continue
		var text := FileAccess.get_file_as_string(sp)
		if not text.contains(old_path):
			continue
		var f := FileAccess.open(sp, FileAccess.WRITE)
		if f == null:
			continue
		f.store_string(text.replace(old_path, new_path))
		f.close()
		changed += 1

	for p in ScriptStats.script_files():
		var s := String(p)
		if s == new_path:
			continue
		var real := ScriptPaths.resolve(s)
		var text2 := FileAccess.get_file_as_string(real)
		if text2.is_empty() or not text2.contains(old_path):
			continue
		var f2 := FileAccess.open(real, FileAccess.WRITE)
		if f2 == null:
			continue
		f2.store_string(text2.replace(old_path, new_path))
		f2.close()
		changed += 1
	return changed


## 除了 except_path 之外，下一个可以打开的剧本（优先入口剧本）
func _first_other_script(except_path: String) -> String:
	var entry := ScriptPaths.entry()
	if entry != except_path and FileAccess.file_exists(entry):
		return entry
	for p in ScriptStats.script_files():
		if String(p) != except_path:
			return String(p)
	return ""


func _create_script() -> void:
	var name := sanitize_script_name(_new_name.text)
	if name.is_empty():
		_notice_flash("文件名只能用 小写字母 / 数字 / 下划线", EdTheme.ERR)
		return
	var path := "res://data/scripts/%s.gvs" % name
	if FileAccess.file_exists(path):
		_notice_flash("%s 已存在，换个名字" % path.get_file(), EdTheme.ERR)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_notice_flash("写不进 %s" % path, EdTheme.ERR)
		return
	f.store_string(_new_script_template(name))
	f.close()
	ScriptStats.clear_cache()
	_refresh_files()
	_open(path)
	_issue_panel.refresh(true)
	_push_issues()
	_notice_flash("已创建 %s —— 要变成章节的话，去 data/scripts/chapters.json 登记"
		% path.get_file(), EdTheme.OK)


## 新剧本的骨架。
##
## **刻意不自动改 chapters.json** —— 那是人工排的目录（顺序、标题都是创作决定），
## 工具替作者改容易把目录弄乱；只在注释与提示里说清「怎么接进主流程」。
static func _new_script_template(name: String) -> String:
	return "\n".join(PackedStringArray([
		"# %s.gvs" % name,
		"# 由编辑器创建。",
		"#",
		"# 接进主流程的两种方式：",
		"#   1. 从别的剧本里写 `jump_file res://data/scripts/%s.gvs start`" % name,
		"#   2. 在 data/scripts/chapters.json 里登记成章节（标题 + 本文件 + 起始标签）",
		"",
		"label start",
		"narr （在这里开始写。）",
		"",
	])) + "\n"


# ---------------------------------------------------------------------------
# 布局
# ---------------------------------------------------------------------------

func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = EdTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	_topbar = _build_topbar()
	root.add_child(_topbar)

	# 中栏 + 底部问题面板装进 VSplitContainer：
	# 校验区能拖高看全，也能一键收起把纵向空间全让给编辑区。
	# 注意 VSplitContainer 会**跳过不可见的子节点**，所以「收起」= 直接把面板 hide。
	_main_split = VSplitContainer.new()
	_main_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main_split.add_theme_constant_override("separation", 0)
	root.add_child(_main_split)

	_main_split.add_child(_build_body())
	_bottombar = _build_bottombar()
	_main_split.add_child(_bottombar)


func _build_topbar() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_PANEL, 0, 12, 7, EdTheme.BORDER, 1))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	bar.add_child(h)

	_title_label = EdTheme.label("（未打开）", EdTheme.FS_TITLE, EdTheme.TEXT)
	h.add_child(_title_label)

	_status = EdTheme.label("", EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	h.add_child(_status)

	h.add_child(_vsep())

	# 剧本视图
	for spec in [["script", "源码"], ["table", "剧本块"], ["graph", "分支图"]]:
		var key := String(spec[0])
		var b := EdTheme.chip(String(spec[1]))
		b.pressed.connect(func() -> void: show_page(key))
		h.add_child(b)
		_chips[key] = b

	h.add_child(_vsep())

	# 工具页
	for spec in [["asset", "素材"], ["search", "搜索"], ["i18n", "翻译"]]:
		var key := String(spec[0])
		var b := EdTheme.chip(String(spec[1]))
		b.pressed.connect(func() -> void: show_page(key))
		h.add_child(b)
		_chips[key] = b

	h.add_child(EdTheme.hfill())

	_notice = EdTheme.label("", EdTheme.FS_SMALL, EdTheme.WARN)
	h.add_child(_notice)

	var btn_rescan := EdTheme.chip("重新扫描")
	btn_rescan.tooltip_text = "重扫素材索引并重新校验（导入新素材后用）"
	btn_rescan.pressed.connect(_rescan)
	h.add_child(btn_rescan)

	_btn_issues = EdTheme.chip("问题 ▾")
	_btn_issues.tooltip_text = "收起 / 展开底部的问题面板（也可以直接拖分隔条调高）"
	_btn_issues.pressed.connect(_toggle_issues)
	h.add_child(_btn_issues)

	var btn_help := EdTheme.chip("?")
	btn_help.tooltip_text = "快捷键一览（F1）"
	btn_help.pressed.connect(_open_shortcuts)
	h.add_child(btn_help)

	return bar


## 收起 / 展开底部的问题面板
func _toggle_issues() -> void:
	if _bottombar == null:
		return
	_bottombar.visible = not _bottombar.visible
	if _btn_issues != null:
		_btn_issues.text = "问题 ▾" if _bottombar.visible else "问题 ▸"
		EdTheme.style_chip(_btn_issues, not _bottombar.visible)


# ---------------------------------------------------------------------------
# 快捷键一览
# ---------------------------------------------------------------------------

## 编辑器里所有会「按一下有反应」的键 + 一份台词内联标记速查。
## 集中写在这里而不是散在 README 里 —— 加键 / 加标记的时候不容易忘。
const SHORTCUTS := [
	["全局", [
		["Ctrl+S", "保存当前剧本（平时只改内存）"],
		["Ctrl+Z / Ctrl+Y", "撤销 / 重做（源码页归 CodeEdit 自己的撤销栈）"],
		["Ctrl+R", "重新扫描素材索引"],
		["Ctrl+Shift+F", "全局搜索（跨全部剧本）"],
		["Ctrl+F", "剧本块内查找（仅「剧本块」页）"],
		["F5", "从当前行开始预览"],
		["F1 / ?", "这个面板"],
	]],
	["剧本块（对白表格）", [
		["点整行 / ↑ / ↓", "选中行 / 换行"],
		["Enter", "在选中行下方插入一条对白，并聚焦台词框"],
		["台词框里 Enter", "提交这一句并接下一行"],
		["Backspace / Delete", "删除选中行（结构行会先确认）"],
		["Esc", "退出编辑态 / 关闭查找条"],
		["Ctrl+V", "剪贴板多行时自动拆成多条对白"],
	]],
	["素材页", [
		["卡片右上角 ✎ / ✕", "重命名 / 删除这个素材"],
		["网格末尾 ＋", "导入素材（立绘页是新建角色）"],
		["把文件拖进来", "直接导入（立绘要拖到某个角色卡片上）"],
		["↶ 撤销", "撤销上一次素材操作（含剧本引用）"],
	]],
	["左侧「剧本」列表", [
		["⋯", "重命名 / 删除这个剧本"],
		["+ 新建", "新建一个 .gvs"],
	]],
	# 这些不是键，而是**直接敲在台词正文里**的标记 —— 它们是作者最常查的东西，
	# 跟快捷键一起放在这个面板里最省事（不必翻手册）。预览窗口会正确剥掉它们。
	["台词内联标记（写在台词里）", [
		["[wait=0.5]", "停顿 0.5 秒后自动继续"],
		["[stop]", "停下等点击（[click] 是别名）"],
		["[speed=3]…[/speed]", "这一段按 3 倍速显示"],
		["[fx=glitch]", "在此处触发音频效果器（bus= / dur= / pitch= 可调）"],
		["[shake] [bounce] [glitch]", "文字特效（详见 GVS-剧本语法手册 §8）"],
	]],
]


func _open_shortcuts() -> void:
	if _help == null:
		_help = AcceptDialog.new()
		_help.title = "快捷键与台词标记"
		_help.ok_button_text = "知道了"
		_help.min_size = Vector2i(560, 0)

		var root := VBoxContainer.new()
		root.add_theme_constant_override("separation", 10)
		_help.add_child(root)

		for group in SHORTCUTS:
			var g: Array = group
			var title := EdTheme.label(String(g[0]), EdTheme.FS_SMALL, EdTheme.ACCENT)
			root.add_child(title)

			var grid := GridContainer.new()
			grid.columns = 2
			grid.add_theme_constant_override("h_separation", 16)
			grid.add_theme_constant_override("v_separation", 2)
			root.add_child(grid)

			for item in (g[1] as Array):
				var row: Array = item
				var key_l := EdTheme.mono_label(String(row[0]), EdTheme.FS_SMALL, EdTheme.TEXT)
				key_l.custom_minimum_size = Vector2(170, 0)
				grid.add_child(key_l)
				grid.add_child(EdTheme.label(String(row[1]), EdTheme.FS_SMALL, EdTheme.TEXT_DIM))

		add_child(_help)
	_help.popup_centered()


func _build_body() -> Control:
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 0)

	# --- 左栏 ---
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(186, 0)
	left.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_PANEL, 0, 10, 10, EdTheme.BORDER, 1))
	split.add_child(left)

	var lscroll := ScrollContainer.new()
	lscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(lscroll)

	var lv := VBoxContainer.new()
	lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv.add_theme_constant_override("separation", 3)
	lscroll.add_child(lv)

	# 「剧本」= data/scripts/ 下的每个 .gvs 文件；
	# 「章节」= chapters.json 里人工排的目录（章节标题 → 某个文件 + 起始标签）。
	# 两者不是一回事：一个文件可以不属于任何章节，一个章节也可以指向别的文件里的标签。
	lv.add_child(_section_action("剧本", "+ 新建", "data/scripts/ 下的每个 .gvs 文件",
		func() -> void: _open_new_script_dialog()))
	_file_list = VBoxContainer.new()
	_file_list.add_theme_constant_override("separation", 1)
	lv.add_child(_file_list)

	lv.add_child(_section_action("章节", "", "chapters.json 里人工排的目录：章节标题 → 文件 + 起始标签",
		Callable()))
	_chapter_list = VBoxContainer.new()
	_chapter_list.add_theme_constant_override("separation", 1)
	lv.add_child(_chapter_list)

	lv.add_child(_section_action("变量", "详细", "旗标 / 变量 / 好感度：谁写谁读。有问题的排在前面，点一条跳到第一处",
		func() -> void: show_page("var")))
	_var_box = VBoxContainer.new()
	_var_box.add_theme_constant_override("separation", 1)
	lv.add_child(_var_box)

	lv.add_child(_section("项目"))
	_index_box = VBoxContainer.new()
	_index_box.add_theme_constant_override("separation", 1)
	lv.add_child(_index_box)

	# --- 中栏 ---
	var center := PanelContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG, 0, 0, 0, EdTheme.BORDER, 1))
	split.add_child(center)

	# 必须用 **Container** 而不是普通 Control 来承载页面：
	# 普通 Control 的子节点靠锚点定位，而锚点布局只在父节点尺寸变化时重算 ——
	# 页面创建时是隐藏的（visible=false），隐藏节点收不到这次重算，
	# 于是 size 永远停在 (0,0)，切过去就是一片空白。
	# Container 会主动给可见子节点分配尺寸，隐藏的自动跳过，正合「多页面切换」。
	_page_holder = MarginContainer.new()
	_page_holder.clip_contents = true
	center.add_child(_page_holder)

	_script_panel = ScriptPanel.new()
	_script_panel.visible = false
	_page_holder.add_child(_script_panel)
	_script_panel.setup(self)
	_script_panel.caret_moved.connect(_on_caret_moved)
	_script_panel.committed.connect(_on_doc_committed)
	_pages["script"] = _script_panel

	# --- 右栏 ---
	# 宽度给足：这栏装的是 16:9 的演出预览，322 时画面只有 322×181，
	# 连对话框里的字都看不清。分隔条本身可以拖，这里只定一个能用的起点。
	_right_pane = PanelContainer.new()
	_right_pane.custom_minimum_size = Vector2(430, 0)
	_right_pane.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_PANEL, 0, 10, 10, EdTheme.BORDER, 1))
	split.add_child(_right_pane)

	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 8)
	_right_pane.add_child(rv)

	_preview_panel = PreviewPanel.new()
	_preview_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rv.add_child(_preview_panel)
	_preview_panel.setup(self)

	return split


func _build_bottombar() -> Control:
	var bar := PanelContainer.new()
	bar.custom_minimum_size = Vector2(0, 132)
	bar.add_theme_stylebox_override("panel",
		EdTheme.sb(EdTheme.BG_PANEL, 0, 10, 6, EdTheme.BORDER, 1))

	_issue_panel = IssuePanel.new()
	bar.add_child(_issue_panel)
	_issue_panel.setup(self)
	_issue_panel.issue_activated.connect(_on_issue_activated)

	return bar


func _section(text: String) -> Control:
	var l := EdTheme.label(text, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	l.custom_minimum_size = Vector2(0, 24)
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	return l


## 小节标题 + 一个可选的操作按钮（例如「剧本」旁边的「+ 新建」）。
## `action_text` 为空时就是一个带 tooltip 的普通标题。
func _section_action(text: String, action_text: String, tip: String,
		cb: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.custom_minimum_size = Vector2(0, 24)

	var l := EdTheme.label(text, EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	l.tooltip_text = tip
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)

	if not action_text.is_empty():
		var b := Button.new()
		b.text = action_text
		b.flat = true
		b.custom_minimum_size = Vector2(0, 20)
		b.tooltip_text = tip
		b.add_theme_font_override("font", EdTheme.ui())
		b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
		b.add_theme_color_override("font_color", EdTheme.TEXT_DIM)
		b.add_theme_color_override("font_hover_color", EdTheme.ACCENT)
		b.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 3, 6, 1))
		b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 6, 1))
		b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 6, 1))
		b.pressed.connect(func() -> void: cb.call())
		row.add_child(b)

	return row


func _vsep() -> Control:
	var s := VSeparator.new()
	s.add_theme_stylebox_override("separator", EdTheme.sb(EdTheme.BORDER, 0, 0, 0))
	s.custom_minimum_size = Vector2(1, 0)
	return s


# ---------------------------------------------------------------------------
# 页面切换
# ---------------------------------------------------------------------------

## 页面按需创建 —— 分支图 / 素材 / 翻译都是重面板，
## 一上来全建好会拖慢启动，而且它们要等索引扫完才有意义。
func show_page(name: String) -> void:
	if not _pages.has(name):
		var p := _make_page(name)
		if p == null:
			return
		p.visible = false
		_page_holder.add_child(p)
		p.setup(self)
		_pages[name] = p

	for key in _pages.keys():
		(_pages[key] as Control).visible = (String(key) == name)
	for key in _chips.keys():
		EdTheme.style_chip(_chips[key] as Button, String(key) == name)

	_current_page = name
	# 预览只对剧本类页面有意义
	_right_pane.visible = name in ["script", "table", "graph"]

	# 切到某个页面时让它自己刷新一次
	var page: Control = _pages[name]
	if page.has_method("on_shown"):
		page.call("on_shown")

	if name == "script":
		# 切回源码页时把「被面板改过」的内容补上（懒同步，见 ScriptPanel）
		_script_panel.sync_if_stale()
		_script_panel.goto_line(caret_line, false)
	elif _current_page == "table" and page.has_method("goto_line"):
		page.call("goto_line", caret_line)


func _make_page(name: String) -> Control:
	match name:
		"table":
			return TablePanel.new()
		"graph":
			return GraphPanel.new()
		"asset":
			return AssetPanel.new()
		"search":
			return SearchPanel.new()
		"var":
			return VarPanel.new()
		"i18n":
			return I18nPanel.new()
	return null


# ---------------------------------------------------------------------------
# 文件
# ---------------------------------------------------------------------------

func _refresh_files() -> void:
	for c in _file_list.get_children():
		c.queue_free()

	for path in ScriptStats.script_files():
		_file_list.add_child(_script_row(String(path)))

	# 章节
	for c in _chapter_list.get_children():
		c.queue_free()
	for entry in ScriptStats.chapters():
		var ch: Dictionary = entry
		var b := Button.new()
		b.text = String(ch.get("title", "?"))
		b.flat = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 24)
		b.add_theme_font_override("font", EdTheme.ui())
		b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
		b.add_theme_color_override("font_color", EdTheme.TEXT_DIM)
		b.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 3, 6, 1))
		b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 6, 1))
		b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 6, 1))
		var file := String(ch.get("file", ""))
		var label := String(ch.get("label", ""))
		b.tooltip_text = "%s → %s" % [file, label]
		b.pressed.connect(func() -> void: _open_at_label(file, label))
		_chapter_list.add_child(b)


## 左侧「剧本」列表的一行：文件名 + 「⋯」操作菜单（重命名 / 删除）。
##
## 为什么用常驻的「⋯」而不是右键菜单当唯一入口：左栏很窄、右键是隐藏操作，
## 作者不一定想得到；菜单本身只在代码里建一个 PopupMenu，不占版面。
## ⚠️ 回调里要用的 `p` 是**按值捕获**的字符串，不是行号 ——
## 刷新会重建整行，没有「行号错位」这类问题。
func _script_row(p: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)

	var is_cur := (doc != null and doc.path == p)
	var b := Button.new()
	b.text = p.get_file()
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.custom_minimum_size = Vector2(0, 24)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.tooltip_text = p
	b.add_theme_font_override("font", EdTheme.ui())
	b.add_theme_font_size_override("font_size", EdTheme.FS_UI)
	b.add_theme_color_override("font_color", EdTheme.ACCENT if is_cur else EdTheme.TEXT_DIM)
	b.add_theme_stylebox_override("normal",
		EdTheme.sb(EdTheme.SEL_BG if is_cur else Color(0, 0, 0, 0), 3, 6, 1))
	b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 6, 1))
	b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 6, 1))
	b.pressed.connect(func() -> void: _open(p))
	row.add_child(b)

	var more := Button.new()
	more.text = "⋯"
	more.flat = true
	more.custom_minimum_size = Vector2(20, 24)
	more.tooltip_text = "重命名 / 删除"
	more.add_theme_font_override("font", EdTheme.ui())
	more.add_theme_font_size_override("font_size", EdTheme.FS_UI)
	more.add_theme_color_override("font_color", EdTheme.TEXT_FAINT)
	more.add_theme_color_override("font_hover_color", EdTheme.ACCENT)
	more.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 3, 2, 1))
	more.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 2, 1))
	more.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 2, 1))
	row.add_child(more)

	# 每个文件一个菜单：挂在行下面，只在点「⋯」时才弹出
	var menu := EdTheme.style_popup(PopupMenu.new())
	menu.add_item("重命名", 0)
	menu.add_item("删除", 1)
	menu.id_pressed.connect(func(id: int) -> void:
		if id == 0:
			_open_rename(p)
		else:
			_open_delete(p))
	more.pressed.connect(func() -> void:
		menu.popup(Rect2i(
			Vector2i(more.get_screen_position()) + Vector2i(0, int(more.size.y)),
			Vector2i.ZERO)))
	row.add_child(menu)

	return row


func _refresh_index_summary() -> void:
	for c in _index_box.get_children():
		c.queue_free()

	var rows := [
		["背景", index.count("bg")],
		["CG", index.count("cg")],
		["立绘", index.char_ids().size()],
		["音乐", index.count("bgm")],
		["音效", index.count("se")],
		["语音", index.count("voice")],
		["视频", index.count("video")],
	]
	for r in rows:
		var row := HBoxContainer.new()
		var k := EdTheme.label(String(r[0]), EdTheme.FS_SMALL, EdTheme.TEXT_FAINT)
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(k)
		row.add_child(EdTheme.label(str(r[1]), EdTheme.FS_SMALL, EdTheme.TEXT_DIM))
		_index_box.add_child(row)

	var missing: Dictionary = index.missing()
	var total_missing := 0
	for kind in missing.keys():
		total_missing += (missing[kind] as Array).size()
	if total_missing > 0:
		_index_box.add_child(EdTheme.label("缺 %d 项素材" % total_missing,
			EdTheme.FS_SMALL, EdTheme.WARN))
	# 变量清单不在这里 —— 它有自己的 `_refresh_vars()`（见 `_push_issues`）


## 打开一个剧本文件
func _open(path: String, initial: bool = false, keep_page: bool = false) -> void:
	if doc != null and doc.path == path and not initial:
		return
	if not initial:
		_script_panel.flush_now()
		# 手动保存模式下，切文件会把未保存的改动丢掉 —— 先落盘。
		# 落不下去（磁盘被外部改过）就先别切，交给用户裁决。
		if doc != null and doc.is_dirty():
			var r := doc.save()
			if not bool(r.get("ok", false)):
				_notice_flash("当前文件还没保存成功（%s），先处理它再切换"
					% String(r.get("message", "")), EdTheme.ERR)
				_conflict.dialog_text = ("磁盘上的 %s 已被外部修改，\n"
					+ "而编辑器里还有未保存的改动。\n\n"
					+ "【覆盖磁盘】用编辑器里的版本盖掉它\n"
					+ "【加载外部版本】丢弃编辑器里的改动") % doc.path.get_file()
				_conflict.popup_centered()
				return
			watcher.resync(doc.path)

	if not doc.load_from_disk(path):
		_notice_flash("打不开 %s" % path, EdTheme.ERR)
		return

	watcher.watch(path)
	_script_panel.load_doc()
	_script_panel.refresh_labels(doc.labels())
	caret_line = 1
	_last_doc_revision = doc.revision

	_title_label.text = path.get_file()
	_refresh_files()
	_refresh_status()
	_issue_panel.refresh(true)
	_push_issues()
	_preview_panel.show_line_state(caret_line)

	# 打开新文件后切到源码页是默认行为；但剧本块里的跳转链接要**留在剧本块**，
	# 否则用户点一下跳转就被打到源码页、丢掉正在看的位置。
	if not initial:
		if keep_page:
			_refresh_current_page()
		elif _current_page != "script":
			show_page("script")


func _open_at_label(file_path: String, label: String) -> void:
	_open(file_path)
	var no := doc.label_line(label)
	if no > 0:
		_script_panel.goto_line(no)


## 打开某个剧本并跳到某个标签 —— **留在剧本块页**。
##
## 剧本块里的跳转链接（含 `jump_file`）用它；会切到源码页的 `_open_at_label`
## 留给章节列表、问题列表那些地方。
func _open_at_label_in_table(file_path: String, label: String) -> void:
	_open(file_path, false, true)
	var table: Control = _pages.get("table")
	if table != null and table.has_method("goto_line") and doc != null:
		table.call("goto_line", doc.label_line(label))


## 按文件名打开剧本（素材详情、问题列表等处跳转用）
##
## 同时接受**完整逻辑路径**和**文件名** —— 调用方手里有哪个就传哪个。
## ⚠️ 只认文件名的话，传完整路径会静默什么都不做（`get_file()` 对不上），
## 表现成「点了没反应」，很难查。
func _open_at_file(file_name: String) -> void:
	for path in ScriptStats.script_files():
		var p := String(path)
		if p == file_name or p.get_file() == file_name:
			_open(p)
			return


func _on_issue_activated(file_name: String, line_no: int) -> void:
	if file_name.is_empty():
		return
	for path in ScriptStats.script_files():
		if String(path).get_file() == file_name:
			_open(String(path))
			if line_no > 0:
				_script_panel.goto_line(line_no)
			return
	# 不是剧本（可能是 chapters.json / cg.json 之类）
	_notice_flash("%s 不是剧本文件" % file_name, EdTheme.TEXT_FAINT)


# ---------------------------------------------------------------------------
# 同步与刷新
# ---------------------------------------------------------------------------

func _on_caret_moved(line_no: int) -> void:
	# 源码视图的光标**只在源码页才算数**。
	#
	# 别的页面（剧本块）有自己的「当前行」，由 `set_caret_from_panel`
	# 维护。而源码视图在那些页面里只是个后台控件：`load_doc()` / `sync_from_doc()`
	# 会把它整篇换掉、光标重置到第 1 行，CodeEdit 随后**延迟**发出 caret_changed。
	# 那个信号若照单全收，就会把面板的当前行拽回文件开头 ——
	# 表现出来就是「表格里改一下，状态条跳回第 1 行」「+ 添加对白 插到文件开头」。
	# 延迟发出意味着用「同步中」布尔量挡不住，必须按页面判。
	if _current_page != "script":
		return
	caret_line = line_no
	_preview_panel.show_line_state(line_no)


## 从其他面板（剧本块 / 分支图 / 问题列表）跳到源码视图的某一行
func goto_source(line_no: int) -> void:
	if _current_page != "script":
		show_page("script")
	_script_panel.goto_line(line_no)
	caret_line = line_no


## 面板（剧本块）把自己认定的「当前行」告诉主控。
##
## 与 `goto_source` 的区别：**不切页面**，只更新光标与预览。
##
## 为什么需要它：`caret_line` 以前只能由源码视图的 `caret_moved` 驱动，
## 于是「在表格里编辑」这件事根本没有机会更新它 —— 表格只能借用一个
## 跟它无关的光标行，而那个值又会被后台同步重置成 1。
func set_caret_from_panel(line_no: int) -> void:
	if doc == null:
		return
	var n := clampi(line_no, 1, maxi(1, doc.line_count()))
	caret_line = n
	_preview_panel.show_line_state(n)


func _on_doc_committed() -> void:
	# 击键稳定之后：刷新校验、刷新预览状态
	_issue_panel.refresh()
	_push_issues()
	_preview_panel.show_line_state(caret_line)
	_refresh_status()


## 把当前文件的校验结果推给剧本块（行内错误标记）。
##
## 复用 `_issue_panel` 已经解析好的结果，不额外跑一遍 ScriptAudit ——
## 全量审计要读遍所有剧本文件，在每次改动后跑是受不了的。
func _push_issues() -> void:
	# 变量清单也在这里刷 —— 它和静态校验是同一批触发点（打开 / 保存 / 重扫 /
	# 新建 / 改名 / 删除剧本），比挂在每次击键上便宜得多。
	_refresh_vars()
	var table: Control = _pages.get("table")
	if table == null or doc == null or doc.path.is_empty():
		return
	if table.has_method("set_issues"):
		table.call("set_issues", _issue_panel.issues_for_file(doc.path.get_file()))


# ---------------------------------------------------------------------------
# 侧栏「变量」清单
# ---------------------------------------------------------------------------

## 变量清单做成**侧栏常驻**，不是单独一页 ——
## 作者要的是「写剧本时随手瞄一眼」，切页看完再切回来太费事（用户反馈）。
## 详细页（带过滤 / 只看有问题）还在，从这一节标题的「详细」进。
func _refresh_vars() -> void:
	if _var_box == null:
		return
	for c in _var_box.get_children():
		_var_box.remove_child(c)
		c.queue_free()

	var data = VarIndex.scan()
	var by_key := {}
	for it in VarIndex.issues(data):
		var d: Dictionary = it
		by_key["%s/%s" % [d["kind"], d["name"]]] = d

	# 有问题的排前面 —— 这一栏是拿来「发现问题」的，不是当字典查的
	var rank := {"error": 0, "warn": 1, "info": 2}
	var rows: Array = []
	for kind in VarIndex.KINDS:
		var table: Dictionary = data.get(kind, {})
		for nm in table.keys():
			var name := String(nm)
			var it2: Dictionary = by_key.get("%s/%s" % [kind, name], {})
			rows.append({
				"kind": kind, "name": name, "entry": table[name], "issue": it2,
				"rank": int(rank.get(String(it2.get("level", "")), 3)),
			})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["rank"]) != int(b["rank"]):
			return int(a["rank"]) < int(b["rank"])
		return String(a["name"]) < String(b["name"]))

	if rows.is_empty():
		_var_box.add_child(EdTheme.label("（还没有变量）", EdTheme.FS_SMALL, EdTheme.TEXT_FAINT))
		return
	for r in rows:
		_var_box.add_child(_var_row(r))


func _var_row(r: Dictionary) -> Control:
	var it: Dictionary = r["issue"]
	var lv := String(it.get("level", ""))
	var mark := ""
	var col := EdTheme.TEXT_DIM
	match lv:
		"error":
			mark = "✕ "
			col = EdTheme.ERR
		"warn":
			mark = "⚠ "
			col = EdTheme.WARN
		"info":
			mark = "· "
			col = EdTheme.TEXT_FAINT

	var b := Button.new()
	b.text = "%s%s" % [mark, String(r["name"])]
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.custom_minimum_size = Vector2(0, 18)
	b.tooltip_text = _var_tip(r)
	b.add_theme_font_override("font", EdTheme.mono())
	b.add_theme_font_size_override("font_size", EdTheme.FS_SMALL)
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", EdTheme.ACCENT)
	b.add_theme_stylebox_override("normal", EdTheme.sb(Color(0, 0, 0, 0), 3, 4, 1))
	b.add_theme_stylebox_override("hover", EdTheme.sb(EdTheme.BG_HOVER, 3, 4, 1))
	b.add_theme_stylebox_override("pressed", EdTheme.sb(EdTheme.BG_ACTIVE, 3, 4, 1))

	var site := _var_site(r)
	b.pressed.connect(func() -> void: _jump_to_site(site))
	return b


func _var_tip(r: Dictionary) -> String:
	var it: Dictionary = r["issue"]
	var entry: Dictionary = r["entry"]
	var kind := String(r["kind"])
	var lines: Array = [
		"%s「%s」" % [String(VarIndex.LABELS.get(kind, kind)), String(r["name"])],
		VarIndex.summary(entry),
	]
	if not it.is_empty():
		lines.append(String(it.get("message", "")))
	for label in [["写", "writes"], ["读", "reads"]]:
		var pair: Array = label
		lines.append("%s：" % String(pair[0]))
		var list: Array = entry.get(String(pair[1]), [])
		if list.is_empty():
			lines.append("  （无）")
		for s in list:
			var d: Dictionary = s
			lines.append("  %s 第 %d 行  %s" % [
				String(d.get("file", "")).get_file(), int(d.get("line", 0)),
				String(d.get("raw", ""))])
	lines.append("")
	lines.append("点一下跳到第一处")
	return "\n".join(PackedStringArray(lines))


## 优先跳到「写」，没有写就跳到「读」
static func _var_site(r: Dictionary) -> Dictionary:
	var entry: Dictionary = r["entry"]
	var w: Array = entry.get("writes", [])
	if not w.is_empty():
		return w[0]
	var rd: Array = entry.get("reads", [])
	if not rd.is_empty():
		return rd[0]
	return {}


func _jump_to_site(site: Dictionary) -> void:
	if site.is_empty():
		return
	_open_at_file(String(site.get("file", "")))
	goto_source(int(site.get("line", 1)))


func _refresh_status() -> void:
	if doc == null or doc.path.is_empty():
		_status.text = ""
		return
	var n := doc.line_count()
	if doc.is_dirty():
		_status.text = "● 未保存（Ctrl+S 保存）"
		_status.add_theme_color_override("font_color", EdTheme.WARN)
	else:
		_status.text = "· 已保存 · %d 行" % n
		_status.add_theme_color_override("font_color", EdTheme.OK)


func _notice_flash(msg: String, color: Color = EdTheme.WARN) -> void:
	_notice.text = msg
	_notice.add_theme_color_override("font_color", color)
	_notice_until = Time.get_ticks_msec() + 4000


func _process(_delta: float) -> void:
	if doc == null:
		return

	# 1. 外部改动（AI 直接改 .gvs / 别的编辑器改了）
	var changed := watcher.poll()
	for p in changed:
		if String(p) == doc.path:
			_handle_external_change()

	# 2. 提示自动消失
	if _notice_until > 0 and Time.get_ticks_msec() > _notice_until:
		_notice.text = ""
		_notice_until = 0

	# 3. 文档被别处改动（剧本块 / 撤销）→ 给源码视图打「过期」标记。
	#
	# **不在这里整篇重设 CodeEdit**：那要 17ms 全文重解析，还会清空
	# CodeEdit 自己的撤销栈。改为标记 + 懒同步 —— 切回源码页时才对齐。
	# 用户正停在源码页时（改动来自他自己的击键）立刻对齐，
	# 但 sync_if_stale 会发现文本本来就一致而直接跳过，不会动光标。
	if doc.revision != _last_doc_revision:
		_last_doc_revision = doc.revision
		_script_panel.mark_dirty_from_panel()
		if _current_page == "script":
			_script_panel.sync_if_stale()
		_refresh_status()


## 外部改动了当前文件。
##
## **关掉自动写盘之后这里不再能「直接整体重载」** —— 工具手里可能有
## 未保存的改动，静默重载等于把用户的编辑丢掉。所以要弹冲突提示让他选。
func _handle_external_change() -> void:
	watcher.resync(doc.path)
	if not doc.is_dirty():
		# 手里没改动，直接跟上外部版本（原来的行为）
		_reload_from_disk("已同步外部改动")
		return
	_conflict.dialog_text = ("磁盘上的 %s 已被外部修改，\n"
		+ "而编辑器里还有未保存的改动。\n\n"
		+ "【覆盖磁盘】用编辑器里的版本盖掉它\n"
		+ "【加载外部版本】丢弃编辑器里的改动") % doc.path.get_file()
	_conflict.popup_centered()


## 用磁盘内容整体替换（丢弃内存改动）
func _discard_and_reload() -> void:
	if doc == null or doc.path.is_empty():
		return
	if doc.discard_and_reload():
		watcher.resync(doc.path)
		_script_panel.load_doc()
		_script_panel.refresh_labels(doc.labels())
		_last_doc_revision = doc.revision
		_issue_panel.refresh(true)
		_push_issues()
		_preview_panel.show_line_state(caret_line)
		_refresh_status()
		_refresh_current_page()
		_notice_flash("已加载磁盘上的版本", EdTheme.OK)


func _reload_from_disk(msg: String) -> void:
	var caret: int = _script_panel.current_line()
	if doc.reload_from_disk():
		watcher.resync(doc.path)
		_script_panel.load_doc()
		_script_panel.refresh_labels(doc.labels())
		_last_doc_revision = doc.revision
		_script_panel.goto_line(mini(caret, doc.line_count()), false)
		_issue_panel.refresh(true)
		_push_issues()
		_preview_panel.show_line_state(caret)
		_refresh_status()
		_refresh_current_page()
		_notice_flash(msg, EdTheme.OK)
	else:
		# 内容没变（mtime 动了但文本相同），也要把基线更新掉，
		# 否则每轮轮询都会报一次
		watcher.resync(doc.path)


## 让当前页面重新读一遍文档（撤销 / 重载之后用）
func _refresh_current_page() -> void:
	var page: Control = _pages.get(_current_page)
	if page != null and page.has_method("on_shown"):
		page.call("on_shown")


func _rescan() -> void:
	index.scan()
	_refresh_index_summary()
	ScriptStats.clear_cache()
	_refresh_files()
	_issue_panel.refresh(true)
	_push_issues()
	invalidate_asset_views()
	_notice_flash("已重新扫描", EdTheme.OK)
	# 让当前页面也刷新
	var page: Control = _pages.get(_current_page)
	if page != null and page.has_method("on_shown"):
		page.call("on_shown")


## 素材索引变了 → 通知依赖它的面板丢掉缓存。
##
## 现在只有剧本块：它的素材 / 表情下拉是**建行那一刻**生成的，
## 而它又是按 `doc.revision` 判断「要不要重建」的 —— 导入素材不改剧本，
## 所以不主动作废的话，旧行的下拉永远停在旧选项上。
func invalidate_asset_views() -> void:
	var table: Control = _pages.get("table")
	if table != null and table.has_method("invalidate_assets"):
		table.call("invalidate_assets")


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return

	if k.ctrl_pressed and k.keycode == KEY_S:
		_save()
		accept_event()
	elif k.ctrl_pressed and k.keycode == KEY_R:
		_rescan()
		accept_event()
	elif k.ctrl_pressed and k.shift_pressed and k.keycode == KEY_F:
		# ⚠️ 必须排在 Ctrl+F 之前判（shift 也按着，两条都会命中）
		_open_search()
		accept_event()
	elif k.ctrl_pressed and k.keycode == KEY_F:
		# 剧本块自己的查找条；别的页面没有「行」的概念，不接管
		var table: Control = _pages.get("table")
		if _current_page == "table" and table != null and table.has_method("open_find"):
			table.call("open_find")
			accept_event()
	elif k.ctrl_pressed and k.keycode == KEY_Z:
		# 源码页的撤销交给 CodeEdit 自己（它有内建撤销栈，且比快照栈细）
		if _current_page != "script":
			_undo(k.shift_pressed)
			accept_event()
	elif k.ctrl_pressed and k.keycode == KEY_Y:
		if _current_page != "script":
			_undo(true)
			accept_event()
	elif k.keycode == KEY_F5:
		_preview_panel.run_from_caret()
		accept_event()
	elif k.keycode == KEY_F1 or k.keycode == KEY_QUESTION \
			or (k.keycode == KEY_SLASH and k.shift_pressed):
		_open_shortcuts()
		accept_event()


## 切到搜索页并聚焦输入框
func _open_search() -> void:
	show_page("search")
	var sp: Control = _pages.get("search")
	if sp != null and sp.has_method("focus_input"):
		sp.call("focus_input")


## 保存（Ctrl+S）。冲突时弹对话框让用户裁决，不静默覆盖。
func _save(force: bool = false) -> void:
	_script_panel.flush_now()
	var r := doc.save(force)
	if bool(r.get("ok", false)):
		watcher.resync(doc.path)
		_refresh_status()
		_issue_panel.refresh(true)
		_push_issues()
		# 侧栏的变量总览要跟着新旗标 / 好感度更新（只在保存时算，不跟每次击键）
		_refresh_index_summary()
		_notice_flash("已保存", EdTheme.OK)
		return
	if bool(r.get("conflict", false)):
		_conflict.dialog_text = ("磁盘上的 %s 已被外部修改。\n\n"
			+ "【覆盖磁盘】用编辑器里的版本盖掉它\n"
			+ "【加载外部版本】丢弃编辑器里的改动") % doc.path.get_file()
		_conflict.popup_centered()
		return
	_notice_flash(String(r.get("message", "保存失败")), EdTheme.ERR)


## 撤销 / 重做。
##
## 快照栈在 `ScriptDoc` 里（200 步），**剧本块这类结构性改动才进栈**；
## 源码视图的击键由 CodeEdit 自己的撤销栈管，两边互不干扰 ——
## 所以这里只在非源码页接管 Ctrl+Z。
func _undo(redo: bool) -> void:
	if doc == null:
		return
	var ok := doc.redo() if redo else doc.undo()
	if not ok:
		_notice_flash("没有可%s的操作" % ("重做" if redo else "撤销"), EdTheme.TEXT_FAINT)
		return
	_last_doc_revision = doc.revision
	_script_panel.mark_dirty_from_panel()
	_refresh_current_page()
	_issue_panel.refresh(true)
	_push_issues()
	_refresh_status()
	_notice_flash("已%s" % ("重做" if redo else "撤销"), EdTheme.OK)
