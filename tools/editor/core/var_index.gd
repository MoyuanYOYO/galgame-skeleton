extends RefCounted

## 剧本变量清单：旗标 / 变量 / 好感度
##
## 扫全部剧本，列出「谁写、谁读」。三件事靠它：
##
##   1. 一眼看到项目里到底有多少变量（不用一个个文件翻）
##   2. 揪出两类**静默**错误 ——
##      · **只读不写**：条件里读了但从没人设过。几乎一定是名字拼错了，
##        而剧本不报错，只是那条分支**永远走不到**。
##      · **只写不读**：设了但从没被条件用过。可能是忘了接上，也可能是纯记录，
##        所以只给 warn。
##   3. 点一条跳到第一次出现的位置
##
## 判定规则与 `GvsParser.parse_condition` 对齐 —— 同一个剧本在编辑器里和
## 在游戏里必须是一个说法，否则「工具说没问题」就成了假安全感。
##
##   写：`flag <名> [true|false]` / `set|add|sub [var] <名> <值>` / `affection <角色> <值>`
##   写：`call <标签> 名=值`（子过程里当变量用）
##   读：`if|elif` 条件里的 `[not] flag|var|affection <名>`
##   读：`carry <类别> <名>`（下一周目继承时要读它）
##   读：台词 / 章节名 / 结局标题里的 `{$名字}`（见 GvsInterp）

const LineIndex = preload("res://tools/editor/core/line_index.gd")
const ScriptPaths = preload("res://scripts/core/script_paths.gd")
const ScriptStats = preload("res://scripts/core/script_stats.gd")
const GvsInterp = preload("res://scripts/core/gvs_interp.gd")

const KINDS := ["flag", "var", "affection"]

const LABELS := {
	"flag": "旗标", "var": "变量", "affection": "好感度",
}


## 扫全部剧本（`files` 非空则只扫这些，测试用）。
## 返回 `{"flag": {名字: {"writes": [site...], "reads": [site...]}}, "var": {...}, ...}`
## `site` = `{"file": 逻辑路径, "line": 行号, "raw": 原文}`
static func scan(files := PackedStringArray()) -> Dictionary:
	var out := {}
	for k in KINDS:
		out[k] = {}

	for p in (files if not files.is_empty() else ScriptStats.script_files()):
		var logical := String(p)
		var text := FileAccess.get_file_as_string(ScriptPaths.resolve(logical))
		if text.is_empty():
			continue
		var parsed := LineIndex.parse_raw(text.split("\n"))
		for l in parsed.get("lines", []):
			_collect_line(out, logical, l as LineIndex.Line)
	return out


## 名字总数（跨三类）
static func total(data: Dictionary) -> int:
	var n := 0
	for k in KINDS:
		n += (data.get(k, {}) as Dictionary).size()
	return n


## 只读不写 / 只写不读。**引擎侧会读写的名字不算问题**，所以先排除掉。
##
## 只读不写 = error（剧本和引擎里都没人设过它，几乎一定是拼错，那条分支永远走不到）；
## 只写不读 = warn（可能只是纯记录）。
## 名字在引擎侧出现过 = info（小游戏通关、章节解锁这类旗标本来就是引擎设的）。
static func issues(data: Dictionary) -> Array:
	var engine := engine_names()
	var out: Array = []
	for kind in KINDS:
		var table: Dictionary = data.get(kind, {})
		for name in table.keys():
			var e: Dictionary = table[name]
			var w: Array = e.get("writes", [])
			var r: Array = e.get("reads", [])
			var nm := String(name)
			var in_engine := engine.has(nm)
			if w.is_empty() and not r.is_empty():
				if in_engine:
					out.append({
						"level": "info", "kind": kind, "name": nm,
						"message": "%s「%s」剧本里没人设过，但引擎侧有同名 —— 应该没问题"
							% [LABELS[kind], nm],
						"site": r[0],
					})
				else:
					out.append({
						"level": "error", "kind": kind, "name": nm,
						"message": "%s「%s」被读过、但剧本和引擎里都没人设过 —— 拼错了？这条分支永远走不到"
							% [LABELS[kind], nm],
						"site": r[0],
					})
			elif r.is_empty() and not w.is_empty():
				if in_engine:
					out.append({
						"level": "info", "kind": kind, "name": nm,
						"message": "%s「%s」剧本里没人读，但引擎侧会读它 —— 应该没问题"
							% [LABELS[kind], nm],
						"site": w[0],
					})
				else:
					out.append({
						"level": "warn", "kind": kind, "name": nm,
						"message": "%s「%s」只写不读 —— 是不是忘了接条件？"
							% [LABELS[kind], nm],
						"site": w[0],
					})
	return out


