extends Node

## 能力探测：Godot 4.7.2 到底能播什么、能加载什么动画格式
##
##   Godot --headless --path . res://tools/capability_probe.tscn

func _ready() -> void:
	print("=== Godot %s ===" % Engine.get_version_info().string)

	print("\n--- VideoStream 相关类 ---")
	for cls in ClassDB.get_class_list():
		var n := String(cls)
		if n.begins_with("VideoStream") or n.begins_with("Video"):
			var can_instantiate := ClassDB.can_instantiate(n)
			print("  %-34s instantiable=%s  inherits=%s"
				% [n, can_instantiate, ClassDB.get_parent_class(n)])

	print("\n--- 可加载的 VideoStream 扩展名 ---")
	print("  ", ResourceLoader.get_recognized_extensions_for_type("VideoStream"))

	print("\n--- 可加载的 Texture2D 扩展名 ---")
	print("  ", ResourceLoader.get_recognized_extensions_for_type("Texture2D"))

	print("\n--- 可加载的 Image 扩展名 ---")
	print("  ", ResourceLoader.get_recognized_extensions_for_type("Image"))

	print("\n--- 动画相关节点 / 资源 ---")
	for n in ["AnimatedSprite2D", "Sprite2D", "TextureRect", "AnimationPlayer",
			"SpriteFrames", "AnimatedTexture", "AtlasTexture", "VideoStreamPlayer",
			"CanvasItem", "SubViewport", "SubViewportContainer", "GPUParticles2D"]:
		print("  %-24s 存在=%s" % [n, ClassDB.class_exists(n)])

	print("\n--- Image 的静态加载入口 ---")
	for m in ClassDB.class_get_method_list("Image", true):
		var mn := String(m.get("name", ""))
		if mn.begins_with("load_") or mn.contains("webp") or mn.contains("png"):
			print("  ", mn)

	print("\n--- ResourceImporter 里和视频/动画有关的 ---")
	for cls in ClassDB.get_class_list():
		var n := String(cls)
		if n.begins_with("ResourceImporter") and (
				n.contains("Video") or n.contains("WebP") or n.contains("Image")
				or n.contains("Texture")):
			print("  ", n)

	print("\n--- SpriteFrames 能装什么 ---")
	var sf := SpriteFrames.new()
	print("  SpriteFrames.new() ok, 动画数量=%d" % sf.get_animation_names().size())
	print("  支持的类型: 任意 Texture2D（含 AtlasTexture / CompressedTexture2D）")

	print("\n--- AnimatedTexture 参数 ---")
	var at := AnimatedTexture.new()
	print("  MAX_FRAMES=%d  默认 fps=%.1f" % [AnimatedTexture.MAX_FRAMES, at.speed_scale])

	print("\n--- 渲染器 ---")
	print("  ", ProjectSettings.get_setting("rendering/renderer/rendering_method"))
	print("  ", ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile"))

	get_tree().quit(0)
