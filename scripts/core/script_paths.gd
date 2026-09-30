class_name ScriptPaths
extends RefCounted

## 「剧本文件住在哪」的唯一权威
##
## 这套知识以前散在好几处：`ScriptStats` 有三个路径常量、`main.gd` 写死入口文件、
## 调试控制台自己拼前缀。最麻烦的是「按语言分目录」只实现了一半 ——
## `ScriptStats` 会去 `data/scripts/<lang>/` 统计，调度器却仍然只从根目录加载，
## 结果是「统计到的是英文、玩到的却是中文」。
##
## 现在统一在这里，并确立一条规则：
##
##   **对外的路径一律是「逻辑路径」**（`res://data/scripts/xxx.gvs`），
##   真正读文件时才用 `resolve()` 映射到当前语言的实际文件。
##
## 好处是 `jump_file` 指令、`chapters.json`、`cg.json` 的 replay 里写的路径
## 都不用改；要加一门语言，只要在 `data/scripts/<lang>/` 下放同名文件即可。
## 存档里记的也是逻辑路径，换语言读旧档不会对不上。

const SOURCE_LANG := "zh_CN"
const DIR := "res://data/scripts/"
const CHAPTERS := DIR + "chapters.json"
const LOCALIZED_DIR := DIR + "{lang}/"


## 主入口剧本
static func entry() -> String:
	return DIR + "prologue.gvs"


## 当前界面语言对应的剧本目录。该语言没有自己的目录就回退源语言目录。
static func active_dir() -> String:
	var localized := _localized_dir()
	if localized.is_empty():
		return DIR
	return localized if DirAccess.open(localized) != null else DIR


## 章节表。和剧本一样，语言目录里有一份就用那份。
static func chapters_path() -> String:
	var localized := _localized_dir()
	if not localized.is_empty() and FileAccess.file_exists(localized + "chapters.json"):
		return localized + "chapters.json"
	return CHAPTERS


## 逻辑路径 → 实际要读的文件路径。
##
## 只处理 `res://data/scripts/` 下的路径；其余（`user://` 的测试剧本、外部路径）
## 原样返回。目标语言缺少这个文件时也回退逻辑路径 —— 单文件缺译文不该让整段剧情加载失败。
static func resolve(path: String) -> String:
	if not path.begins_with(DIR):
		return path
	var localized := _localized_dir()
	if localized.is_empty():
		return path
	var candidate := localized + path.substr(DIR.length())
	return candidate if FileAccess.file_exists(candidate) else path


## 当前语言下所有剧本的**逻辑路径**（按语言分目录时读那里的文件，但返回逻辑路径）。
static func list_scripts() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(active_dir())
	if dir == null:
		return out
	for name in dir.get_files():
		if String(name).ends_with(".gvs"):
			out.append(DIR + String(name))
	out.sort()
	return out


## 当前语言是不是源语言（等于「不需要任何映射」）
static func is_source_language() -> bool:
	return _localized_dir().is_empty()


## 当前语言对应的 `data/scripts/<lang>/`；是源语言则返回空串。
static func _localized_dir() -> String:
	var lang := String(ConfigManager.get_value("language", SOURCE_LANG))
	if lang.is_empty() or lang == SOURCE_LANG:
		return ""
	return LOCALIZED_DIR.replace("{lang}", lang)
