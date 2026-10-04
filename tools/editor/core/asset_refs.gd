extends RefCounted

## 素材 id 在项目里的引用点：查找 / 重写
##
## **素材改名不能只改文件名。** 剧本里 `bg classroom`、对白前缀 `alice@smile:`、
## 收藏表里 `"id": "cg_classroom"` 与 `"image": "res://assets/cg/cg_classroom.png"`
## 都写着旧名字 —— 不改就是一堆死链，而且**剧本不会报错**，只是画面黑掉、
## 收藏品解锁不了。删除同理：至少得告诉作者会留下几处死链。
##
## 两条原则：
##
## 1. **只改「结构位置」，绝不全文替换。**
##    对白正文里出现同名的词是常事（`alice@smile: 我笑了 smile。`），
##    全文替换会把台词改坏；而且这种损坏是静默的。
## 2. **逐行改，只重写需要改的那一行** —— 与编辑器的保真铁律一致
##    （注释、空行、缩进一个字节都不动）。
##
## 「数引用」和「改引用」走**同一条代码路径**（`_scan`，靠 `apply` 开关区分），
## 否则「提示 3 处、实际改 5 处」这种偏差永远查不出来。

const LineIndex = preload("res://tools/editor/core/line_index.gd")
const ScriptPaths = preload("res://scripts/core/script_paths.gd")
const ScriptStats = preload("res://scripts/core/script_stats.gd")

## 每类素材 id 出现在哪些指令的第几个**位置参数**上。
## 元素 = [指令, 位置参数下标, 需要 args[0] 等于的值（空 = 不判）]
##
## ⚠️ `unlock <type> <id>` 的 id 是**第二个**位置参数，且要按 type 分流
## （`unlock music daily` 里 daily 是 bgm 的 id，不是 cg 的）。
const SITES := {
	"bg": [["bg", 0, ""]],
	"cg": [["cg", 0, ""], ["unlock", 1, "cg"]],
	"se": [["se", 0, ""]],
	"bgm": [["bgm", 0, ""], ["unlock", 1, "music"]],
	"voice": [["voice", 0, ""]],
	"video": [["video", 0, ""]],
	"char": [
		["show", 0, ""], ["hide", 0, ""], ["move", 0, ""], ["expr", 0, ""],
		["hop", 0, ""], ["zoom", 0, ""], ["shake", 0, ""], ["anim", 0, ""],
	],
}

## 需要同步的收藏表：kind → 文件列表
const REGISTRIES := {
	"cg": ["res://data/collection/cg.json", "res://data/collection/endings.json"],
	"bgm": ["res://data/collection/music.json"],
}


# ---------------------------------------------------------------------------
# 对外
# ---------------------------------------------------------------------------

## 改掉某类素材 id 的剧本引用（`kind == "char"` 时改的是**角色 id**，
## 连对白前缀 `alice: 文本` 一起改）。返回 {"files", "lines", "hits"}。
##
## `files` 为空 = 扫项目里全部剧本；传值则只扫这些文件（测试用）。
static func rewrite_asset(kind: String, old_id: String, new_id: String,
		files := PackedStringArray()) -> Dictionary:
	return _scan(kind, old_id, new_id, "", true, files)


## 只查不改 —— 「被引用 N 处」与删除前的提示用
static func find_asset(kind: String, old_id: String,
		files := PackedStringArray()) -> Array:
	return _scan(kind, old_id, old_id, "", false, files).get("hits", [])


## 改掉某个角色下**表情** id 的引用：
## `show <角色> expr=<表情>`、`expr <角色> <表情>`、对白 `<角色>@<表情>:`
static func rewrite_expr(char_id: String, old_expr: String, new_expr: String,
		files := PackedStringArray()) -> Dictionary:
	return _scan("char", old_expr, new_expr, char_id, true, files)


static func find_expr(char_id: String, old_expr: String,
		files := PackedStringArray()) -> Array:
	return _scan("char", old_expr, old_expr, char_id, false, files).get("hits", [])


## 收藏表里的引用：
##   cg.json      → `"id": "<旧>"` + image 路径
##   music.json   → `"id": "<旧>"`（music.json 的 id 必须等于 bgm 文件名）
##   endings.json → image 路径
##
## ⚠️ **只做「带引号的精确模式」替换，不做全文替换。**
## cg.json 里还有 `"label": "cg_classroom"` —— 那是**剧本里的标签名**，
## 跟着 id 一起改会让「重播剧情」直接跳不到（标签没了，剧本也不报错）。
## 返回改动过的文件数。
static func rewrite_registry(kind: String, old_id: String, new_id: String,
		old_path: String, new_path: String) -> int:
	var changed := 0
	for p in (REGISTRIES.get(kind, []) as Array):
		var path := String(p)
		if not FileAccess.file_exists(path):
			continue
		var text := FileAccess.get_file_as_string(path)
		var before := text
		if not old_path.is_empty() and not new_path.is_empty():
			text = text.replace(old_path, new_path)
		if not old_id.is_empty() and old_id != new_id:
			text = text.replace("\"id\": \"%s\"" % old_id, "\"id\": \"%s\"" % new_id)
		if text == before:
			continue
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			continue
		f.store_string(text)
		f.close()
		changed += 1
	return changed


