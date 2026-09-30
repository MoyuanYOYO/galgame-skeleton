extends Node

## 剧本静态校验 + 素材清单（headless 可跑，适合做 CI 门禁）
##
##   "D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --headless --path . res://tools/audit.tscn
##
## 有错误时退出码为 1，可以直接挂到 CI 上。

func _ready() -> void:
	var result := ScriptAudit.audit()
	var errors: Array = result["errors"]
	var warnings: Array = result["warnings"]

	print("=== 剧本校验 ===")
	print("扫了 %d 个文件、%d 条指令" % [result["files"], result["commands"]])
	for e in errors:
		print("  [错误] %s" % String(e))
	for w in warnings:
		print("  [提醒] %s" % String(w))
	if errors.is_empty() and warnings.is_empty():
		print("  没有问题")

	print("")
	print("=== 素材清单 ===")
	var all_assets := ScriptAudit.assets()
	var total := 0
	var real := 0
	for kind in all_assets.keys():
		var table: Dictionary = all_assets[kind]
		var hit := 0
		for id in table.keys():
			total += 1
			if bool(table[id]):
				hit += 1
		real += hit
		print("  %-6s %d / %d 有真实文件" % [kind, hit, table.size()])

	var missing := ScriptAudit.missing_assets()
	if not missing.is_empty():
		print("")
		print("  缺素材的 id（会退回程序化占位图 / 静默跳过，不影响运行）：")
		for kind in missing.keys():
			var list: Array = missing[kind]
			print("    %s：%s" % [kind, ", ".join(list)])

	print("")
	print("[audit] 完成（错误 %d / 提醒 %d / 素材 %d/%d）"
		% [errors.size(), warnings.size(), real, total])
	get_tree().quit(0 if errors.is_empty() else 1)
