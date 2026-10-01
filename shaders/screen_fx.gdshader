shader_type canvas_item;
render_mode unshaded;

// 全屏后处理特效（错乱 / 扭曲 / 马赛克 …）
//
// 挂在一个铺满屏幕的 ColorRect 上（见 scripts/stage/screen_fx.gd）。
// 它前面必须有一个 BackBufferCopy（VIEWPORT 模式）把「到那时为止已经画好的
// 整屏」copy 进 back buffer —— 否则 hint_screen_texture 读到的是一张空图，
// 特效会把画面变成一片黑。
//
// strength = 0 时逐像素原样输出。这是「关闭」的判据，也是 ScreenFx 整层
// 隐藏的依据（不显示就没有这次全屏采样与拷贝的开销）。
//
// 注意：入口函数 fragment() 里**不能用 return** —— Godot 着色语言不允许，
// 而且不会让脚本报错，只是这一帧渲染不出来。tools/smoke.gd 第 22 节会扫它。
//
// mode 由 GDScript 侧映射（见 scripts/core/screen_fx_spec.gd），
// 顺序必须与那边的 KINDS 一致。

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable;

uniform int mode = 0;
uniform float strength : hint_range(0.0, 4.0) = 0.0;

// strength = 1 时各效果的基准量。调手感改这里，不用动剧本。
const float GLITCH_SLICE = 0.14;   // 被撕裂的条带占多少比例
const float GLITCH_SHIFT = 0.035;  // 条带最大横向位移（UV）
const float GLITCH_RGB   = 0.010;  // RGB 分离最大偏移（UV）
const float WAVE_AMP     = 0.022;  // 波纹振幅（UV）
const float WAVE_FREQ    = 15.0;   // 波纹密度
const float SWIRL_MAX    = 3.6;    // 漩涡最大旋角（弧度）
const float CHROMA_MAX   = 0.016;  // 色差最大偏移（UV）
const float PIXEL_MAX    = 0.030;  // 马赛克最大块（UV）
const float BLUR_RADIUS  = 0.010;  // 模糊最大半径（UV，向四周各散这么远）

// 便宜的伪随机。同一格 (x, y) 一定返回同一个值 —— 撕裂条带靠它保持
// 在几帧之内稳定，否则每帧全随机，看起来只是噪点而不是「信号错乱」。
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

vec4 fetch(vec2 uv) {
	return texture(screen_tex, uv);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec4 src = fetch(uv);
	vec3 col = src.rgb;

	if (mode == 0) {
		// 错乱：随机挑一部分横条整体横移，再叠 RGB 分离与扫描线。
		// 只撕一部分条带 —— 全撕看起来像花屏，不像「信号出问题」。
		float t = floor(TIME * 14.0);
		float row = floor(uv.y * 26.0);
		float r = hash21(vec2(row, t));
		float torn = step(1.0 - GLITCH_SLICE * clamp(strength, 0.0, 1.0), r);
		float shift = (hash21(vec2(row, t + 7.0)) * 2.0 - 1.0)
			* GLITCH_SHIFT * strength * torn;
		vec2 duv = vec2(shift, 0.0);
		float ca = GLITCH_RGB * strength;
		col = vec3(
			fetch(uv + duv + vec2(ca, 0.0)).r,
			fetch(uv + duv).g,
			fetch(uv + duv - vec2(ca, 0.0)).b);
		// 扫描线（隔行压暗），越强越明显
		col *= 1.0 - 0.30 * clamp(strength, 0.0, 1.0) * step(0.5, fract(uv.y * 260.0));
	} else if (mode == 1) {
		// 波纹扭曲：横竖两路正弦，相位不同以免看起来像规则网格
		float amp = WAVE_AMP * strength;
		uv.x += sin(uv.y * WAVE_FREQ + TIME * 3.2) * amp;
		uv.y += cos(uv.x * WAVE_FREQ * 0.7 + TIME * 2.4) * amp * 0.55;
		col = fetch(uv).rgb;
	} else if (mode == 2) {
		// 漩涡：越靠近中心转得越多，边缘几乎不动
		vec2 c = uv - vec2(0.5);
		float d = length(c);
		float a = SWIRL_MAX * strength * max(0.55 - d, 0.0);
		float s = sin(a);
		float co = cos(a);
		uv = vec2(0.5) + vec2(c.x * co - c.y * s, c.x * s + c.y * co);
		col = fetch(uv).rgb;
	} else if (mode == 3) {
		// 马赛克：块大小随强度增长，再与原始画面按 strength 混合，
		// 这样强度是连续可调的，不会在某个阈值上「啪」地跳变
		float k = clamp(strength, 0.0, 1.0);
		float block = max(PIXEL_MAX * k, 0.0008);
		vec2 puv = (floor(uv / block) + 0.5) * block;
		col = fetch(mix(uv, puv, k)).rgb;
	} else if (mode == 4) {
		// 色差：红蓝往两边拉开，绿不动
		float ca = CHROMA_MAX * strength;
		col = vec3(
			fetch(uv + vec2(ca, 0.0)).r,
			fetch(uv).g,
			fetch(uv - vec2(ca, 0.0)).b);
	} else if (mode == 5) {
		// 反色 / 底片
		col = mix(col, vec3(1.0) - col, clamp(strength, 0.0, 1.0));
	} else {
		// 模糊：5x5 二十五抽头。半径小了会比 3x3 更糊（三次采样会拉出三层鬼影），
		// 5x5 才像「蒙了一层」，代价也还能接受 —— 它本来就是短促的转场效果。
		float r = BLUR_RADIUS * strength;
		vec4 sum = vec4(0.0);
		for (int i = -2; i <= 2; i++) {
			for (int j = -2; j <= 2; j++) {
				sum += fetch(uv + vec2(float(i), float(j)) * (r * 0.5));
			}
		}
		col = (sum / 25.0).rgb;
	}

	COLOR = vec4(col, src.a);
}
