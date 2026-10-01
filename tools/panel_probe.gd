extends Node

## 功能窗口尺寸探针：
##   "D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/panel_probe.tscn
##
## 各面板尺寸由内容撑出来（VBox 里塞了什么就多高），静态算不可靠，
## 这里走真实打开路径，等布局稳定后打印带 panel 样式的节点的最终矩形。
## 产物只 print，不改任何文件。

const MAIN_SCENE := "res://scenes/main.tscn"

var _main: Node


func _ready() -> void:
	await _wait(0.3)
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(0.6)
	_main.call("_on_start_requested")
	await _wait(1.5)

	# ---- 对话框（对照：应与 ui_theme 的 offset 换算一致）----
	_report("dialogue_box", _main.get("dialogue_box"))

	# ---- 回看（先推进几句才有内容）----
	var runner: ScriptRunner = _main.get("runner") as ScriptRunner
	var guard := 40
	while not runner.is_waiting_choice() and guard > 0:
		guard -= 1
		_main.call("_on_advance_requested")
		await _wait(0.03)
	_main.call("_open_backlog")
	await _wait(0.5)
	_report("backlog", _main.get("backlog"))
	_main.call("_close_modals")
	await _wait(0.2)

	# ---- 设置 ----
	_main.call("_open_settings")
	await _wait(0.5)
	_report("settings", _main.get("settings"))
	_main.call("_close_modals")
	await _wait(0.2)

	# ---- 存档 / 读档（存一档让面板里有真实行）----
	_main.call("_save_to_slot", 1)
	await _wait(0.5)
	_main.call("_open_save_load", false)
	await _wait(0.5)
	_report("save_load", _main.get("save_load"))
	_main.call("_close_modals")
	await _wait(0.2)

	# ---- 记录 ----
	_main.get("records").call("present")
	await _wait(0.5)
	_report("records", _main.get("records"))
	_main.get("records").call("hide_panel")
	await _wait(0.2)

	# ---- 鉴赏（解锁内容才有卡片）----
	CollectionManager.unlock("cg", "cg_classroom")
	CollectionManager.unlock("cg", "cg_rooftop")
	CollectionManager.unlock("cg", "cg_street")
	CollectionManager.unlock("music", "daily")
	CollectionManager.unlock("music", "sunset")
	CollectionManager.unlock("music", "theme")
	_main.call("_on_gallery_requested")
	await _wait(0.6)
	_report("gallery_cg", _main.get("gallery"))
	var gallery: GalleryPanel = _main.get("gallery") as GalleryPanel
	gallery.show_tab(GalleryPanel.TAB_MUSIC)
	await _wait(0.5)
	_report("gallery_music", _main.get("gallery"))
	gallery.show_tab(GalleryPanel.TAB_CG)
	await _wait(0.3)

	# ---- 音乐页标签字体颜色调试 ----
	var music: Node = _main.get_node_or_null("UILayer/GalleryPanel/Panel/VBox/MusicRoot")
	if music != null:
		for nname in ["%ListHeader", "%NowPlaying", "%TrackArtist", "%MusicTime"]:
			var lbl: Label = music.get_node_or_null(NodePath(nname))
			if lbl != null:
				print("[probe] %s font_color=%s visible=%s text=%s"
					% [nname, lbl.get_theme_color("font_color"), lbl.visible, lbl.text])
			else:
				print("[probe] %s = <null>" % nname)
		print("[probe] music script path = ", music.get_script().resource_path)

	# ---- CG 查看器 ----
	_main.call("_on_cg_activated", "cg_rooftop")
	await _wait(0.6)
	_report("cg_viewer", _main.get("cg_viewer"))

	print("[probe] DONE")
	get_tree().quit(0)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _report(tag: String, root: Node) -> void:
	if root == null or not is_instance_valid(root):
		print("[probe] %s = <null>" % tag)
		return
	var panel := _find_styled(root)
	if panel == null:
		print("[probe] %s root.size=%s <无样式面板>" % [tag, root.size])
		return
	print("[probe] %s size=%s pos=%s" % [tag, panel.size, panel.global_position])


## 递归找第一个带 panel 样式 override 的 Control（apply_panel 的落点）。
func _find_styled(node: Node) -> Control:
	if node is Control and node.has_theme_stylebox_override("panel"):
		return node
	for child in node.get_children():
		var hit := _find_styled(child)
		if hit != null:
			return hit
	return null
