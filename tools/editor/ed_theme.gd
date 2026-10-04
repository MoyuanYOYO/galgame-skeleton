extends RefCounted

## 编辑器深色主题
##
## 独立于游戏的 `data/ui/ui_theme.json` —— 编辑器是长时间看代码的工具，
## 需要的是低亮度、高对比、等宽对齐的观感，和游戏的水彩浅色主题诉求相反。
## 所以这里不复用 UiTheme，只借它的「静态工厂函数」这个组织方式。
##
## 全部是静态成员：`const` 配色 + `static func` 工厂。
## 调用方 `preload("res://tools/editor/ed_theme.gd")` 后直接当命名空间用。

# ---------------------------------------------------------------------------
# 配色
# ---------------------------------------------------------------------------

const BG := Color("#17171b")          # 窗口底
const BG_PANEL := Color("#1e1e24")    # 面板
const BG_ELEV := Color("#26262e")     # 卡片 / 输入框
const BG_HOVER := Color("#2f2f39")
const BG_ACTIVE := Color("#34343f")
const BORDER := Color("#33333d")
const BORDER_HI := Color("#45454f")

const TEXT := Color("#d8d8e0")
const TEXT_DIM := Color("#9494a0")
const TEXT_FAINT := Color("#62626e")

const ACCENT := Color("#6aa9ff")
const ACCENT_DIM := Color("#3d6fa8")
const OK := Color("#57c78a")
const WARN := Color("#e0b355")
const ERR := Color("#e56a6a")

const SEL_BG := Color("#2b3b52")      # 选中行背景
const CURLINE_BG := Color("#22222a")  # 当前行背景

# ---------------------------------------------------------------------------
# 语法高亮（VS Code Dark+ 取向，与项目现有的「行首关键字」语法匹配）
# ---------------------------------------------------------------------------

const SYN_KEYWORD := Color("#569cd6")   # label / show / bg / if / choice …
const SYN_STRING := Color("#ce9178")    # 引号内容、参数值
const SYN_COMMENT := Color("#6a9955")   # # 注释
const SYN_LABEL := Color("#dcdcaa")     # 标签名
const SYN_SPEAKER := Color("#4ec9b0")   # 说话人
const SYN_PARAM := Color("#9cdcfe")     # 参数名
const SYN_NUMBER := Color("#b5cea8")    # 数字
const SYN_CHOICE := Color("#c586c0")    # 选项文本

# 行类型对应的整行着色（用于左侧色条与表格视图）
const KIND_COLORS := {
	"blank": Color("#2a2a32"),
	"comment": Color("#4a4a55"),
	"label": SYN_LABEL,
	"directive": SYN_KEYWORD,
	"dialogue": SYN_SPEAKER,
	"choice": SYN_CHOICE,
}

## 剧本块里「指令类型」那一格的颜色，按用途分类。
##
## 设计要求：**八类在色相环上大致等距**，因为这一格很小（11px 字）、
## 又挤在一起，色相挨近了两类就分不出来。
## 色相大致是 25 / 50 / 90 / 168 / 205 / 240 / 275 / 330 ——
## 相邻至少差 25°，实测相邻两类的最近距离是「背景(205) ↔ 流程(240)」。
##
## ⚠️ 曾经 `CHAR` 与 `SAY` 共用 `SYN_SPEAKER`，于是「立绘入场」和「对白」
## 长得一模一样 —— 这两类恰恰是最需要区分的（一个改画面、一个改台词）。
const TAG_COLORS := {
	"SAY": SYN_SPEAKER,          # 对白 / 旁白 —— 青（与源码视图的说话人同色）
	"CHAR": Color("#e0965a"),    # 立绘 —— 橙
	"BG": Color("#7fb3d5"),      # 背景 / CG —— 蓝
	"CG": Color("#7fb3d5"),
	"BGM": Color("#a8c98a"),     # 音频 —— 绿
	"SE": Color("#a8c98a"),
	"VO": Color("#a8c98a"),
	"FX": Color("#b98ad9"),      # 画面特效 —— 紫
	"AFX": Color("#e06a6a"),     # 音频特效（效果器）—— 红。色相 0°，
								 # 与 CHAR(27°) / VIDEO(334°) 都拉开 26° 以上，
								 # 且「故障 / 失真」用红色最直观
	"STATE": Color("#dfc95f"),   # 旗标 / 好感度 —— 黄
	"VIDEO": Color("#d9709e"),   # 视频 —— 品红
	"FLOW": Color("#8f9ad4"),    # 流程（等待 / 结局 / 解锁）—— 蓝紫
}