## 只数**真正算问题**的（error + warn），info 不计 —— 侧栏那行要的是可信的数字。
static func problem_count(data: Dictionary) -> int:
	var n := 0
	for it in issues(data):
		if String((it as Dictionary).get("level", "")) != "info":
			n += 1
	return n


## 引擎侧会读写的名字。
##
## 为什么需要：小游戏通关、章节解锁这些旗标是**引擎**设/读的，剧本里查不到 ——
## 不排除的话「只读不写」会把它们全报成错，作者看两次就不信这个功能了。
##
## ⚠️ 只认**字面量调用**（`get_flag("x")` / `set_var("x", …)`）与
## `chapters.json` 的 `unlock_flag`，**不认注释里出现的名字** ——
## 项目里 `rhythm_qte.gd` 的注释写着「成功时点亮旗标 rhythm_qte_cleared」，
## 但代码里其实没设；那正是要报出来的真问题。
##
## 结果按进程缓存（编辑器里改了游戏代码要重开才刷新）—— 扫一遍 scripts/ 不贵，
## 但这一页会在切页 / 保存时反复算，没必要每次重扫。
static var _engine_cache: Dictionary = {}


static func engine_names() -> Dictionary:
	if not _engine_cache.is_empty():
		return _engine_cache
	var out := {}
	var re := RegEx.new()
	re.compile("(?:get|set|has|add|sub)_(?:flag|var)\\s*\\(\\s*\"([^\"]+)\"")
	_scan_scripts("res://scripts/", re, out)

	# chapters.json 的 unlock_flag 由 route_tracker 在引擎侧读
	var text := FileAccess.get_file_as_string("res://data/scripts/chapters.json")
	var re2 := RegEx.new()
	re2.compile("\"unlock_flag\"\\s*:\\s*\"([^\"]+)\"")
	for m in re2.search_all(text):
		var v := m.get_string(1)
		if not v.is_empty():
			out[v] = true

	_engine_cache = out
	return out


static func _scan_scripts(dir_path: String, re: RegEx, out: Dictionary) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var files := dir.get_files()
	var subs := dir.get_directories()
	dir = null
	for fn in files:
		var f := String(fn)
		if f.get_extension().to_lower() != "gd":
			continue
		var text := FileAccess.get_file_as_string(dir_path + f)
		if text.is_empty():
			continue
		for m in re.search_all(text):
			out[m.get_string(1)] = true
	for sub in subs:
		_scan_scripts(dir_path + String(sub) + "/", re, out)


## 单条变量的一句话摘要，如「写 3 · 读 1」
static func summary(entry: Dictionary) -> String:
	return "写 %d · 读 %d" % [
		(entry.get("writes", []) as Array).size(),
		(entry.get("reads", []) as Array).size()]


# ---------------------------------------------------------------------------