# ---------------------------------------------------------------------------
# 核心：扫全部剧本
# ---------------------------------------------------------------------------

## `apply = false` 时只统计命中行，不写盘。
## `char_id` 非空 → 改的是「某个角色下的表情」，此时 `old_id` / `new_id` 是表情名。
## `files` 为空 = 用项目里的全部剧本；传值则只扫这些文件（测试用）。
static func _scan(kind: String, old_id: String, new_id: String, char_id: String,
		apply: bool, files := PackedStringArray()) -> Dictionary:
	var out := {"files": 0, "lines": 0, "hits": []}
	if old_id.is_empty():
		return out
	var sites: Array = SITES.get(kind, [])
	var targets := files if not files.is_empty() else ScriptStats.script_files()

	for p in targets:
		var logical := String(p)
		var real := ScriptPaths.resolve(logical)
		var text := FileAccess.get_file_as_string(real)
		if text.is_empty():
			continue

		var raw_lines := text.split("\n")
		var parsed := LineIndex.parse_raw(raw_lines)
		var changed := 0

		for l in parsed.get("lines", []):
			var line := l as LineIndex.Line
			var patch := _patch_line(line, kind, sites, old_id, new_id, char_id)
			if not bool(patch.get("hit", false)):
				continue
			changed += 1
			(out["hits"] as Array).append({"file": logical.get_file(), "line": line.no})
			var nr := String(patch.get("raw", line.raw))
			if apply and nr != line.raw:
				raw_lines[line.no - 1] = nr

		if changed == 0:
			continue
		if apply:
			var f := FileAccess.open(real, FileAccess.WRITE)
			if f == null:
				continue
			f.store_string("\n".join(raw_lines))
			f.close()
		out["files"] = int(out["files"]) + 1
		out["lines"] = int(out["lines"]) + changed

	return out


## 单行改写。返回 {"hit": bool, "raw": String}。
##
## `hit` 与「raw 变了」是两件事：查引用时 new_id == old_id，raw 不变但命中为真。
static func _patch_line(line: LineIndex.Line, kind: String, sites: Array,
		old_id: String, new_id: String, char_id: String) -> Dictionary:
	var miss := {"hit": false, "raw": line.raw}

	if not char_id.is_empty():
		return _patch_expr_line(line, char_id, old_id, new_id)

	# 角色 id 比别的素材多几个「藏身处」—— 好感度的键也是角色 id，
	# 不改干净的话会出现「画面里没有 alice，好感度面板里却有 alice」这种幽灵角色。
	if kind == "char":
		var c := _patch_char_line(line, old_id, new_id)
		if bool(c.get("hit", false)):
			return c

	if line.kind != LineIndex.Line.DIRECTIVE:
		return miss

	for s in sites:
		var site: Array = s
		if line.head != String(site[0]):
			continue
		var need0 := String(site[2])
		if not need0.is_empty() and (line.args.size() < 1 or line.args[0] != need0):
			continue
		var idx := int(site[1])
		if line.args.size() <= idx or line.args[idx] != old_id:
			continue
		return {"hit": true, "raw": _replace_pos_arg(line.raw, idx, old_id, new_id)}
	return miss


## 角色 id 的额外引用点。`show/hide/…` 那类走通用的 `SITES`，这里只管它们之外的：
##   `<角色>: 文本` / `<角色>@<表情>: 文本`   对白前缀
##   `affection <角色> <值>`                好感度的键也是角色 id
##   `carry affection <角色>`               跨周目继承
##   `if/elif affection <角色> >= 10`        条件不是 kv，只能按词扫原文
static func _patch_char_line(line: LineIndex.Line, old_id: String,
		new_id: String) -> Dictionary:
	var miss := {"hit": false, "raw": line.raw}

	if line.kind == LineIndex.Line.DIALOGUE:
		if line.speaker != old_id:
			return miss
		return {"hit": true, "raw": _replace_dialogue_prefix(line.raw, new_id, line.expr)}

	if line.kind != LineIndex.Line.DIRECTIVE:
		return miss

	match line.head:
		"affection":
			if line.args.size() > 0 and line.args[0] == old_id:
				return {"hit": true, "raw": _replace_pos_arg(line.raw, 0, old_id, new_id)}
		"carry":
			if line.args.size() > 1 and line.args[0] == "affection" and line.args[1] == old_id:
				return {"hit": true, "raw": _replace_pos_arg(line.raw, 1, old_id, new_id)}
		"if", "elif":
			var nr := _replace_cond_affection(line.raw, old_id, new_id)
			if nr != line.raw:
				return {"hit": true, "raw": nr}
	return miss


