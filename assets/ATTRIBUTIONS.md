# 素材来源与授权

本工程的素材分两类：**AI 生成的美术** 与 **CC0 公共领域的音频**。
两类都不要求署名，这里记录来源是为了日后可追溯、也方便替换。

---

## 一、美术素材（背景 / 立绘 / CG）

全部由 AI 生成，**无第三方版权**，可自由使用与修改。

生成后经过统一后处理（见 `.workbuddy/tmp/process_assets.py`）：

- 背景 / CG：原图 1536×1024 → 裁掉底部 160px → 缩放为 1920×1080
  （裁掉的底部正好是生成平台的水印区，一举两得）
- 立绘：白底转透明（只抠与画布边缘连通的白色，保留衣服上的白色），并裁去透明边距

| 文件 | 内容 |
| --- | --- |
| `assets/bg/classroom.png` | 教室 · 春日清晨 |
| `assets/bg/rooftop.png` | 天台 · 黄昏 |
| `assets/bg/street.png` | 校门前街道 · 樱花 |
| `assets/sprites/alice/normal.png` | 女主角 · 平静微笑 |
| `assets/sprites/alice/smile.png` | 女主角 · 开心大笑（差分） |
| `assets/sprites/bob/normal.png` | 男主角 · 常态 |
| `assets/cg/cg_classroom.png` | CG · 教室清晨 |
| `assets/cg/cg_rooftop.png` | CG · 天台黄昏 |
| `assets/cg/cg_street.png` | CG · 放学路上 |
| `assets/cg/cg_true_end.png` | CG · 真结局（樱花树下） |
| `assets/cg/cg_secret_01.png` | CG · 隐藏（星空天台） |
| `assets/cg/cg_secret_02.png` | CG · 隐藏（雨中校门） |

> 角色设定（跨图保持一致）：女主角为长直栗棕色头发 + 白色发饰 + 深蓝水手服（白领、红领巾）；
> 男主角为黑色短发 + 深蓝立领学兰制服。后续补图请沿用这段描述。

---

## 二、UI 素材（按钮 / 面板 / 对话框）— v5 樱花和纸套件

当前 UI（v5，浅色「樱花和纸」主题）由 **AI 生成底纹 + 程序绘制几何** 合成，
无第三方版权，可自由使用与修改。处理脚本 `.workbuddy/tmp/build_ui_sakura_washi.py`。

| 文件 | 质感来源 | 几何 |
| --- | --- | --- |
| `ui_panel_*.png` | AI 和纸纸纹（灰度重上色到固定奶油色域） | 程序画金线框 + 樱花角饰 + 圆角 |
| `ui_panel_dialogue.png` | 同上 + AI 樱花瓣图案（色相抠图重上色） | 同上 |
| `ui_panel_nameplate.png` | — | 程序画玫红横向渐变 + 金底线 |
| `ui_btn_flat/main_*.png` | AI 和纸纸纹 | 程序画奶油底 + 金边 + 四态 |
| `ui_btn_gold_*.png` | — | 程序画玫红渐变（标题主按钮）+ 四态 |

原始生成图（含右下角平台水印，脚本内已裁除 `WM_AVOID=340px`）：

| 生成素材 | 用途 |
| --- | --- |
| `.workbuddy/tmp/gen_washi/Seamless_tileable_washi_*.png` | 和纸纸纹 |
| `.workbuddy/tmp/gen_washi/Seamless_tileable_pattern_of_s_*.png` | 樱花瓣图案 |
| `.workbuddy/tmp/gen/A_single_delicate_corner_ornam_*.png` | 樱花藤蔓角饰线稿（v4 起沿用） |

### 关键做法（换风格时照抄）

1. **和纸底纹去随机**：AI 生成的纸纹色调不可控，统一转灰度后用
   `ImageOps.colorize` 重上色到固定奶油色域 —— 任何一批生成图出来都是同一色号。
2. **花瓣图案色相抠图**：生成图整体太浅（最深像素亮度才 182），
   亮度抠 alpha 接近全透明（可见率 0.8%）；改按「偏粉 / 偏金」色相判别、
   直接以目标色重画，可见率 7.4%。
3. **按钮 64×64、圆角 10 = texture_margin 10**（圆角不得大于切边）；
   面板 192×192、圆角 ≤20、角饰 40px + 内缩 3 ≤ margin 48。
4. **四态**：hover 提亮、pressed 压暗 + 内阴影、disabled 去饱和半透明，
   几何完全一致，切换状态不跳动。

> **浅色主题的连带改动**（换回深色主题时同样要过一遍这串检查）：
> `ui_theme.json` 的 text/text_dim 换成深墨色；每个按钮预设补齐
> font_hover/pressed 颜色（回退值是白色，浅底上会消失）；标题文字单独走
> `palette.title_text` 键（坐在深色底板上，不跟 text 走）；回看面板的
> BBCode 颜色改用 `Color.to_html()`；节奏 QTE 的画布/轨道颜色改读主题。

### 历史：v4 及更早（Kenney，已被替换）

v4 之前按钮来自 [Kenney](https://kenney.nl)（CC0）的 ui-pack，做色相旋转适配；
窗口底板是程序画的细线框 + 樱花角饰（`build_ui_v4_ornate.py`）。
当时的深色底板取值：对话框 `(22,20,38,236)` / 通用面板 `(28,25,47,246)` /
名牌 `(54,47,92,246)` / 鉴赏面板 `(28,25,47,244)`。

> `button_gold.png` / `button_ninepatch.png` 是工程早期自带的示意素材，未被配置引用。

---

## 三、音频素材

全部来自 [OpenGameArt.org](https://opengameart.org)，授权均为 **CC0 1.0（公共领域）**，
可商用、可修改、无需署名。

### BGM — `assets/audio/bgm/`

| 文件 | 原曲名 | 作者 | 来源 |
| --- | --- | --- | --- |
| `daily.ogg` | Calm3 - Peaceful Days | Juhani Junkala (SubspaceAudio) | [JRPG Pack 4 Calm](https://opengameart.org/content/jrpg-pack-4-calm) |
| `sunset.ogg` | Calm5 - Summer Memories | Juhani Junkala (SubspaceAudio) | 同上 |
| `theme.ogg` | Calm1 - A Place I Call Home | Juhani Junkala (SubspaceAudio) | 同上 |
| `ending_theme.ogg` | Calm6 - Innocence | Juhani Junkala (SubspaceAudio) | 同上 |
| `tension.wav` | Tension Theme | Umplix | [Tension Theme](https://opengameart.org/content/tension-theme) |

### 音效 — `assets/audio/se/`

| 文件 | 原文件 | 作者 | 来源 |
| --- | --- | --- | --- |
| `bell.wav` | bell_ding1.wav | PWL | [Bell dings/chimes](https://opengameart.org/content/bell-dings-chimes) |

> `ui_click.wav` / `ui_hover.wav` 为工程早期自带的界面音效，不在本次引入范围内。

---

## 四、替换素材

框架本身对素材零依赖：**删掉任何一个文件都不会报错**。

- 删掉图片 → 回退到运行时程序化生成的占位图
- 删掉音频 → 静默跳过，不播而已

所以想换成自己的素材，直接按文件名覆盖即可，不需要改任何代码。
