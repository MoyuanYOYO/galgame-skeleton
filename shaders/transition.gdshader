shader_type canvas_item;

// 通用转场遮罩
//
// progress 从 0 推到 1，上层图按不同方式逐渐显现。
// 挂在「新画面」那一层上（背景转场时是 BgB，CG 转场时是 CgRect）。
//
// 四种模式：
//   0 溶解    按噪声阈值逐块显现，最柔和
//   1 擦除    从左到右扫过
//   2 百叶窗  每条叶片从下往上展开
//   3 圆形    从画面中心扩散
//
// ⚠ modulate：canvas_item 的 fragment 里进来的 COLOR 已经等于「贴图 × 顶点色」，
// 直接给 COLOR 赋值就等于把它丢掉（modulate 失效），乘一遍则等于叠两遍。
// 所以同样要在 vertex() 里单独取顶点色、fragment 里乘回去 —— 与
// char_expr.gdshader 是同一个坑，理由与实测见那里的注释和
// tools/char_shader_probe.gd。
//
// 遮罩路径下代码会把 modulate.a 给满、淡入淡出走的是另一条路径（不用本材质），
// 所以这里乘不乘在当下看不出差别；但留着「只认贴图」的写法，等于埋一颗
// 「哪天给这层加个淡入就直接失效」的雷。

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform int mode : hint_range(0, 3) = 0;
uniform float softness : hint_range(0.005, 0.5) = 0.06;
// 溶解的颗粒密度 / 百叶窗的叶片数。数值越大越细。
// 12 在 1080p 上每块有 160px，太粗；30 大约是 64px，更接近常见的溶解观感。
uniform float density : hint_range(2.0, 80.0) = 30.0;

// 干净的顶点色（modulate × self_modulate × 各级父节点）
varying flat vec4 vcol;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	vcol = COLOR;
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float mask = 0.0;

	if (mode == 0) {
		// 溶解：每个格子有自己的阈值，progress 越过它就亮起来
		float threshold = hash21(floor(UV * density));
		mask = smoothstep(threshold - softness, threshold + softness, progress);
	} else if (mode == 1) {
		// 擦除：progress 扫过 UV.x 就显现
		mask = smoothstep(UV.x - softness, UV.x + softness, progress);
	} else if (mode == 2) {
		// 百叶窗：叶片内部从下往上展开
		float band = fract(UV.y * density);
		mask = smoothstep(band - softness, band + softness, progress);
	} else {
		// 圆形：从中心向外扩散
		float radius = progress * 0.78;
		float dist = distance(UV, vec2(0.5));
		mask = 1.0 - smoothstep(radius - softness, radius + softness, dist);
	}

	COLOR = vec4(tex.rgb, tex.a * mask) * vcol;
}