static func tag_color(tag: String) -> Color:
	return TAG_COLORS.get(tag, TEXT_DIM)

# ---------------------------------------------------------------------------
# 字号与度量
# ---------------------------------------------------------------------------

const FS_CODE := 13
const FS_UI := 13
const FS_SMALL := 11
const FS_TITLE := 15

const ROW_H := 20          # 代码行高
const GUTTER_W := 52       # 行号栏宽度

# ---------------------------------------------------------------------------
# 字体
# ---------------------------------------------------------------------------

static var _mono: Font = null
static var _ui: Font = null


## 等宽字体栈。
##
## 必须显式列出 Windows 上的候选名 —— 否则会掉到带点零的 DejaVu Sans Mono，
## 在代码里看 `0` 和 `O`、`1` 和 `l` 分不清。
##
## 注意：`SystemFont` **没有可写的 `font_size`**，字号一律由调用方通过
## `add_theme_font_size_override()` 指定（见下面的 style_* 系列）。
static func mono() -> Font:
	if _mono == null:
		var f := SystemFont.new()
		f.font_names = PackedStringArray([
			"Cascadia Mono", "Cascadia Code", "Consolas",
			"JetBrains Mono", "SF Mono", "Menlo", "DejaVu Sans Mono", "monospace",
		])
		_mono = f
	return _mono


static func ui() -> Font:
	if _ui == null:
		var f := SystemFont.new()
		f.font_names = PackedStringArray([
			"Segoe UI", "Microsoft YaHei UI", "PingFang SC", "Noto Sans CJK SC",
			"Source Han Sans SC", "sans-serif",
		])
		_ui = f
	return _ui


# ---------------------------------------------------------------------------
# StyleBox 工厂
# ---------------------------------------------------------------------------

static func sb(
		bg: Color,
		radius: int = 6,
		pad_h: int = 10,
		pad_v: int = 6,
		border_color: Color = Color(0, 0, 0, 0),
		border_w: int = 0,
	) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	s.content_margin_top = pad_v
	s.content_margin_bottom = pad_v
	if border_w > 0:
		s.border_color = border_color
		s.border_width_left = border_w
		s.border_width_right = border_w
		s.border_width_top = border_w
		s.border_width_bottom = border_w
	return s


static func panel_box(pad: int = 10) -> StyleBoxFlat:
	return sb(BG_PANEL, 0, pad, pad, BORDER, 1)


static func card_box(pad: int = 10) -> StyleBoxFlat:
	return sb(BG_ELEV, 8, pad, pad, BORDER, 1)


static func input_box() -> StyleBoxFlat:
	return sb(BG, 4, 8, 4, BORDER_HI, 1)


# ---------------------------------------------------------------------------
# 控件应用辅助
# ---------------------------------------------------------------------------

## 让一个 Control 用上编辑器主题的基本外观
static func apply_control(node: Control, font_size: int = FS_UI, color: Color = TEXT) -> void:
	node.add_theme_font_override("font", ui())
	node.add_theme_font_size_override("font_size", font_size)
	node.add_theme_color_override("font_color", color)


