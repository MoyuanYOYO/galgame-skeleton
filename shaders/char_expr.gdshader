shader_type canvas_item;

// 立绘表情交叉过渡
//
// 直接换 texture 是硬切换，看着很生硬。这里同时采样两张：
//   TEXTURE   —— 节点自己的贴图，换成了「新表情」
//   from_tex  —— 上一张「旧表情」，由代码塞进来
// progress 从 0 推到 1，两张图交叉混合。
//
// has_from 为 false 时直接输出 TEXTURE，避免没设 from_tex 时采到空白纹理。
//
// ⚠ modulate（focus_speaker 改的 modulate.rgb、淡入淡出改的 modulate.a）：
// canvas_item 的 fragment 里，进来的 COLOR **已经等于「贴图 × 顶点色」**
// （顶点色 = modulate × self_modulate × 各级父节点）。于是有两种写法都会坏，
// 而且都只有逐像素量渲染色才看得出来（modulate 属性本身一直是对的，逻辑测试全绿）：
//
//   1) COLOR = texture(...)          —— 顶点色被整个丢掉。
//      表现为「一挂上本材质，说话人压暗与淡入淡出就永久失效」——
//      女主换过一次表情之后，再也不会被压暗，就是这一条。
//   2) COLOR = texture(...) * COLOR  —— 顶点色叠了两遍（变成 贴图² 量级），
//      整张立绘恒暗约 40%，一挂材质就变深色且回不来。
//
// 正确写法：在 vertex() 里单独取一次顶点色，fragment 里乘回去。
// 对照表（无材质 / COLOR=tex / COLOR=tex*COLOR / 本写法）见
// tools/char_shader_probe.gd，smoke 第 22 节的守卫盯着这两种坏法。

uniform sampler2D from_tex : filter_linear, repeat_disable;
uniform float progress : hint_range(0.0, 1.0) = 1.0;
uniform bool has_from = false;

// 干净的顶点色。fragment 里的 COLOR 已经被贴图乘过，取不出这一份。
// flat 是安全的：整个矩形四个顶点的 modulate 相同。
varying flat vec4 vcol;

void vertex() {
	vcol = COLOR;
}

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	// 注意：Godot 的着色语言不允许在 fragment() 里用 return ——
	// 必须写成 if/else 把结果都赋给 COLOR，否则编译直接失败
	// （表现为表情过渡整段失效，而逻辑测试仍然全绿，很难发现）。
	if (has_from) {
		vec4 prev = texture(from_tex, UV);
		base = mix(prev, base, progress);
	}
	COLOR = base * vcol;
}
