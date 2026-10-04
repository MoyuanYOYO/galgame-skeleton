extends RefCounted

## 项目素材索引
##
## 扫一遍 `assets/` 下约定的 7 类素材目录，建「id → 文件信息」的映射。
## 这是编辑器所有面板的共同底座：素材面板、剧本编辑器的角色/表情下拉、
## 缺失看板、立绘差分矩阵、未使用素材反查，全都查这里。
##
## 两个关键取舍：
##
## 1. **图片尺寸用 `Image.load_from_file()` 直读**，不走 `ResourceLoader`。
##    因为刚复制进 assets/ 的新素材还没有 `.import` 文件，走 `load()` 会失败；
##    直读能立刻拿到尺寸，编辑器因此不必等一次 `--import` 才能预览。
##
## 2. 目录约定**从 `ScriptAudit.ASSET_DIRS` 取**，不在这里另写一份 ——
##    素材目录是「剧本引用素材时去哪儿找」的知识，必须只有一个权威。

const ScriptAudit = preload("res://scripts/core/script_audit.gd")

const IMAGE_EXT := ["png", "jpg", "jpeg", "webp"]
const AUDIO_EXT := ["ogg", "mp3", "wav"]
const VIDEO_EXT := ["ogv"]

## 需要索引的类别（顺序即界面展示顺序）
const KINDS := ["bg", "cg", "char", "se", "bgm", "voice", "video"]

const KIND_LABELS := {
	"bg": "背景", "cg": "CG", "char": "立绘",
	"se": "音效", "bgm": "音乐", "voice": "语音", "video": "视频",
}

const KIND_DIRS := {
	"bg": "res://assets/bg/",
	"cg": "res://assets/cg/",
	"char": "res://assets/sprites/",
	"se": "res://assets/audio/se/",
	"bgm": "res://assets/audio/bgm/",
	"voice": "res://assets/audio/voice/",
	"video": "res://assets/video/",
}

## 素材 id 的命名规范：小写字母、数字、下划线
const ID_PATTERN := "^[a-z0-9_]+$"

var table: Dictionary = {}          ## kind → { id → entry }
var conflicts: Array = []           ## 同名多后缀等命名问题
var scan_time_ms: int = 0

## kind → { 组名 → 目录路径 }。**空目录也记** —— 语音页要靠它把「刚建好、
## 还没放语音」的角色也显示出来（只从 id 反推组名的话，空目录会凭空消失，
## 用户就会觉得「新建的角色文件夹没显示」）。
var group_dirs: Dictionary = {}


# ---------------------------------------------------------------------------
# 扫描
# ---------------------------------------------------------------------------

func scan() -> void:
	var t0 := Time.get_ticks_msec()
	table.clear()
	conflicts.clear()
	group_dirs.clear()

	table["bg"] = _scan_flat("bg")
	table["cg"] = _scan_flat("cg")
	table["se"] = _scan_flat("se")
	table["bgm"] = _scan_flat("bgm")
	table["voice"] = _scan_grouped("voice")
	table["video"] = _scan_flat("video")
	table["char"] = _scan_chars()

	scan_time_ms = Time.get_ticks_msec() - t0


## 平铺目录：文件名（去后缀）就是 id
func _scan_flat(kind: String) -> Dictionary:
	var out: Dictionary = {}
	var dir_path := String(KIND_DIRS[kind])
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	_collect(out, kind, dir_path, "", dir.get_files(), _exts_of(kind))
	return out