static func style_label(l: Label, size: int = FS_UI, color: Color = TEXT) -> Label:
	l.add_theme_font_override("font", ui())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func style_mono_label(l: Label, size: int = FS_CODE, color: Color = TEXT) -> Label:
	l.add_theme_font_override("font", mono())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func style_button(b: Button, accent: bool = false) -> Button:
	b.add_theme_font_override("font", ui())
	b.add_theme_font_size_override("font_size", FS_UI)
	var base := ACCENT_DIM if accent else BG_ELEV
	var hover := ACCENT if accent else BG_HOVER
	var pressed := ACCENT_DIM if accent else BG_ACTIVE
	b.add_theme_stylebox_override("normal", sb(base, 5, 10, 5, BORDER, 1))
	b.add_theme_stylebox_override("hover", sb(hover, 5, 10, 5, BORDER_HI, 1))
	b.add_theme_stylebox_override("pressed", sb(pressed, 5, 10, 5, BORDER_HI, 1))
	b.add_theme_stylebox_override("disabled", sb(BG_ELEV, 5, 10, 5, BORDER, 1))
	b.add_theme_stylebox_override("focus", sb(Color(0, 0, 0, 0), 5, 10, 5, ACCENT, 1))
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", TEXT_FAINT)
	return b


## 小号「芯片」按钮：用于工具栏、标签页
static func style_chip(b: Button, on: bool = false) -> Button:
	b.add_theme_font_override("font", ui())
	b.add_theme_font_size_override("font_size", FS_SMALL)
	var bg := ACCENT_DIM if on else Color(0, 0, 0, 0)
	var fg := Color.WHITE if on else TEXT_DIM
	b.add_theme_stylebox_override("normal", sb(bg, 4, 8, 3, Color(0, 0, 0, 0) if on else BORDER, 1))
	b.add_theme_stylebox_override("hover", sb(ACCENT_DIM if on else BG_HOVER, 4, 8, 3, BORDER_HI, 1))
	b.add_theme_stylebox_override("pressed", sb(BG_ACTIVE, 4, 8, 3, BORDER_HI, 1))
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	return b


static func style_line_edit(e: LineEdit) -> LineEdit:
	e.add_theme_font_override("font", ui())
	e.add_theme_font_size_override("font_size", FS_UI)
	e.add_theme_stylebox_override("normal", input_box())
	e.add_theme_stylebox_override("focus", sb(BG, 4, 8, 4, ACCENT, 1))
	e.add_theme_color_override("font_color", TEXT)
	e.add_theme_color_override("font_placeholder_color", TEXT_FAINT)
	e.add_theme_color_override("caret_color", ACCENT)
	return e


static func style_text_edit(e: TextEdit, mono_font: bool = false) -> TextEdit:
	e.add_theme_font_override("font", mono() if mono_font else ui())
	e.add_theme_font_size_override("font_size", FS_CODE if mono_font else FS_UI)
	e.add_theme_color_override("font_color", TEXT)
	e.add_theme_color_override("caret_color", ACCENT)
	e.add_theme_color_override("current_line_color", CURLINE_BG)
	e.add_theme_color_override("selection_color", SEL_BG)
	e.add_theme_stylebox_override("normal", sb(BG, 4, 8, 6, BORDER, 1))
	e.add_theme_stylebox_override("focus", sb(BG, 4, 8, 6, BORDER_HI, 1))
	return e


