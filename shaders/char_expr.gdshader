shader_type canvas_item;

// 立绘表情交叉过渡
//
// 直接换 texture 是硬切换，看着很生硬。这里同时采样两张：
//   TEXTURE   —— 节点自己的贴图，换成了「新表情」
//   from_tex  —— 上一张「旧表情」，由代码塞进来
// progress 从 0 推到 1，两张图交叉混合。
//
// has_from 为 false 时直接输出 TEXTURE，避免没设 from_tex 时采到空白纹理。

uniform sampler2D from_tex : filter_linear, repeat_disable;
uniform float progress : hint_range(0.0, 1.0) = 1.0;
uniform bool has_from = false;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	// 注意：Godot 的着色语言不允许在 fragment() 里用 return ——
	// 必须写成 if/else 把结果都赋给 COLOR，否则编译直接失败
	// （表现为表情过渡整段失效，而逻辑测试仍然全绿，很难发现）。
	if (has_from) {
		vec4 prev = texture(from_tex, UV);
		COLOR = mix(prev, base, progress);
	} else {
		COLOR = base;
	}
}