## 两级目录：`<根>/<组>/<文件>`，**id = `<组>/<文件名>`**。
##
## 语音按角色分目录（`assets/audio/voice/alice/line01.ogg` → 剧本写 `voice alice/line01`）。
## **组名必须进 id** —— 只把目录当纯组织的话，两个角色各有一个 `01.ogg` 就撞了，
## 而撞了之后游戏会播到另一个角色的语音，这种错极难查。
## 根目录下的散文件仍然按文件名当 id（共用音效之类）。
##
## 路径拼出来就是 `VOICE_DIR + "alice/line01" + ".ogg"`，所以游戏侧
## （`AudioManager._find_stream`）和 `ScriptAudit.has_real_asset` 都不用改。
func _scan_grouped(kind: String) -> Dictionary:
	var out: Dictionary = {}
	var root := String(KIND_DIRS[kind])
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	var exts := _exts_of(kind)
	var dirs: Dictionary = {"": root}

	_collect(out, kind, root, "", dir.get_files(), exts)

	var subs := dir.get_directories()
	dir = null
	var names: Array = []
	for s in subs:
		names.append(String(s))
	names.sort()
	for g in names:
		var gs := String(g)
		var sub := DirAccess.open(root + gs + "/")
		if sub == null:
			continue
		var files := sub.get_files()
		sub = null
		dirs[gs] = root + gs + "/"
		_collect(out, kind, root + gs + "/", gs + "/", files, exts)
	group_dirs[kind] = dirs
	return out


## 某一类素材的所有「组名」（语音 = 角色）。按名字排序，不含空组。
##
## ⚠️ **以目录为准，不是以 id 为准** —— 刚建好、还没放语音的角色目录
## 也要算一个组，否则「新建角色 → 返回」时那个文件夹就像没建成功一样
## （用户报的「新建角色返回时不显示新建的角色文件夹」）。
func groups(kind: String) -> PackedStringArray:
	var out := PackedStringArray()
	if group_dirs.has(kind):
		for g in (group_dirs[kind] as Dictionary).keys():
			if String(g).is_empty():
				continue
			out.append(String(g))
		out.sort()
		return out
	# 退化路径：没走过分组扫描的类别，只能从 id 里推
	var seen := {}
	if not table.has(kind):
		return out
	for k in (table[kind] as Dictionary).keys():
		var id := String(k)
		var slash := id.find("/")
		if slash <= 0:
			continue
		var g2 := id.substr(0, slash)
		if seen.has(g2):
			continue
		seen[g2] = true
		out.append(g2)
	out.sort()
	return out


## 某个组的目录路径（**不需要它存在** —— 空组也会给对路径）
func group_dir(kind: String, group: String) -> String:
	if group_dirs.has(kind):
		var d: Dictionary = group_dirs[kind]
		if d.has(group):
			return String(d[group])
	return String(KIND_DIRS.get(kind, "")) + (group if group.is_empty() else group + "/")


## 这个组是不是**已经有目录**了（哪怕里面一条语音都没有）
func group_exists(kind: String, group: String) -> bool:
	if group.is_empty():
		return true
	return group_dirs.has(kind) and (group_dirs[kind] as Dictionary).has(group)


static func _exts_of(kind: String) -> Array:
	if kind == "video":
		return VIDEO_EXT
	if kind in ["se", "bgm", "voice"]:
		return AUDIO_EXT
	return IMAGE_EXT


## 把一个目录里的文件收进索引。`prefix` 是组前缀（`"alice/"` 或 `""`）。
func _collect(out: Dictionary, kind: String, dir_path: String, prefix: String,
		file_names: PackedStringArray, exts: Array) -> void:
	var by_id: Dictionary = {}      # id → [完整文件名, ...]，用来查同名冲突
	for file_name in file_names:
		var fn := String(file_name)
		if _is_meta(fn):
			continue
		var ext := fn.get_extension().to_lower()
		if not exts.has(ext):
			continue
		var id := prefix + fn.get_basename()
		if not by_id.has(id):
			by_id[id] = []
		(by_id[id] as Array).append(fn)

	for id in by_id.keys():
		var files: Array = by_id[id]
		if files.size() > 1:
			conflicts.append({
				"kind": kind, "id": String(id),
				"message": "「%s」有 %d 个同 id 文件：%s" % [id, files.size(), ", ".join(files)],
			})
		var fn := String(files[0])
		var full := dir_path + fn
		var entry := {
			"id": String(id),
			"file": fn,
			"path": full,
			"ext": fn.get_extension().to_lower(),
			"kind": kind,
			"exists": true,
		}
		if kind == "video" or kind in ["se", "bgm", "voice"]:
			entry["duration"] = _audio_length(full)
		else:
			entry["size"] = _image_size(full)
		if not _valid_id(String(id)):
			conflicts.append({
				"kind": kind, "id": String(id),
				"message": "「%s」命名不规范（建议只用小写字母、数字、下划线）" % id,
			})
		out[String(id)] = entry


