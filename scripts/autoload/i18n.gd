extends Node

## 界面文案本地化
##
## 用「中文原文」当 key：zh_CN 不需要翻译表（原文即译文），其它语言只写差异。
## 好处是新写的文案不用登记 key 就能显示，其它语言缺条目时自动回退原文，
## 绝不会把界面显示成一串 `menu.start` 这样的东西。
##
## 没用 Godot 内置 TranslationServer：它的 .translation 资源要先导入才能用，
## 改一次文案就得重新导入一遍；这里是纯 JSON，和项目其它配置
## （ui_theme.json / gallery_theme.json）保持同一种玩法。
##
## 界面文字分两类，处理方式不同：
##   1. 静态文案（写在 main.tscn 里）—— 由 apply_tree() 遍历替换
##   2. 代码拼出来的（如「存档 3」「结局：春日的答案」）—— 在生成处显式调 t()
##
## 两类都不会被重复翻译。静态文案的原文存进节点的 i18n_src 元数据，
## 下次切语言时拿**原文**重新查表，而不是拿已经翻好的英文去查
## （那会查不到，于是永远卡在英文上）。

signal language_changed(lang: String)

const I18N_DIR := "res://data/i18n/"
const DEFAULT_LANG := "zh_CN"
const CONFIG_KEY := "language"

## 存原文的元数据键（静态文案）
const META_SRC := "i18n_src"
## 存 key / 参数的元数据键（代码生成的动态文案）
const META_KEY := "i18n_key"
const META_PARAMS := "i18n_params"
## 打上这个标记的节点及其子树不会被翻译 —— 剧本对白、回看记录、
## 曲目名这类「内容」必须靠它挡住
const META_SKIP := "i18n_skip"

## 语言代码 -> 用各自语言写的语言名。语言名本身就是本地化的，
## 不参与翻译，所以放这里而不是放进 JSON。
const LANGUAGE_NAMES: Dictionary = {
	"zh_CN": "简体中文",
	"zh_TW": "繁體中文",
	"en": "English",
	"ja": "日本語",
}

var current: String = DEFAULT_LANG

var _table: Dictionary = {}


func _ready() -> void:
	current = String(ConfigManager.get_value(CONFIG_KEY, DEFAULT_LANG))
	reload()


# ---------------------------------------------------------------------------
# 语言表
# ---------------------------------------------------------------------------

## data/i18n/ 下有哪些语言（按文件名）
func languages() -> Array:
	var out: Array = []
	var dir := DirAccess.open(I18N_DIR)
	if dir == null:
		out.append(DEFAULT_LANG)
		return out
	for f in dir.get_files():
		if f.ends_with(".json"):
			out.append(f.get_basename())
	if not out.has(DEFAULT_LANG):
		out.append(DEFAULT_LANG)
	out.sort()
	return out


func language_name(code: String) -> String:
	return String(LANGUAGE_NAMES.get(code, code))


func reload() -> void:
	_table = {}
	if current == DEFAULT_LANG:
		return
	var raw: Variant = JsonUtil.load_json(I18N_DIR + current + ".json")
	if typeof(raw) == TYPE_DICTIONARY:
		_table = raw


## 翻译。找不到就原样返回 —— 缺条目只是「这一句没翻译」，不会显示成 key。
## 参数用 {name} 占位：`t("存档 {n}", {"n": 3})`
func t(key: String, params: Dictionary = {}) -> String:
	var s := String(_table.get(key, key))
	for k in params.keys():
		s = s.replace("{%s}" % String(k), str(params[k]))
	return s


func set_language(lang: String) -> void:
	if lang == current:
		return
	current = lang
	ConfigManager.set_value(CONFIG_KEY, lang)
	reload()
	language_changed.emit(lang)


# ---------------------------------------------------------------------------
# 应用到界面
# ---------------------------------------------------------------------------

## 给代码生成的控件赋「带参数的文案」，并记下 key 以便切语言时重算。
func set_text(node: Control, key: String, params: Dictionary = {}) -> void:
	node.set_meta(META_KEY, key)
	node.set_meta(META_PARAMS, params)
	node.set("text", t(key, params))


## 递归替换界面上的静态文案。可以反复调用（切语言时重跑一遍）。
func apply_tree(root: Node) -> void:
	_walk(root)


func _walk(node: Node) -> void:
	if bool(node.get_meta(META_SKIP, false)):
		return
	if node.has_meta(META_KEY):
		var params: Dictionary = node.get_meta(META_PARAMS, {})
		node.set("text", t(String(node.get_meta(META_KEY)), params))
	elif node.has_meta(META_SRC):
		node.set("text", t(String(node.get_meta(META_SRC))))
	elif _is_text_node(node):
		var text := String(node.get("text"))
		if not text.is_empty():
			node.set_meta(META_SRC, text)
			node.set("text", t(text))
	for child in node.get_children():
		_walk(child)


## 只有「玩家界面上的固定文字」才翻译。
##
## 刻意不收 RichTextLabel —— 对白框和回看记录都是它，里面装的是剧本内容，
## 翻译器一旦碰到就会把台词当 key 去查表。LineEdit / OptionButton 同理：
## 前者是玩家输入，后者装的是语言名（本身就该用各自语言显示）。
func _is_text_node(node: Node) -> bool:
	return (node is Button or node is Label or node is CheckBox) \
		and not (node is OptionButton) and not (node is LineEdit)