## 下拉框。**弹出菜单必须单独设置样式** —— 它是 OptionButton 内部的一个
## PopupMenu 节点，不跟着 OptionButton 的主题走，不设的话在深色界面上
## 会弹出一个浅色的原生菜单，非常突兀。
static func style_option(o: OptionButton) -> OptionButton:
	o.add_theme_font_override("font", ui())
	o.add_theme_font_size_override("font_size", FS_UI)
	o.add_theme_stylebox_override("normal", sb(BG_ELEV, 4, 8, 3, BORDER, 1))
	o.add_theme_stylebox_override("hover", sb(BG_HOVER, 4, 8, 3, BORDER_HI, 1))
	o.add_theme_stylebox_override("pressed", sb(BG_ACTIVE, 4, 8, 3, BORDER_HI, 1))
	o.add_theme_stylebox_override("focus", sb(BG_ELEV, 4, 8, 3, ACCENT, 1))
	o.add_theme_color_override("font_color", TEXT)
	o.add_theme_color_override("font_hover_color", Color.WHITE)
	o.add_theme_color_override("font_pressed_color", Color.WHITE)

	var pop := o.get_popup()
	if pop != null:
		pop.add_theme_font_override("font", ui())
		pop.add_theme_font_size_override("font_size", FS_UI)
		pop.add_theme_color_override("font_color", TEXT)
		pop.add_theme_color_override("font_hover_color", Color.WHITE)
		pop.add_theme_color_override("font_disabled_color", TEXT_FAINT)
		pop.add_theme_stylebox_override("panel", sb(BG_ELEV, 6, 4, 4, BORDER_HI, 1))
		pop.add_theme_stylebox_override("hover", sb(SEL_BG, 4, 4, 3))
		pop.add_theme_constant_override("v_separation", 4)
	return o


## 独立的 PopupMenu（不是 OptionButton 里那个）。
##
## 和 `style_option()` 里给弹出菜单设的是同一套观感 —— 不设的话深色界面上
## 会弹出一个浅色原生菜单。凡是在代码里 `PopupMenu.new()` 的地方都要过一遍这个。
static func style_popup(m: PopupMenu) -> PopupMenu:
	m.add_theme_font_override("font", ui())
	m.add_theme_font_size_override("font_size", FS_UI)
	m.add_theme_color_override("font_color", TEXT)
	m.add_theme_color_override("font_hover_color", Color.WHITE)
	m.add_theme_color_override("font_disabled_color", TEXT_FAINT)
	m.add_theme_color_override("font_separator_color", TEXT_FAINT)
	m.add_theme_stylebox_override("panel", sb(BG_ELEV, 6, 4, 4, BORDER_HI, 1))
	m.add_theme_stylebox_override("hover", sb(SEL_BG, 4, 4, 3))
	m.add_theme_constant_override("v_separation", 4)
	return m


static func style_scroll(s: ScrollContainer) -> ScrollContainer:
	return s


static func style_tree(t: Tree) -> Tree:
	t.add_theme_font_override("font", ui())
	t.add_theme_font_size_override("font_size", FS_UI)
	t.add_theme_color_override("font_color", TEXT_DIM)
	t.add_theme_color_override("font_selected_color", Color.WHITE)
	t.add_theme_color_override("guide_color", Color(1, 1, 1, 0.04))
	t.add_theme_stylebox_override("panel", sb(BG_PANEL, 0, 4, 4, BORDER, 1))
	t.add_theme_stylebox_override("selected", sb(SEL_BG, 4, 4, 2))
	t.add_theme_stylebox_override("selected_focus", sb(SEL_BG, 4, 4, 2))
	t.add_theme_stylebox_override("hovered", sb(BG_HOVER, 4, 4, 2))
	return t


static func style_split(v: VSeparator) -> VSeparator:
	var s := StyleBoxFlat.new()
	s.bg_color = BORDER
	s.content_margin_left = 0
	s.content_margin_right = 0
	v.add_theme_stylebox_override("separator", s)
	return v


static func style_hsplit(v: HSeparator) -> HSeparator:
	var s := StyleBoxFlat.new()
	s.bg_color = BORDER
	v.add_theme_stylebox_override("separator", s)
	return v


# ---------------------------------------------------------------------------
# 便捷构造
# ---------------------------------------------------------------------------

static func label(text: String, size: int = FS_UI, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	return style_label(l, size, color)


static func mono_label(text: String, size: int = FS_CODE, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	return style_mono_label(l, size, color)


static func button(text: String, accent: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	return style_button(b, accent)


static func chip(text: String, on: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = false
	return style_chip(b, on)


## 一根 1px 的分隔线（横向）
static func hline() -> HSeparator:
	return style_hsplit(HSeparator.new())


## 一个固定高度的间隔
static func spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## 一个可伸缩的横向填充
static func hfill() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c