## 立绘：两级结构 `sprites/<角色>/<表情>.png`，
## 表情也可能是一个**帧序列目录** `sprites/<角色>/<表情>/00.png …`（动态立绘）。
func _scan_chars() -> Dictionary:
	var out: Dictionary = {}
	var root := String(KIND_DIRS["char"])
	var dir := DirAccess.open(root)
	if dir == null:
		return out

	for char_name in dir.get_directories():
		var cid := String(char_name)
		var char_dir := root + cid + "/"
		var exprs: Dictionary = {}
		var animated: Dictionary = {}
		var sub := DirAccess.open(char_dir)
		if sub == null:
			continue

		for fn in sub.get_files():
			var f := String(fn)
			if _is_meta(f):
				continue
			var ext := f.get_extension().to_lower()
			if not IMAGE_EXT.has(ext):
				continue
			var eid := f.get_basename()
			exprs[eid] = {
				"id": eid, "path": char_dir + f, "file": f,
				"size": _image_size(char_dir + f),
			}

		for sub_name in sub.get_directories():
			var eid2 := String(sub_name)
			var frames := _scan_frames(char_dir + eid2 + "/")
			if frames.size() > 0:
				animated[eid2] = {
					"id": eid2, "path": char_dir + eid2 + "/",
					"frame_count": frames.size(), "frames": frames,
					"size": _image_size(String(frames[0])),
					"fps": _anim_fps(char_dir + eid2 + "/"),
				}

		out[cid] = {
			"id": cid, "path": char_dir,
			"exprs": exprs, "animated": animated,
			"exists": not exprs.is_empty() or not animated.is_empty(),
		}

	return out