static func _collect_line(out: Dictionary, file: String, line: LineIndex.Line) -> void:
	var site := {"file": file, "line": line.no, "raw": line.raw.strip_edges()}

	# 台词 / 章节名 / 结局标题里的 `{$名字}` 也是「读」。
	# 漏掉这一处的话，一个只在台词里用到的变量会被报成「只写不读」，
	# 而真正拼错的那个（只读不写）反倒看不出来。
	if _is_text_line(line):
		for name in GvsInterp.names_in(line.text):
			_add_interp_read(out, name, site)

	if line.kind != LineIndex.Line.DIRECTIVE:
		return

	match line.head:
		"flag":
			_add(out, "flag", _arg(line, 0), "writes", site)
		"affection":
			_add(out, "affection", _arg(line, 0), "writes", site)
		"set", "add", "sub":
			# `set var x 3` 与 `set x 3` 两种写法项目里都在用
			var idx := 1 if _arg(line, 0) == "var" else 0
			_add(out, "var", _arg(line, idx), "writes", site)
		"call":
			# 具名参数在子过程里就是变量（`call f who=alice` → 子过程写 `{$who}`），
			# 算作一次写入，否则子过程那边会被误判成「只读不写」。
			for key in line.params.keys():
				_add(out, "var", String(key), "writes", site)
		"carry":
			# carry <类别> <名> —— 下一周目继承时会读它
			var kind := _arg(line, 0)
			if KINDS.has(kind):
				_add(out, kind, _arg(line, 1), "reads", site)
		"if", "elif":
			for pair in _cond_reads(line):
				var p: Array = pair
				_add(out, String(p[0]), String(p[1]), "reads", site)


## 这一行会不会产出「给玩家看的文本」（台词 / 旁白 / 章节名 / 结局标题）
static func _is_text_line(line: LineIndex.Line) -> bool:
	if line.kind == LineIndex.Line.DIALOGUE:
		return true
	if line.kind != LineIndex.Line.DIRECTIVE:
		return false
	return LineIndex.Line.SAY_KEYWORDS.has(line.head) \
		or line.head == "chapter" or line.head == "ending"


## `{$名字}` → 对应类别的「读」。
##
## `{$affection.alice}` / `{$flag.met}` 直接落到 affection / flag 两类；
## `{$1}` 是 call 的位置参数（下标不是名字），跳过；
## 其余算变量名。
static func _add_interp_read(out: Dictionary, name: String, site: Dictionary) -> void:
	if name.is_empty() or GvsInterp.is_positional(name):
		return
	if name.begins_with("affection."):
		_add(out, "affection", name.substr("affection.".length()), "reads", site)
		return
	if name.begins_with("flag."):
		_add(out, "flag", name.substr("flag.".length()), "reads", site)
		return
	_add(out, "var", name, "reads", site)


## 条件里读了哪些变量。`LineIndex` 把 `if` 之后整段留在 `cond_text` 里
## （它的语法不是 kv，硬拆会丢信息），所以这里按词扫，规则同 `parse_condition`。
static func _cond_reads(line: LineIndex.Line) -> Array:
	var out: Array = []
	var toks := line.cond_text.split(" ", false)
	var i := 0
	if toks.size() > 0 and String(toks[0]) == "not":
		i = 1
	if i >= toks.size():
		return out
	var head := String(toks[i])
	if not KINDS.has(head):
		return out
	if i + 1 < toks.size():
		out.append([head, String(toks[i + 1])])
	return out


static func _arg(line: LineIndex.Line, idx: int) -> String:
	if idx < 0 or idx >= line.args.size():
		return ""
	return String(line.args[idx])


static func _add(out: Dictionary, kind: String, name: String, bucket: String,
		site: Dictionary) -> void:
	if name.is_empty() or not out.has(kind):
		return
	var table: Dictionary = out[kind]
	if not table.has(name):
		table[name] = {"writes": [], "reads": []}
	var e: Dictionary = table[name]
	var list: Array = e[bucket]
	# 同一行可能出现两次（`if flag a and flag b` 之类），去重
	for s in list:
		var d: Dictionary = s
		if int(d.get("line", 0)) == int(site["line"]) \
				and String(d.get("file", "")) == String(site["file"]):
			return
	list.append(site)