## `if affection alice >= 10` —— 条件不是 kv，`LineIndex` 把整段原样留在 `cond_text` 里，
## 所以只能按词扫原文：找 `affection` 后面紧跟着的那个词，相等就换。
## 行尾注释之后不再看（注释里出现同名不该被改）。
static func _replace_cond_affection(raw: String, old_id: String, new_id: String) -> String:
	var i := 0
	var n := raw.length()
	var prev := ""
	while i < n:
		while i < n and (raw[i] == " " or raw[i] == "\t"):
			i += 1
		var start := i
		while i < n and raw[i] != " " and raw[i] != "\t":
			i += 1
		var tok := raw.substr(start, i - start)
		if tok.begins_with("#"):
			break
		if prev == "affection" and tok == old_id:
			return raw.substr(0, start) + new_id + raw.substr(i)
		prev = tok
	return raw


static func _patch_expr_line(line: LineIndex.Line, char_id: String,
		old_expr: String, new_expr: String) -> Dictionary:
	var miss := {"hit": false, "raw": line.raw}

	if line.kind == LineIndex.Line.DIALOGUE:
		if line.speaker != char_id or line.expr != old_expr:
			return miss
		return {"hit": true, "raw": _replace_dialogue_prefix(line.raw, char_id, new_expr)}

	if line.kind != LineIndex.Line.DIRECTIVE:
		return miss
	if line.args.size() == 0 or line.args[0] != char_id:
		return miss

	match line.head:
		"show":
			# `show alice expr=smile` —— 表情是 kv
			if String(line.params.get("expr", "")) != old_expr:
				return miss
			return {"hit": true, "raw": _replace_kv(line.raw, "expr", old_expr, new_expr)}
		"expr":
			# `expr alice smile` —— 表情是第二个位置参数
			if line.args.size() < 2 or line.args[1] != old_expr:
				return miss
			return {"hit": true, "raw": _replace_pos_arg(line.raw, 1, old_expr, new_expr)}
	return miss


# ---------------------------------------------------------------------------
# 定位 + 替换
# ---------------------------------------------------------------------------

## 把一行里第 `idx` 个**位置参数**（0 = 紧跟指令名的第一个）换成 `new_v`。
##
## 按词扫定位，不按 `raw.find(old_v)` —— 后者在 `flag true_flag true`
## 这类行上会命中错的那个，把名字改坏且不报错。
static func _replace_pos_arg(raw: String, idx: int, old_v: String, new_v: String) -> String:
	var span := _token_span(raw, idx + 1)
	if span.x < 0:
		return raw
	if raw.substr(span.x, span.y - span.x) != old_v:
		return raw
	return raw.substr(0, span.x) + new_v + raw.substr(span.y)


## 把 `key=旧值` 换成 `key=新值`。只认整词相等，不做子串替换。
static func _replace_kv(raw: String, key: String, old_v: String, new_v: String) -> String:
	var i := 0
	var n := raw.length()
	while i < n:
		while i < n and (raw[i] == " " or raw[i] == "\t"):
			i += 1
		var start := i
		while i < n and raw[i] != " " and raw[i] != "\t":
			i += 1
		var tok := raw.substr(start, i - start)
		var eq := tok.find("=")
		if eq > 0 and tok.substr(0, eq) == key and tok.substr(eq + 1) == old_v:
			return raw.substr(0, start) + key + "=" + new_v + raw.substr(i)
	return raw


## 改对白前缀（`: ` 之前那一段）。**台词正文一个字节都不碰** ——
## 正文里出现同名的词是常事（`alice@smile: 我笑了 smile。`）。
static func _replace_dialogue_prefix(raw: String, speaker: String, expr: String) -> String:
	var start := 0
	while start < raw.length() and (raw[start] == " " or raw[start] == "\t"):
		start += 1
	var colon := raw.find(":", start)
	if colon <= start:
		return raw
	var np := speaker if expr.is_empty() else "%s@%s" % [speaker, expr]
	return raw.substr(0, start) + np + raw.substr(colon)


## 第 n 个「词」的字符区间（0 = 行首那个）。找不到返回 (-1, -1)。
##
## 按空白切词，与 `LineIndex._parse_directive` 的切法一致；
## 行首缩进与行尾注释都不会影响前几个词的下标。
static func _token_span(raw: String, n: int) -> Vector2i:
	var i := 0
	var idx := 0
	var len := raw.length()
	while i < len:
		while i < len and (raw[i] == " " or raw[i] == "\t"):
			i += 1
		if i >= len:
			break
		var start := i
		while i < len and raw[i] != " " and raw[i] != "\t":
			i += 1
		if idx == n:
			return Vector2i(start, i)
		idx += 1
	return Vector2i(-1, -1)