func _scan_frames(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for fn in dir.get_files():
		var f := String(fn)
		if _is_meta(f):
			continue
		if not IMAGE_EXT.has(f.get_extension().to_lower()):
			continue
		out.append(dir_path + f)
	# 帧名按数字自然排序（00 / 01 / … / 10），不能按字典序，否则 10 会排到 2 前面
	out.sort_custom(func(a: String, b: String) -> bool:
		return a.get_file().get_basename().naturalnocasecmp_to(
			b.get_file().get_basename()) < 0)
	return out


func _anim_fps(dir_path: String) -> float:
	var p := dir_path + "anim.json"
	if not FileAccess.file_exists(p):
		return 12.0
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if typeof(parsed) != TYPE_DICTIONARY:
		return 12.0
	return float((parsed as Dictionary).get("fps", 12.0))


static func _is_meta(file_name: String) -> bool:
	# Godot 的导入产物与 uid 旁文件，都不是素材本体
	return file_name.ends_with(".import") or file_name.ends_with(".uid") \
		or file_name.begins_with(".")


## 素材 id 的命名规范：小写字母、数字、下划线。
##
## 分组素材（语音 `alice/line01`）允许**一层** `/` —— 每段各自校验，
## 所以 `alice/line01` 合法、`Alice/Line01` 与 `a/b/c` 都不合法。
static func _valid_id(id: String) -> bool:
	if id.is_empty():
		return false
	var parts := id.split("/")
	if parts.size() > 2:
		return false
	var re := RegEx.new()
	re.compile(ID_PATTERN)
	for p in parts:
		if re.search(String(p)) == null:
			return false
	return true


# ---------------------------------------------------------------------------
# 元信息读取
# ---------------------------------------------------------------------------

## 图片尺寸。
##
## **顺序很重要**：先走资源加载，失败才直读。
##
## - 已经导入过的素材（有 .import）走 `load()`：快，且不会刷警告。
## - 刚复制进 assets/、还没生成 .import 的新素材走 `Image.load_from_file()`：
##   这条路会打一条 "will not work on export" 警告 —— 编辑器只在开发环境跑、
##   不导出，这个代价可以接受；换来的是**新素材不必等一次 --import 就能预览**。
##
## 注意 `Image.load_from_file()` 在 Godot 4.3+ 是**静态方法且返回 Image**
## （失败返回 null），不是返回 Error 的旧式实例方法 —— 写成
## `img.load_from_file(p) == OK` 会直接编译不过。
static func _image_size(path: String) -> Vector2i:
	if ResourceLoader.exists(path):
		var tex := load(path) as Texture2D
		if tex != null:
			return tex.get_size()
	var img: Image = Image.load_from_file(path)
	if img != null:
		return img.get_size()
	return Vector2i.ZERO


## 音频时长（秒）。读不到返回 0。
##
## 优先走资源加载（已导入的素材）；失败才直读，且**只对 ogg / mp3 直读**。
## 原因：`AudioStreamWAV.load_from_file()` 对部分 wav 会抛引擎级 ERROR
## （`Condition "p_position > length" is true`），这种错误 GDScript 捕获不到，
## 会在控制台刷屏。wav 时长读不到只影响列表上的一行显示，不值得为它忍受噪音。
static func _audio_length(path: String) -> float:
	if ResourceLoader.exists(path):
		var res: Variant = load(path)
		if res is AudioStream:
			return (res as AudioStream).get_length()

	var ext := path.get_extension().to_lower()
	var stream: AudioStream = null
	match ext:
		"ogg":
			stream = AudioStreamOggVorbis.load_from_file(path)
		"mp3":
			stream = AudioStreamMP3.load_from_file(path)
		_:
			# wav / ogv：不直读（见上面的说明）
			return 0.0
	if stream == null:
		return 0.0
	return stream.get_length()


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

func has(kind: String, id: String) -> bool:
	if not table.has(kind):
		return false
	return (table[kind] as Dictionary).has(id)


func get_entry(kind: String, id: String) -> Dictionary:
	if not has(kind, id):
		return {}
	return (table[kind] as Dictionary)[id]


func ids(kind: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not table.has(kind):
		return out
	var d: Dictionary = table[kind]
	var keys := d.keys()
	keys.sort()
	for k in keys:
		out.append(String(k))
	return out


func count(kind: String) -> int:
	if not table.has(kind):
		return 0
	return (table[kind] as Dictionary).size()


## 所有角色 id
func char_ids() -> PackedStringArray:
	var out := PackedStringArray()
	if not table.has("char"):
		return out
	var keys: Array = (table["char"] as Dictionary).keys()
	keys.sort()
	for k in keys:
		out.append(String(k))
	return out


## 某角色的静态表情 id 列表
func char_exprs(cid: String) -> PackedStringArray:
	var out := PackedStringArray()
	var e := get_entry("char", cid)
	if e.is_empty():
		return out
	var exprs: Dictionary = e.get("exprs", {})
	var keys: Array = exprs.keys()
	keys.sort()
	for k in keys:
		out.append(String(k))
	return out


## 某角色的帧序列表情 id 列表
func char_animated(cid: String) -> PackedStringArray:
	var out := PackedStringArray()
	var e := get_entry("char", cid)
	if e.is_empty():
		return out
	var anim: Dictionary = e.get("animated", {})
	var keys: Array = anim.keys()
	keys.sort()
	for k in keys:
		out.append(String(k))
	return out


## 某角色的全部表情（静态 + 动态），给下拉框用
func char_all_exprs(cid: String) -> PackedStringArray:
	var out := PackedStringArray()
	out.append_array(char_exprs(cid))
	out.append_array(char_animated(cid))
	return out


# ---------------------------------------------------------------------------
# 与剧本的交叉分析
# ---------------------------------------------------------------------------

## 剧本引用了哪些素材、缺哪些（直接复用 ScriptAudit，保证与 CI 校验同口径）
func script_usage() -> Dictionary:
	return ScriptAudit.assets()


func missing() -> Dictionary:
	return ScriptAudit.missing_assets()


## 反向：assets/ 里有哪些文件剧本从没引用过。
##
## 这是 ScriptAudit 不做的一面 —— 它只做正向（剧本→素材），
## 所以「删了剧本引用之后留下的孤儿文件」永远查不出来。
func unused() -> Dictionary:
	var used := script_usage()
	var out: Dictionary = {}
	for kind in KINDS:
		if kind == "video":
			continue      # 视频没有收藏表，单独看
		var used_ids: Dictionary = used.get(kind, {})
		var unused_ids: Array = []
		if kind == "char":
			# 立绘的「被引用」是角色级：任一指令提到该角色即算用过
			for cid in char_ids():
				if not used_ids.has(cid):
					unused_ids.append(cid)
		else:
			for id in ids(kind):
				if not used_ids.has(id):
					unused_ids.append(id)
		if not unused_ids.is_empty():
			out[kind] = unused_ids
	return out


## 素材健康检查：尺寸/格式是否符合约定
func health() -> Array:
	var issues: Array = []
	for id in ids("bg"):
		var e := get_entry("bg", id)
		var s: Vector2i = e.get("size", Vector2i.ZERO)
		if s == Vector2i.ZERO:
			issues.append({"level": "warn", "kind": "bg", "id": id,
				"message": "读不出图片尺寸（文件损坏或格式不受支持）"})
		elif s.x < 1280 or s.y < 720:
			issues.append({"level": "warn", "kind": "bg", "id": id,
				"message": "背景分辨率偏低（%d×%d，建议 1920×1080）" % [s.x, s.y]})
	for id in ids("cg"):
		var e := get_entry("cg", id)
		var s: Vector2i = e.get("size", Vector2i.ZERO)
		if s == Vector2i.ZERO:
			issues.append({"level": "warn", "kind": "cg", "id": id,
				"message": "读不出图片尺寸"})
	for cid in char_ids():
		var e := get_entry("char", cid)
		for eid in (e.get("exprs", {}) as Dictionary).keys():
			var info: Dictionary = (e["exprs"] as Dictionary)[eid]
			var s: Vector2i = info.get("size", Vector2i.ZERO)
			if s == Vector2i.ZERO:
				continue
			if s.y < 400:
				issues.append({"level": "warn", "kind": "char", "id": "%s/%s" % [cid, eid],
					"message": "立绘高度只有 %dpx，可能不是全身图" % s.y})
	for issue in conflicts:
		var c: Dictionary = issue
		issues.append({"level": "error", "kind": String(c.get("kind", "")),
			"id": String(c.get("id", "")), "message": String(c.get("message", ""))})
	return issues


## 素材目录的绝对文件系统路径（用于「在资源管理器中打开」）
static func abs_dir(kind: String) -> String:
	var p := String(KIND_DIRS.get(kind, ""))
	if p.begins_with("res://"):
		return ProjectSettings.globalize_path(p)
	return p


## 生成一个不冲突的文件名（导入时用）
static func unique_file_name(kind: String, base_id: String, ext: String) -> String:
	var dir_path := String(KIND_DIRS.get(kind, ""))
	var candidate := "%s.%s" % [base_id, ext]
	var n := 2
	while FileAccess.file_exists(dir_path + candidate):
		candidate = "%s_%d.%s" % [base_id, n, ext]
		n += 1
	return candidate
