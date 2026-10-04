class_name TextEffects
extends RefCounted

## 项目自定义的 BBCode 文字特效 —— **一处登记，三处使用**
## （对白框 / 剧情回看 / 编辑器预览）。
##
## ⚠️ **没注册的特效标签会原样漏成文本。** RichTextLabel 把未知标签当普通字符处理，
## 于是 `[bounce]弹跳[/bounce]` 会连着方括号一起显示出来。这个坑踩过两次：
## 回看面板漏过一次（注释里写着），编辑器预览又漏了一次 ——
## 所以列表必须只有一份，谁要加特效就加在这里。
##
## `[shake]` / `[wave]` / `[rainbow]` / `[fade]` / `[pulse]` 是 **Godot 内置**的，
## 不用登记，直接可用。
##
## 三个特效都是**无状态**的（只认 bbcode 名字），所以整项目共用一份实例就够，
## 不必每个 RichTextLabel 都 new 一遍。

static var _cache: Array[RichTextEffect] = []


## 共享的特效实例数组（直接赋给 `RichTextLabel.custom_effects`）
static func all() -> Array[RichTextEffect]:
	if _cache.is_empty():
		_cache = [
			BounceEffect.new(),
			GlitchEffect.new(),
			BlinkEffect.new(),
		]
	return _cache
