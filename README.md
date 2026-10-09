# Galgame Skeleton

Godot 4 视觉小说（galgame）工程骨架。引擎、系统、演出、存档、工具链全部做完，
**零素材、零配置即可运行**——直接打开工程按 F5 就能走完序章到结局的完整流程。

- 详细设计：[`DESIGN.md`](DESIGN.md)
- 剧本语言规格：[`DESIGN.md` 第四节](DESIGN.md#四剧本语言-gvs-规格)
- 素材来源与授权：[`assets/ATTRIBUTIONS.md`](assets/ATTRIBUTIONS.md)
- 许可证：[MIT](LICENSE)

---

## 快速开始

1. 打开 Godot 4.7+，`导入` → 选择本目录的 `project.godot`
2. 按 `F5` 运行（主场景已设为 `scenes/main.tscn`）
3. 点「开始游戏」

命令行运行：

```bash
godot --path .
```

---

## 操作

| 操作 | 按键 |
|---|---|
| 推进对白 | 鼠标左键 / `空格` / `回车` |
| **回滚一句** | **滚轮向上** |
| **前进一句（撤销回滚）** | **滚轮向下** |
| 回看历史 | `B` 或点 HUD「回看」 |
| 打开设置 | `Esc` |
| 自动播放 | `A` 或点 HUD「自动」 |
| 快速跳过 | 点 HUD「跳过」 |
| 保存 / 读取 | `S` / `L`，或点 HUD 按钮 |
| 隐藏 UI（截图） | `H` |

标题界面另有「继续游戏」（一键读最近存档）和「读取存档」（打开面板挑槽位）。
右上角 HUD 有全部功能的按钮，不记快捷键也能玩。

---

## 玩家便利功能

### 回滚（滚轮翻历史）

**滚轮向上退一句，向下再前进一句。** 退的不只是那行文字，而是「那一句当时的世界」：
背景、立绘、CG、天气、好感度、旗标、剧本变量、选项状态，全部一起还原。

退到选项处，选项面板会重新弹出来，可以直接**改选**。改选之后，原先那条被放弃的支线
不会赖在历史里 —— 再往前翻不会翻进一条其实没走过的分支。

两个实现上的取舍值得知道：

- **快照记在「每一句对白」和「每个选项」上**，不是每帧。内容只是软状态摘要加画面摘要，
  留 100 格也就几十 KB，缓冲区满了自动丢最旧的。
- **还原走的是和读档完全同一条路径** —— 让调度器重新执行那条指令，于是对白 / 选项
  会自己重新出现。不为「回滚」另写一套展示逻辑，两者不会各自漂移。

想换回旧习惯（滚轮上 = 打开回看），在设置里关掉「滚轮用于回滚剧情」即可。

### 跳过已读

**跳过键默认只快进看过的内容，遇到没看过的台词会自动停下来** —— 这是 galgame 的标配行为，
避免误跳过新剧情。

已读记录按**台词内容的 hash** 存，不用「文件 + 行号」：
改剧本、插删行都不会让记录错位（代价是两处一模一样的台词会被当成同一处）。

数据在 `user://read_text.json`，和存档分离 —— 已读是「这台机器上的记忆」，不跟某个存档槽走。

想一路跳到底，在设置里打开「允许跳过未读文本」。

### 已读文本变暗

同一句话重看时压暗显示，一眼看出哪些已经读过。默认关闭，在设置里开「已读文本变暗」。

实现上只改对话框的**默认字色**，不去给文本包一层 `[color]` —— 包起来会跟剧本里
已有的颜色标记和文字特效打架。判重用的是「跳过已读」那套同一份记录，不额外记东西。

### 存档管理（删除 / 覆盖确认）

存档面板每个槽位右侧有「删除」按钮，删除会连缩略图一起清掉。

**写操作都要过一次确认**：覆盖已有存档、删除存档都会先弹一句「确定 / 取消」。
存档是几十小时的进度，误点一下就没了，这是最不该图快的地方。

另外**自动存档槽只能读、不能手动写** —— 它归系统管，手动存进去也会被下一句的
自动存档冲掉，写它只会骗自己。

### 存档缩略图

每个存档槽都会存一张当前画面的截图（384×216）。

缩略图存成**独立 PNG**（`user://saves/slot_01.png`），不塞进存档 JSON ——
这样存档 JSON 保持可读、可手改，也不会因为图片膨胀到几百 KB。删除存档时会一并删掉缩略图。

两个实现细节：

- **抓图前先把存档面板藏起来**，否则拍进去的是面板自己。藏两帧再抓，一帧可能那帧已经把面板画进去了。
- **自动存档的缩略图有 15 秒节流**，因为抓图是 GPU→CPU 回读，每句都抓会明显掉帧。抓之前还会等 0.6 秒 —— 刚切场景时背景还在淡入，立刻抓会是一片黑。

### 隐藏 UI

按 `H` 隐藏全部 UI（对话框、HUD），只留画面。再按一次恢复。用来截图或纯欣赏画面。

### 角色语音静音

设置面板底部按角色列出开关（清单来自 `data/characters.json`，漏登记的角色由
`assets/sprites/` 目录扫描兜底列出）。勾上之后该角色**所有语音都不播**
（包括点名字牌重播），但台词照常显示 —— 不想听某个人说话时很有用。
选择存 `user://config.json`，跨存档、跨周目保留。

### 标题界面 BGM

设置面板的「标题音乐」下拉可以给标题界面挑一首 BGM，**候选只列已解锁的曲目** ——
未解锁的曲子连标题都不该暴露。默认「（不播放）」。改完若正停在标题界面会立刻生效。

---

## 现在能玩到什么

序章 + 第一章，包含：

- 背景切换、立绘显示/隐藏/移动、表情切换（全部带 Tween 过渡）
- 打字机对白、选项分支、条件分支、好感度累计
- **节奏 QTE 小游戏**（指针停在绿色判定区内即命中，5 回合中 3 回合过关）
- 小游戏结果回写剧本变量，并按结果走不同分支
- 跨文件跳转（序章 → 第一章）
- 4 种结局，由累计好感度决定（含序章的一个分支结局）
- 立绘动效（小跳 / 缩放靠近 / 抖动）、全屏震动与闪光、**天气粒子**（雨 / 雪 / 樱花）、背景缓慢运镜
- 存 / 读档（**每句对白自动存档** + 6 个手动槽位）
- **标题界面读档**：「继续游戏」一键回到离开时那一句，「读取存档」打开面板挑槽位
- **CG 鉴赏**：网格浏览，未解锁显示锁图标与 `???`；点击已解锁的 CG 可全屏查看
- **剧情重播**：从 CG 详情页一键跳回该 CG 对应的那段剧情重播，**不会污染当前进度**
- **音乐鉴赏**：曲目列表（当前曲目高亮 + `♪`）+ 可拖拽进度条 + 上一首 / 播放暂停 / 停止 / 下一首 + 播放模式（列表循环 / 单曲循环 / 随机播放 / 顺序播放）
- **视频鉴赏**：与 CG 同款的解锁网格，点击用内置播放器循环播放（素材需 `.ogv`）
- **点击停在停顿处**：台词里的 `[wait]` / `[stop]` 都是停顿点，点击快进到下一个停顿点而不是直接给全文
- **居中旁白**：`narr [center] 文本` 把这一句摆到画面正中（无对话框底板、浅字深描边），
  位置与配色在 `ui_theme.json` 的 `narration` 段
- **子过程参数 + 台词插值**：`call 打招呼 who=alice`，台词里写 `{$who}`；还支持 `{$affection.角色}` / `{$flag.旗标}`
- **演出并行组 `together`**：块内演出同时启动，块结束等最长的那条跑完
- **打字音效**：每 2 个字一声轻响（内置合成音，没有素材也有手感；放 `assets/audio/se/type.ogg` 可替换）
- **对白时压低 BGM**：语音在播时自动把音乐压下去，念完再放回来
- **自动播放等语音**：这一句的语音没念完就不跳下一句
- **音频效果器**：`audio_fx` 指令 + `[fx=…]` 内联标签，给 BGM / 音效 / 语音分别挂故障 / 移调 / 失真 / 混响等效果
- **角色语音静音**：设置里按角色开关，静音后该角色语音不播（台词照常显示）
- **标题界面 BGM**：设置里从**已解锁的曲目**里挑一首当标题音乐
- **界面高度自定义**：配色、字体、按钮尺寸与贴图、对话框位置全在 `data/ui/ui_theme.json`；
  鉴赏界面的列数/卡片/播放器文案在 `data/ui/gallery_theme.json`
- **回滚**：滚轮在历史里前后翻，还原当时的画面与状态，退到选项处可改选
- **多周目**：周目计数、通关记录、`carry` 状态继承，剧本可用 `if cycle >= 2` / `if cleared <结局id>` 写 NG+ 专属内容
- 回看、设置（按「文本 / 音频 / 显示与操作 / 语言与标题 / 角色语音」分组，共 16 项，即时生效并持久化）

---

## 换素材

工程里已经带了一套完整素材（来源与授权见 `assets/ATTRIBUTIONS.md`：美术为 AI 生成，音频为 CC0）。
即便如此，**把 `assets/` 清空也照样能跑** —— 图片缺失时退回**运行时生成的占位图**（按 id 派生色相），
音频缺失时静默跳过。想换成自己的素材，按下面的名字覆盖即可，**代码零改动**：

```
assets/bg/<背景id>.png              1920×1080，如 classroom.png / rooftop.png
assets/cg/<CG id>.png               1920×1080，CG 事件图
assets/sprites/<角色>.png           立绘整图
assets/sprites/<角色>/<表情>.png    立绘差分（优先级更高）
assets/sprites/<角色>/<表情>/       立绘**帧序列目录**（优先级最高，会动）
assets/audio/bgm/<id>.ogg           BGM（也支持 mp3 / wav）
assets/audio/se/<id>.ogg            音效
assets/audio/voice/<id>.ogg         语音
assets/video/<id>.ogv               过场视频（Godot 只认 Ogg Theora）
```

> 帧序列目录里放 `00.png` `01.png` …，文件名里的数字会按**自然顺序**排
> （`frame10` 排在 `frame2` 之后，不是字典序）。可选放一个 `anim.json`：
> `{ "fps": 12, "loop": true }`，不写就是 12fps 循环。目录一存在就自动生效，
> 剧本里不用加任何指令。

音频缺失时会**静默跳过**并只在控制台提示一次，不会中断游戏。

BGM 会自动**循环播放**，不用在导入设置里勾 Loop —— 代码会按流类型把 `loop`
（Ogg / MP3）或 `loop_mode`（WAV）打开。这一点不注意的话，放进真素材会发现
「播完一遍就静音了」。

---

## 改界面（配色 / 字体 / 按钮）

**所有外观集中在 `data/ui/ui_theme.json`** —— 配色、字体、按钮尺寸与贴图、对话框位置全在这一个文件里，改完重启即可，**不用碰代码**。

### 换配色

```json
"palette": {
  "accent": "#7f77dd",
  "text": "#ece9ff",
  "speaker": "#f1c774",
  "bg_deep": "#141221"
}
```

### 换字体

1. 把 `.ttf` / `.otf` / `.woff2` 放进 `assets/fonts/`
2. 在 `data/ui/ui_theme.json` 里填路径：

```json
"fonts": {
  "body":     "res://assets/fonts/main.ttf",
  "title":    "res://assets/fonts/title.ttf",
  "dialogue": "res://assets/fonts/main.ttf"
}
```

| 键 | 管什么 |
|---|---|
| `body` | **界面 / 系统字体** —— 所有 Label、按钮、开关、下拉、回看、存档、设置… |
| `title` | 标题界面的主标题与副标题 |
| `dialogue` | 对话框里的**对白正文**与说话人名牌 |

留空 = 用 Godot 内置默认字体（中文靠引擎的系统字体回退渲染）。
文件不存在会打警告并自动回退，**不会崩**。

字号在同文件的 `font_sizes` 段：`title` / `subtitle` / `heading` / `dialogue` /
`speaker` / `backlog` / `button` / `label` / `small`。

### 换对白的颜色

对白文字色**可以单独配**，不用动全局调色板（`palette.text` 是全界面共用的）：

```json
"dialogue": {
  "text_color":     "#3a2f28",
  "text_dim_color": "#a89a8c"
}
```

留空 = 沿用 `palette.text` / `palette.text_dim`。居中旁白另有自己的
`narration.text_color` / `narration.text_dim_color` / `outline_*`。
说话人名牌的底色是 `palette.name_plate`、字色是 `palette.speaker`。

### 换按钮尺寸

按钮按「预设」管理，共 6 个：`title`（标题界面）、`choice`（选项）、`hud`（右上角）、`track`（曲目）、`default`、`small`。

```json
"buttons": {
  "title": { "width": 340, "height": 68, "font_size": 26, "radius": 10, "pad_h": 24, "pad_v": 12 }
}
```

`width: 0` 表示宽度自适应内容（HUD 按钮就是这么配的）。

### 调「面板外的画面压多暗」

打开设置 / 存档 / 回看时，面板背后那层遮罩的深浅在 `ui_theme.json` 的 `scrim` 段：

```json
"scrim": { "color": "#08070e", "alpha": 0.55, "viewer_alpha": 0.72 }
```

`alpha` 是给小窗面板（设置 / 存档 / 回看）用的 —— 面板外大面积可见，0.55 既能拉开层次又不会把背景压死。
`viewer_alpha` 给近满屏面板（鉴赏 / CG 详情 / 记录）—— 遮罩只露一圈边，压深一点让中间的图更突出。
想更亮就调小，0 是完全不压暗。这些值由 `main.gd` 的 `_apply_scrims()` 统一刷到各面板名为 `Dim` 的节点上，
新增面板只要挂一个叫 `Dim` 的 `ColorRect` 就会被自动接管。

### 加开关（CheckButton）时注意状态色

Godot 默认主题里 `CheckButton` 的 `font_pressed_color` / `font_hover_pressed_color`
是**白色** —— 本项目的面板是浅色纸面，只覆盖 `font_color` 的话，
**开关一打开、文字就变白看不见了**（hover 同理）。所以走统一入口：

```gdscript
UiTheme.apply_check_button(check, UiTheme.TEXT, 20)
```

它会把 `font_color` / `font_hover_color` / `font_pressed_color` /
`font_hover_pressed_color` / `font_focus_color` 五个状态全部覆盖，
禁用态用 `TEXT_DIM`。`tools/smoke.gd` 有一条守卫会**扫真实设置面板里的每个开关**，
发现白色状态就报错。

### 调 CG 详情页的留白

CG 详情页和别的功能窗口一样走面板预设，内边距在 `data/ui/ui_theme.json`
的 `panels.cg_viewer` 段：

```json
"cg_viewer": { "pad_h": 48, "pad_v": 40,
               "texture": "res://assets/ui/ui_cg_viewer_full.png",
               "texture_margin": 0 }
```

历史上这里是代码自己拼 stylebox 的，内边距一度传 0 —— CG 图、标题文字和
重播/关闭按钮全部顶到面板边框上（顺带把面板贴图也挡在了门外）。现在统一走
`UiTheme.apply_panel`。`smoke` 有两条守卫盯着：一条「内边距不能是 0」，
一条「面板样式必须与预设同源」。

### 换面板美术素材（九宫格 / 整图二选一）

按**控件尺寸是否恒定**选机制：

| 机制 | `texture_margin` | 用在哪 |
|---|---|---|
| 九宫格 | > 0（= 切边像素） | 尺寸会浮动的面板：`default`（通用大面板、确认弹层）、`card`（槽位卡片）、调试台 |
| 整图 | 0 | 尺寸恒定的功能窗口：`backlog` / `save_load` / `records` / `gallery` / `cg_viewer` / `settings` |

整图模式下贴图**铺满控件**：圆角、边框粗细、水彩那种不规则边缘全都由画师在
源图里画好，缩放时不会变形，比九宫格自由得多。代价是**贴图像素必须与控件矩形
逐像素相等** —— 差一个像素就被拉伸，而且不报错、不 warning。

这条能成立，靠的是「面板矩形在设计分辨率下是常量」：`canvas_items` + `aspect=keep`
把逻辑画布钉在 1920×1080，1280×720 / 2560×1440 / 1600×1200 三档窗口实测完全一致。

所以：

1. 改 `offset_*` 就等于改了面板尺寸，得重烘焙对应贴图
2. 内边距 `pad_h` / `pad_v` 也会顶高内容的最小尺寸，撑过面板矩形一样会拉伸
   （实测 `save_load` 的内容最小宽度 978px，`pad_h` 给 56 就撑破了 1080）
3. 改完这些数先跑 `tools/panel_probe.tscn` 对账（**要窗口模式**，headless 视口
   只有 64×64 量不准）；`UiTheme.apply_panel` 也会在尺寸对不上时 `push_warning`，
   但那只在该面板被打开时才触发

换主题 = 替换 `assets/ui/ui_<面板>_full.png` 这 6 个文件。`galgame-ui-styles/`
里有 water / sakura / violet / navy / parch 五套按同样尺寸烘焙好的素材。

### 换按钮美术素材（九宫格）

1. 画一张圆角按钮图，四角透明 —— 比如 64×64、圆角 14px
2. 放进 `assets/ui/`
3. 在预设里填路径：

```json
"title": {
  "texture": "res://assets/ui/my_button.png",
  "texture_margin": 14
}
```

`texture_margin` 是九宫格切边（像素），**必须 ≥ 圆角半径**，否则拉伸时圆角会被拉变形。

想给不同状态分别配贴图也可以：

```json
"texture":          "res://assets/ui/btn_normal.png",
"texture_hover":    "res://assets/ui/btn_hover.png",
"texture_pressed":  "res://assets/ui/btn_pressed.png",
"texture_disabled": "res://assets/ui/btn_disabled.png"
```

**只配 `texture` 时**，hover / pressed / disabled 会用同一张贴图加色调区分 —— 够用且省事。

> 仓库里带了一张示例：`assets/ui/button_ninepatch.png`（64×64，切边 14）。把 `"texture"` 指向它就能看到效果。

### 换按钮音效

按钮音效是**自动挂载**的 —— 只要按钮经过 `UiTheme.apply_button()`，点击和悬停就会自动出声，不用逐个连信号。

```json
"audio": {
  "click": "ui_click",
  "hover": "ui_hover",
  "click_volume": 0.7,
  "hover_volume": 0.3
}
```

音效文件放 `assets/audio/se/`，命名对上即可。**留空则不播，文件不存在也静默跳过** —— 删掉素材不会让按钮报错。

想让某类按钮静音，或换用别的音效：

```json
"buttons": {
  "hud":    { "sfx": false },
  "choice": { "sfx_click": "se_confirm" }
}
```

- `"sfx": false` —— 这一类按钮完全静音
- `"sfx_click"` / `"sfx_hover"` —— 单独覆盖某个音效

> 仓库自带两个合成音效 `ui_click.wav`（75ms）和 `ui_hover.wav`（45ms），用 Python 标准库 `wave` 合成，**不是第三方素材，无授权问题**。直接覆盖同名文件就能换成你自己的。

自己搭样式盒、没走 `apply_button` 的按钮（比如曲目列表），手动加一行：

```gdscript
UiTheme.attach_button_sfx(btn, "track")
```

### 按钮位置

位置是布局不是样式，所以不在配置里，改 `scenes/main.tscn`：

- **标题 6 个按钮** → `UILayer/TitleScreen/Center/VBox`
- **HUD 7 个按钮** → `UILayer/HudBar`（锚在右上角）
- **对话框** → 见下方，这个例外

**用 Godot 编辑器打开拖最快。** 手改的话：

```ini
[node name="HudBar" type="HBoxContainer" parent="UILayer"]
anchors_preset = 1        # 锚在右上角
offset_left = -640.0      # 距右边缘（负数向左）
offset_top = 26.0
offset_right = -26.0
```

**对话框例外** —— 它在 `ui_theme.json` 的 `dialogue` 段，运行时由代码应用：

```json
"dialogue": {
  "offset_left": 130, "offset_right": -130,
  "offset_top": -320, "offset_bottom": -70
}
```

### CG 卡片

单独在 `data/ui/gallery_theme.json`：`layout.card_width` / `card_ratio` / `columns` / `grid_spacing`。

### 素材替换一览

| 类型 | 放到哪 | 命名规则 | 支持格式 |
|---|---|---|---|
| 背景 | `assets/bg/` | 剧本里 `bg classroom` → `classroom.png` | png / jpg / jpeg / webp |
| 立绘 | `assets/sprites/` | `<角色id>.png`，或 `<角色id>/<表情>.png`（差分优先） | 同上 |
| CG | `assets/cg/` | `data/collection/cg.json` 里那条的 `id` | 同上 |
| 影片 | `assets/video/` | `data/collection/video.json` 里那条的 `id` | **只认 .ogv（Ogg Theora）** |
| BGM | `assets/audio/bgm/` | 剧本里 `bgm daily` → `daily.ogg` | ogg / mp3 / wav |
| 音效 | `assets/audio/se/` | 剧本里 `se bell` → `bell.ogg` | 同上 |
| 语音 | `assets/audio/voice/<角色>/` | `voice <角色>/<台词>` → `<角色>/<台词>.ogg` | 同上 |

**找不到就退回程序化占位图（背景/立绘/CG）或静默跳过（音频/影片），代码零改动。**

> 背景 / 立绘 / CG 的 id 都来自剧本和注册表 —— 换素材时只要文件名对上，不用动任何代码。

---

## 鉴赏 / 收藏

### 加一张 CG

1. `data/collection/cg.json` 的 `items` 里加一条：

   ```json
   {
     "id": "cg_rooftop",
     "title": "天台·黄昏",
     "hint": "序章 · 放学后",
     "image": "res://assets/cg/cg_rooftop.png",
     "replay": {
       "file": "res://data/scripts/prologue.gvs",
       "label": "cg_rooftop",
       "end_label": "cg_rooftop_end"
     }
   }
   ```

2. 剧本里写 `cg cg_rooftop` —— 展示的同时自动解锁
3. 想让这张 CG 可重播：在剧本里用成对标签把那段剧情包起来

   ```gvs
   label cg_rooftop
   bg rooftop fade=1.0
   cg cg_rooftop fade=0.9
   narr 放学后，天台。夕阳把栏杆的影子拉得很长。
   label cg_rooftop_end
   hide_cg fade=0.6
   ```

界面会自动多出一格，不用动任何 UI 代码。

### 加一首曲子

`data/collection/music.json` 加一条（`id` 要和 `assets/audio/bgm/<id>.ogg` 的文件名一致），
剧本里 `bgm <id>` 播放时自动解锁。

### 加一段影片

鉴赏面板的第三个页签。和 CG 同一套做法：

1. `data/collection/video.json` 加一条（`id` 要和 `assets/video/<id>.ogv` 的文件名一致）：

   ```json
   { "id": "op_movie", "title": "片头动画", "hint": "序章 · 开场", "image": "" }
   ```

2. 剧本里写 `video op_movie` —— 播放的同时自动解锁
3. 影片必须转成 **Ogg Theora（`.ogv`）**（Godot 不内置 H.264/H.265，也不支持带 alpha 的视频）

点了卡片会用内置播放器循环播放（`16:9` 等比，不变形）；素材缺失时提示行直接写
「该视频素材缺失」，不会黑屏。

### 换外观

改 `data/ui/gallery_theme.json` 就行，**不用碰代码**：

```json
{
  "palette": { "accent": "#e0603c" },
  "layout":  { "columns": 4, "card_width": 300 },
  "text":    { "locked_label": "？？？", "replay_button": "重温这一幕",
               "mode_list_loop": "列表循环", "stop_button": "停止" }
}
```

可以只写关心的键，其余自动用默认值。音乐播放器的按钮文案都在 `text` 段
（`play_button` / `pause_button` / `stop_button` / `mode_*` / `now_playing` …），
改字符串不用动代码。

---

## 多周目（NG+）

打通一个结局之后再点「开始游戏」，就进入第 2 周目。周目数会显示在标题界面
（一周目且没通关过时整行隐藏，不提前剧透），记录面板里也有完整的「多周目」板块。

### 剧本里怎么用

**按周目分岔** —— 任何 `if` 里都能用：

```gvs
if cycle >= 2                       # 比较符：== != > < >= <=
    narr （——又是四月。这一次，我大概知道该说什么了。）
end

if cleared true_end                 # 某个结局通关过没有（跨周目记录）
    alice@smile: ……奇怪，这句话，我好像对你说过第二遍。
end

if not cleared bad                  # 反向写法
    ...
end
```

**按结局 id 分岔** 的 id 必须登记在 `data/collection/endings.json` 里 ——
写错 id 时那段 NG+ 内容永远不会出现，而且不报错，所以静态校验会把它当提醒报出来
（跑 `res://tools/audit.tscn` 能看到）。

**继承上一周目的状态** —— 在剧本里标记要带过去的东西：

```gvs
carry affection alice     # 这个角色的好感度继承到下一周目
carry flag  saw_true_end  # 这个旗标继承
carry var   player_name   # 这个变量继承
```

`carry` 只是**打标记**，取值发生在抵达结局的那一刻 —— 也就是说继承的永远是
「这一周目结束时」的值，所以把它写在剧本哪一行都不影响结果。
下一周目开局时这些值会被自动写回 `GameManager`，于是「带着上一周目的好感度重来」
这种经典 NG+ 设计只要一行 `carry` 就够了（本工程的 `chapter1.gvs` 就是这么写的）。

没有 `carry` 标记的东西一律**不继承** —— 新周目是一张干净的白纸，
旗标 / 变量 / 好感度全部清零。

### 什么会跨周目保留，什么会重置

| | 说明 |
|---|---|
| **会保留** | CG / 音乐 / 结局收藏（`user://collection.json`）、已读记录（`user://read_text.json`）、路线图与章节解锁（`user://route.json`）、通关次数与 `carry` 继承数据（`user://cycle.json`） |
| **会重置** | 旗标、变量、好感度、游玩时长 —— 每次开新游戏都从零开始，除非用 `carry` 显式标记 |
| **存进存档** | 只有「当前是第几周目」。所以读一份一周目的旧档会退回一周目的分支，但通关记录不会被抹掉 |

> 想看继承效果：通关一次 → 回标题（会显示「第 2 周目」）→ 开始游戏 →
> 按 `~` 打开调试台敲 `aff alice`，好感度直接就是上一周目的终值。

### 调试台

`cycle` 看当前周目与全部通关记录，`cycle 3` 直接拨到第 3 周目，`cycle reset` 清空周目记录。

---

## 换界面语言

界面文案全部集中在 `data/i18n/`，**加一门语言只要丢一个 JSON 进去**，代码零改动：

```
data/i18n/en.json     英文
data/i18n/ja.json     日文（照抄 en.json 的格式再翻一遍即可）
```

游戏里在「设置」面板最下方选语言，**即时生效，不用重启**。

### 它怎么工作的

- **key 就是中文原文**。中文是源语言，不需要自己的表；其它语言只写差异。
  好处是新写的文案不用登记 key 就能显示，**缺条目只影响那一句，不会把界面显示成 `menu.start`**。
- 界面上的静态文字（写在 `main.tscn` 里的按钮、标签）由 `I18n.apply_tree()` 遍历替换，
  **原文存在节点的元数据里**，所以切成英文再切回中文也能正确还原 ——
  拿已翻好的英文去查表查不到，就会永久卡在英文上，这是这类实现最常见的翻车点。
- 代码拼出来的文字（「存档 3」「已读 12 / 89 句」）在各自的生成处显式调 `I18n.t()`，
  参数用 `{name}` 占位：`I18n.t("存档 {n}", {"n": 3})`。

### 什么不翻译

**CG 标题、曲目名、对白、章节名属于「内容」，不走界面翻译表** —— 它们是剧本的一部分，
硬翻成 key 查表只会把台词也当成界面文案。

内容的多语言走**独立的剧本目录**：

```
data/scripts/prologue.gvs          源语言（中文），逻辑路径
data/scripts/en/prologue.gvs       英文版，同名即可
data/scripts/en/chapter1.gvs
data/scripts/en/chapters.json      可选，语言目录里有就用这份
```

不用改任何代码、也不用改 `jump_file` 或 `chapters.json` 里的路径 ——
路径解析统一在 `ScriptPaths`：**对外一律是逻辑路径**（`res://data/scripts/xxx.gvs`），
真正读文件时才映射到当前语言目录。

两条容错规则值得知道：

- **缺哪个文件就回退哪个** —— 英文只翻了一半也能玩，没译的那几段回退中文，不会报错。
- **存档里记的是逻辑路径**，所以换语言读旧档不会对不上剧本。

`CG 标题 / 曲名 / 章节标题` 这些来自 JSON 的内容仍是单语言，要跟随语言就各自准备一份
JSON（`data/collection/`、`Chapters.json`）。

---

## 改剧本

剧本在 `data/scripts/`，是纯文本，用任意编辑器都能改。语法示例：

```gvs
label start
chapter 序章 · 新学期

bg classroom fade=0.8
bgm daily volume=0.7

show alice expr=normal at=left fade=0.5
alice: 早上好。
alice@smile: 又是游戏。

choice
    "「游戏也是艺术。」" -> defend_games
    "「……我错了。」"    -> admit_fault
end

label defend_games
affection alice 5
minigame rhythm_qte rounds=5 need=3
if flag rhythm_qte_cleared
    alice@smile: 不错嘛。
end
ending good "并肩的归途"
```

改完直接重新运行即可，不需要任何编译步骤。完整指令表见 `GVS-剧本语法手册.md`。

### 子过程参数与台词插值

`call` 可以带参数，台词里用 `{$…}` 取值：

```gvs
call 打招呼 who=alice          # 具名参数（也可以用位置参数：call 打招呼 alice）
narr 你好，{$who}。
alice: 我的好感度是 {$affection.alice}。
ending true_end "给 {$who} 的答案"

label 打招呼
alice: 你好，{$who}。
return
```

- 参数**作用域是局部的**（随调用帧压栈、`return` 弹掉），嵌套调用不会串味。
- 可用的取值：`{$名字}`（call 参数 → 剧本变量）、`{$1}`（位置参数）、
  `{$affection.角色id}`、`{$flag.旗标名}`。
- **查不到时原样保留 `{$名字}`**，不变成空串 —— 名字写错时一眼能看见；
  `tools/audit` 也会把「没人写过的插值名」报成 warning。
- 变量名可以是中文；整数不会显示成 `3.0`。

### 演出并行组 `together`

```gvs
together
    bg rooftop type=dissolve fade=1.2
    show alice transition=slide_left fade=1.0
    bgm sunset fade=1.5
end
narr 转场结束后才出现的旁白。
```

块内指令同时启动，块结束**等最长的那条**跑完（上例 1.5 秒）——
不用再手写一个「跟着 duration 一起改」的 `wait`。
`duration=` 可以覆盖等待时长（`duration=0` = 只启动不等）。
块内只允许非阻塞的演出 / 音频指令，写 `narr` / `wait` / `jump` 是解析期错误。

---

## 文字特效与打字节奏

特效标记**直接写在剧本台词里**，不需要任何额外语法 —— 写文案时顺手打出来就行：

```gvs
alice@angry: [shake rate=14 level=5]你们两个！[/shake]
narr [bounce height=13]弹跳[/bounce] · [blink]闪烁[/blink] · [glitch strength=5]错乱[/glitch] · [rainbow]变色[/rainbow]
alice: 这一句[speed=3]三倍速冲过去[/speed]，然后[wait=0.9]停顿一下，再恢复正常速度。
```

### 可用特效

| 标记 | 效果 | 常用参数 |
|---|---|---|
| `[shake]` | 抖动 | `rate` `level` |
| `[wave]` | 波浪 | `rate` `level` |
| `[rainbow]` | 彩虹变色 | `freq` `sat` `val` |
| `[pulse]` | 脉冲变色 | `freq` `color` |
| `[fade]` | 淡入淡出 | `speed` `min_alpha` |
| `[tornado]` | 旋风 | `radius` `freq` |
| `[flip]` | 翻转 | `h` `v` |
| **`[bounce]`** | 弹跳 | `speed` `height` |
| **`[glitch]`** | 错乱 / 故障 | `rate` `strength` `tint` |
| **`[blink]`** | 闪烁 | `speed` `min_alpha` |
| `[color=#ff0000]` | 固定颜色 | — |
| `[bgcolor=#333333]` | 背景色 | — |

前 7 个是 **Godot 内置**的，直接可用；后 3 个（加粗）是项目自定义的，源码在 `scripts/ui/text_effects/`。

想加新特效：继承 `RichTextEffect`，写一个 `_process_custom_fx()`，然后把它加进 `dialogue_box.gd` 的 `custom_effects` 数组。

### 打字节奏

| 标记 | 作用 |
|---|---|
| `[wait=0.5]` | 在此处停顿 0.5 秒后**自动**继续 |
| `[pause=0.3]` | 同上（别名） |
| `[speed=3]...[/speed]` | 这一段按 3 倍速逐字显示 |
| `[stop]` | 在此处**停下等点击**，点了才接着显示（别名 `[click]`） |
| `[fx=glitch]` | 在此处触发一次音频效果器，见「音频效果器」一节 |
| `[center]` | 这一句摆到**画面正中**显示（居中旁白），见下 |

基准速度是玩家设置里的「文字速度」（默认 45 字/秒），`[speed=N]` 是相对它的倍数。

**节奏标记不占可见字符**，和特效标记能混用且对齐正确。单字等待有 0.35 秒上限 —— 写 `[speed=0.001]` 也不会把节奏拖死。

底层实现：`TypingTimeline` 把带标记的文本预编译成「每个可见字符在第几秒出现」的时间轴，播放时二分查表。所以停顿、变速、跳过、暂停都不会让进度错乱。

**点击时停在停顿处**：玩家点击**不会**一下子显示全文，而是快进到**下一个停顿点**
（`[wait]` 或 `[stop]`），后面没有停顿点了才补完整句。想回到「一点就显示全文」的老手感，
在设置里关掉「点击先跳到下一个停顿」。跳过 / 自动播放仍是一次给全。

```gvs
alice: 那个……[stop]（点了才继续）
alice: 这……这不可能[fx=glitch bus=voice]！
```

**标记只会留在对话框里**。回看面板和存档预览显示的是剥掉标记之后的文本 ——
不剥的话，那两处会直接出现 `[wait=0.7]`、`[stop]`、`[fx=glitch]` 这样的字样。

### 居中旁白

```gvs
narr [center]（——又是四月。这一次，我大概知道该说什么了。）
```

这一句摆到画面正中：**不画对话框底板**，文字直接压在画面上，浅色字 + 深色描边
（字幕的做法，浅背景靠描边、深背景靠字本身，两边都看得清）。
打字机、停顿点、`[fx=…]` 全都照常工作。

**编辑器里不用手写标记**：剧本块的对白行有一个「版式」下拉（旁白和角色台词都有），
选「居中」就把 `[center]` 写进台词、选「默认」就去掉。

位置 / 内边距 / 字色 / 描边都在 `data/ui/ui_theme.json` 的 `narration` 段 ——
它和 `dialogue` 段分开，因为旁白的 offset 相对**全屏**锚点、对话框相对**底边**锚点，
混在一起会让「改旁白的边距」连带把对话框也挪了。

---

## 立绘与画面动效

### 立绘

```gvs
hop alice height=46 times=2 duration=0.8        # 兴奋小跳
zoom alice 1.25 duration=0.5                    # 靠近（放大）
zoom alice 1.0 duration=0.35                    # 退回
shake alice strength=14 times=5 duration=0.5    # 抖动
move alice center duration=0.8 ease=out_cubic   # 带缓动的位移
```

| 指令 | 作用 | 参数 |
|---|---|---|
| `hop <角色>` | 小跳跃 | `height` `times` `duration` |
| `zoom <角色> <倍数>` | 靠近 / 远离 | `duration` `ease` |
| `shake <角色>` | 抖动 | `strength`（默认 28） `times` `duration` |
| `move <角色> <位置>` | 位移 | `duration` `ease` |

> 跳跃用 `hop` 而不是 `jump` —— `jump` 已经被标签跳转占用了。

**`move` 的两条语义**（踩过坑，值得先读）：

- **只移动已经在台上的立绘** —— 它不会让还没出场的角色出现。可重播片段里要自带 `show`。
- **移到槽位 = 横向移动**。槽位表里只有横向比率（`left` / `center` / `right` /
  `off_left` / `off_right`），所以 `move alice right` 只改 X，**Y 保持原样** ——
  你用 `y=1600` 把立绘放低了，横着移过去时不会突然跳回默认底线。想连纵向一起复位就写 `y=`。
  这条也意味着**坐标不会挡住槽位**：`show alice x=460 y=1600` 之后 `move alice right`
  会真的横移过去。

**入场 / 出场方式**用 `type=` 指定：

```gvs
show alice at=left type=slide_left fade=0.6     # 从屏幕左侧滑入
show bob at=right type=slide_right fade=0.6     # 从屏幕右侧滑入
show carol at=center type=slide_up fade=0.5     # 从画面下方滑入
hide alice type=slide_right fade=0.5            # 朝右侧滑出
```

| `type` | 效果 |
|---|---|
| `fade` | 淡入淡出（默认） |
| `slide_left` | 从屏幕左侧外滑入 |
| `slide_right` | 从屏幕右侧外滑入 |
| `slide_up` | 从画面下方滑入 |
| `none` | 直接出现 / 消失 |

滑入时 **alpha 直接给满**，不边滑边淡入 —— 那样显得拖泥带水，而且起点在屏幕外，玩家本来就看不到「突然出现」。

两个实现细节值得知道：

- **缩放以脚底为中心**，所以放大时脚不动、往上长，这才是「靠近」的感觉。pivot 放在左上角的话，放大会整体往右下漂。
- **跳跃的上升段用减速、下落段用加速** —— 这是抛物线的物理感，两段都用 linear 会像坐电梯。
- **动效被打断后会从基准位重新开始**，不会从半空续跳。

### 站位：精确到像素

`at=` 那五个槽位不够用时，可以直接写坐标：

```gvs
show alice expr=smile x=680 y=1130 scale=0.9 fade=0.5
show bob   at=right y=1080 scale=1.1              # 只覆盖 y 与大小，X 仍走预设
move alice x=960 y=1130 duration=0.6 ease=out_cubic
move bob   at=right                               # 槽位 → 横移，Y 不动
move bob   at=right y=1130                        # 槽位 + 纵向一起复位
```

| 参数 | 含义 |
|---|---|
| `x` | 立绘**框中心**的设计像素 X（1920×1080 画布） |
| `y` | 立绘**脚底**的设计像素 Y —— 调小 = 人往上站（显高、显远），调大 = 往下 |
| `scale` | **基准缩放**（这个角色本来就多大），与 `zoom` 的动画倍率相乘 |

三个都是可选的：不写就回到 `at=` 预设与默认底线（脚底 1130），**旧剧本完全不受影响**。
`show` 里没写的轴会回到默认，而不是沿用上一次 —— 所以 `show alice x=500` 之后
再 `show alice at=left`，位置是干净的预设位。

两个要点：

- **坐标基于 1920×1080 设计分辨率**，不是窗口像素。多分辨率由引擎的 `canvas_items`
  拉伸统一处理，所以写死的数字在任何窗口尺寸下都对。
- **`scale` 与 `zoom` 是两回事**：`scale` 是角色设定（进存档，读档后保持）；
  `zoom` 是临时的「凑近一点」（换场景自动复位）。0.5 的基准上再 `zoom 2.0`，屏幕上就是 1.0。

调坐标不用靠猜 —— 跑一次网格预览工具，出图上有 100px 网格与坐标刻度：

```bash
godot --path . res://tools/stage_grid.tscn
```

输出在 `%APPDATA%/Godot/app_userdata/Galgame Skeleton/captures/stage_grid.png`，
图上带预设锚点线（left 422 / center 960 / right 1498）、默认脚底线 `y=1130` 与立绘框参考，
控制台还会把样本立绘的实测坐标打出来对账。

### 多立绘协同

同框时**说话的人亮着、其他人自动压暗** —— 不用在剧本里手写，每次对白自动生效。

```gvs
show alice at=left
show bob at=right
alice: 我说话的时候，bob 会被压暗。
bob: 轮到我说话，就换我亮着。
narr 旁白时两个人都恢复明亮。
```

压暗程度在 `data/ui/ui_theme.json` 的 `stage` 段：

```json
"stage": { "dim_inactive": 0.55, "dim_duration": 0.22 }
```

只改 `modulate` 的 rgb，**不动 alpha** —— alpha 归淡入淡出管，两者不能互相踩。

### 动态立绘（帧序列动画）

把立绘的表情换成**帧序列目录**，它就自己动起来了 —— 剧本里不用加任何指令：

```
assets/sprites/alice/blink/00.png      # 睁眼
assets/sprites/alice/blink/01.png      # 闭眼
assets/sprites/alice/blink/anim.json   # 可选：{"fps": 12, "loop": true}
```

```gvs
show alice expr=blink fade=0.4     # 直接用，自动会动
```

`anim` 指令用来控制播放：

```gvs
anim alice speed=0.5        # 慢放
anim alice pause=true       # 定格在当前帧
anim alice once             # 只播一遍，停在最后一帧
anim alice frame=3          # 跳到第 3 帧（0 基）
anim alice                  # 恢复常速循环
```

| 指令 | 作用 | 参数 |
|---|---|---|
| `anim <角色>` | 控制帧序列动画 | `speed` `pause` `once` `frame` |

几点说明：

- **Godot 内置没有动图解码器**：GIF 完全不认，APNG 只取第一帧，动画 WebP 连第一帧都解不出来。
  所以「动态图片」的唯一可靠路线就是帧序列（实测见 `tools/anim_probe.tscn`）。
- **带透明通道完全没问题** —— 序列帧就是普通 PNG/WebP，alpha 原样保留。
- 帧数上限 **256**（`AnimatedTexture` 的限制），超过会只取前 256 帧并打警告。
- 立绘节点用的还是 `TextureRect`，`AnimatedTexture` 本身就是 `Texture2D` ——
  所以压暗、位移、缩放、**表情交叉混合**全都不受影响（实测见 `tools/media_verify.tscn`）。
- 在静态立绘上写 `anim` 是安全的：返回 false、不报错、画面不受影响。

### 过场视频

```gvs
video op                                    # 全屏播放，不阻塞，播完自动收起
video op wait=true                          # 播完再继续剧情
video op at=320,180 size=640,360            # 指定位置与尺寸
video op layer=ui                           # 压在 UI 之上
video op loop=true volume=0.5 fade=0.4      # 循环 / 音量 / 淡入
hide_video fade=0.3                         # 淡出收掉
```

| 指令 | 作用 | 参数 |
|---|---|---|
| `video <id>` | 播放视频 | `at` `size` `layer` `fade` `volume` `speed` `buffer` `loop` `wait` `hide` |
| `hide_video` | 淡出收掉 | `fade` |

| 参数 | 取值 |
|---|---|
| `at` | `full`（默认，铺满整屏）/ `center`（按 size 居中）/ `x,y`（左上角坐标） |
| `layer` | `world`（默认，在对话框之下）/ `ui`（盖住对话框与 HUD）/ `top`（最上层，连全屏特效一起压住） |
| `wait` | `true` 时调度器会停在这里等播完（也可以点一下跳过） |
| `buffer` | 起播前缓冲多少毫秒，默认 **120**（Godot 默认 500ms，实测那 0.5 秒里画面是空的 —— 过场会「先黑一下」） |

**素材必须是 Ogg Theora（`.ogv`）** —— Godot 内置只认这一种，没有 H.264/H.265
（授权原因），也不支持 WebM。转换用 ffmpeg 或 HandBrake：

```bash
ffmpeg -i input.mp4 -c:v libtheora -q:v 7 -c:a libvorbis -q:a 5 output.ogv
```

**带 alpha 的视频内置不支持**（Theora 是 YUV 4:2:0，没有 alpha 平面）。
需要透明视频请走上面的帧序列动画；或者引入支持 WebM/VP9-alpha 的 GDExtension。

另外两点：

- 视频会被**拉伸到给定矩形**。设计分辨率是 1920×1080（16:9），视频也基本都是 16:9，
  所以默认全屏不会变形；要放非 16:9 的视频，让 `size=` 与视频宽高比一致。
- 素材缺失时**不会卡死**：会打一条 warning，`wait=true` 也照样放行
  （实测见 `tools/media_verify.tscn`）。

**真机验证过的行为**（`tools/video_verify.tscn`，用 ffmpeg 生成的测试 `.ogv`）：

| 验的是 | 结果 |
|---|---|
| 画面在推进 | 白条位置每 0.4s 前进 192 设计像素 = 480px/s，与素材（80 源像素/s × 6 倍缩放）**精确吻合** |
| 指定位置 / 尺寸 | 播放器矩形 `(320,180) 640×360`，矩形内是视频、矩形外仍是背景 |
| **有没有 alpha** | 视频区实测 `(0,255,2)`、背景洋红 `(255,0,255)` —— **没有一丝背景混入**，Theora 确实不透 |
| 播完 | `finished` 发出、视频自动收起（`is_playing=false` / `visible=false`） |
| `wait=true` | 进 `waiting_video`，播完自动放行到下一条对白 |

### 转场

背景和 CG 都支持四种转场，用 `type=` 指定：

```gvs
bg rooftop type=dissolve fade=0.9    # 溶解
bg classroom type=wipe fade=0.8      # 横向擦除
bg rooftop type=blinds fade=0.9      # 百叶窗
bg classroom type=circle fade=0.9    # 从中心圆形扩散
cg cg_classroom type=wipe fade=0.7
hide_cg type=blinds fade=0.5         # 退场时遮罩反向走一遍
```

| `type` | 效果 |
|---|---|
| `fade` | 交叉淡入（默认） |
| `dissolve` | 按噪声阈值逐块显现 |
| `wipe` | 从左到右扫过 |
| `blinds` | 每条叶片从下往上展开 |
| `circle` | 从画面中心扩散 |
| `none` | 直接切换 |

实现是 `shaders/transition.gdshader` —— 把 `progress` 从 0 推到 1，上层图按不同图案显现。想加新转场就在 shader 里加一个 `mode` 分支。

### 画面

```gvs
screen_shake strength=48 times=6 duration=0.6   # 全屏震动（吓一跳）
screen_flash color=#ffffff duration=0.35        # 全屏闪光
```

**震动会同时震舞台和 UI 层** —— 背景 / 立绘 / CG / 对话框 / HUD 一起抖。

这一点很关键：**只震舞台是看不出来的**。背景是铺满画面的渐变，整体平移没有参照物，实测峰值只有画布宽的 0.74%，玩家根本察觉不到。加上 UI 一起抖（对话框明显位移）才真的「吓一跳」。

幅度参考（按 1920×1080 设计分辨率）：

| 效果 | 默认 | 明显可见 |
|---|---|---|
| `screen_shake` | 36 | 45~60 |
| `char_shake` | 28 | 35~45 |

抖动偏移用**极坐标**生成而不是各轴独立随机 —— 后者经常抽出接近零的向量（两个分量恰好都很小），看起来就像根本没动。

### 全屏特效

```gvs
screen_fx glitch                               # 错乱：横条撕裂 + RGB 分离 + 扫描线
screen_fx glitch strength=1.6 duration=0.35    # 更猛、更短促
screen_fx wave duration=2.0                    # 波纹扭曲
screen_fx swirl strength=0.8 duration=0        # 漩涡，持续到手动关闭
screen_fx none                                 # 关闭
```

| 种类 | 效果 |
|---|---|
| `glitch` | 错乱：随机横条撕裂 + RGB 分离 + 扫描线 |
| `wave` | 波纹扭曲（横竖两路正弦，相位不同） |
| `swirl` | 漩涡，越靠中心转得越多 |
| `pixelate` | 马赛克 |
| `chromatic` | 色差（红蓝往两边拉开） |
| `invert` | 反色 / 底片 |
| `blur` | 模糊 |
| `none` | 关闭 |

**参数**

- `strength`：默认 `1`。建议 `0.5 ~ 1.5`；`2` 以上基本就是在看花屏。
- `duration`：默认 `0.8` 秒。这时是**脉冲** —— 快速冲到峰值，再在剩余时长里收回 0。
  **写 `0` 就是持续**，一直挂到 `screen_fx none`、下一条 `screen_fx`、或读档 / 回标题。

强度参考（按 1920×1080 估，`strength=1` 时）：

| 种类 | 观感 |
|---|---|
| `glitch` | 约 14% 的横条被撕开，最大横移 60px 上下 |
| `wave` | 波纹振幅约 42px |
| `swirl` | 画面中心旋转约 50°，边缘几乎不动 |
| `pixelate` | 色块约 58px |
| `blur` | 半径约 19px |

**「全屏」是字面意思**：这一层排在对话框和 HUD **之上**，所以它们会跟着一起变形 ——
要的是「整个世界不对劲」，而不是只有背景不对劲。只糊背景的话，UI 会像贴纸一样
浮在扭曲的画面外面，一眼假。

代价是面板也会被糊掉，所以**任何模态面板（设置 / 存档 / 回看 / 鉴赏 / 记录 / 标题）
一打开，特效就自动收起来**；关掉后原样接着演，长镜头不会被打断。

底层是 `shaders/screen_fx.gdshader`：一个铺满屏幕的 `ColorRect`，前面紧挨着
一个 `BackBufferCopy` 把已经画好的整屏 copy 进 back buffer，shader 再用
`hint_screen_texture` 读它、变形、写回去。想加新种类就到 shader 里补一个
`mode` 分支，并把名字追加进 `ScreenFxSpec.KINDS`（顺序即 `mode` 值）。

### 天气与运镜

```gvs
weather snow intensity=1.0      # 下雪（也支持 rain / sakura，none 关闭）
bg_motion scale=1.10 y=-14 duration=8.0 ease=in_out_cubic   # 镜头极缓慢推近
bg_motion scale=1.0 duration=2.0                            # 收回
```

天气是 GPU 粒子 + 程序化生成的贴图，**不需要任何素材文件**。运镜作用在包住两层背景的容器上 ——
转场时两层正在交叉，只动其中一层会露馅。

### 动态立绘与过场视频

见前面「改素材 → 帧序列目录」与「演出 → 动态立绘 / 过场视频」两节。要点：
**帧序列目录一存在就自动生效**（立绘会动，剧本不用改）；**视频必须是 `.ogv`**，
且可以用 `layer=` 精确控制压在 UI 之下还是之上。

### 语音

```gvs
voice alice_001          # 写在台词「前面」，会被认领成这一句的语音
alice: 早上好。
```

播完之后**点对话框上的名字牌可以重播**这一句。文件放
`assets/audio/voice/<角色>/<台词>.ogg`（**两级目录**，id 就是 `<角色>/<台词>`），
没有素材时静默跳过，不会报错。

同一句里连写多条 `voice`，会**依次排队播完**（不会后一条把前一条掐掉）：

```gvs
voice alice/line01
voice alice/line02
alice: 两句配音连在一起。
```

但如果玩家**推进到下一句**，上一条语音会立刻中断、队列也一并清空 ——
让旧语音拖到新台词上会声画错位，玩家听到的是上一句、看到的却是新的一句。

**角色语音静音**：设置面板底部按角色列出开关（清单来自 `data/characters.json`，
漏登记的角色会由 `assets/sprites/` 目录扫描兜底列出）。勾上之后该角色所有语音都不播
（包括点名字牌重播），但台词照常显示。选择存 `user://config.json`，跨存档、跨周目保留。

### 音频效果器

给 **BGM / 音效 / 语音三条音轨分别**挂效果器 —— 三条是独立总线，
所以「让音乐出故障」不会把语音一起弄坏。

```gvs
bgm tension
audio_fx bgm glitch duration=2.0          # 在某处挂
alice: 屏幕上跳出一行乱码……
audio_fx bgm off                          # 显式清除
alice: 这……这不可能[fx=glitch bus=voice]！  # 或在文字显示的中间触发
```

| 音轨 | 说明 |
|---|---|
| `bgm` / `se` / `voice` | 分别作用于背景音乐 / 音效 / 语音 |
| `all` | 三条一起 |
| `master` | 总输出（会带上 UI 音效，慎用） |

| 效果 | 听感 | 用得到的参数 |
|---|---|---|
| `glitch` | 数字故障、断续跳变 | 时长 · 强度 |
| `error` | 损坏 / 错误音 | 时长 · 强度 |
| `distortion` | 过载失真 | 时长 · 强度 |
| `pitch` | 移调（`pitch=` >1 变尖、<1 变沉） | 时长 · 移调 |
| `muffle` / `underwater` | 闷住 / 水下 | 时长 · 强度 |
| `radio` | 无线电、对讲机 | 时长 · 强度 |
| `echo` / `reverb` | 回声 / 混响 | 时长 · 强度 |
| `amplify` | 增益强调 | 时长 · 强度 |
| `none` / `off` / `clear` | 清除该音轨上挂的效果 | — |

**三个参数不是每个效果都用得到** —— 上表「用得到的参数」列就是运行时真正会读的那些，
编辑器也只显示这些（选了 `muffle` 就不会出现「移调」那种写了也没用的框）。
`strength=1.0` 是基准值，越大效果越深。

- `duration=0` 表示持续到显式清除；不写默认 0.8 秒后自动清除。
- 同一音轨上效果器**互斥**（新的一次先清上一次），链不会越挂越长。
- 音轨名 / 效果名拼错是**解析期错误**（`tools/audit` 会让 CI 非零退出），不会静默无声。
- 内联 `[fx=…]` 的参数：`bus=`（默认 `bgm`）、`dur=`（默认 0.6）、`strength=`、`pitch=`。
- 回标题 / 读档会清掉全部效果器，不会把「故障」带到下一幕。

### 打字音与压低音乐

两个「开箱就有手感」的音频细节，都在设置 → 音频里开关：

- **打字音效**：每显示 2 个字响一声轻响。没有素材时用**内置合成的点击音**
  （28ms 的衰减噪声），所以骨架阶段也能听到；想换就放
  `assets/audio/se/type.ogg`（优先级高于合成音）。
- **对白时压低音乐**：语音播放时把 BGM 压 12 dB，念完再放回来。
  压的是 BGM **总线**音量，与切歌淡入淡出走的是两条互不干扰的路
  （否则两者会互相覆盖，表现为「淡入到一半突然跳回原音量」）。

另外「文本」分组里的**自动播放等语音念完**：这一句的语音还没播完时，
自动播放会先等它，不会在半句话上跳走。

### 缓动

位移类动效都支持 `ease=`，**默认 `out_cubic`（减速收尾），不是线性** —— 线性位移看起来像电梯。

| 值 | 感觉 |
|---|---|
| `linear` | 匀速（不推荐） |
| `in_quad` / `in_cubic` / `in_quart` | 越走越快（溜走、冲刺） |
| `out_quad` / `out_cubic` / `out_quart` | 越走越慢（默认，自然收尾） |
| `in_out_cubic` | 两头慢、中间快 |
| `out_back` | 冲过头再回弹（弹入） |
| `out_elastic` | 弹性振荡 |
| `out_bounce` | 落地弹跳 |

```gvs
move alice right duration=1.0 ease=in_cubic   # 带着加速度溜走
zoom alice 1.3 duration=0.5 ease=out_back     # 弹一下放大
```

> 十六进制颜色里的 `#` 不会被当成注释 —— 解析器只在行首或空格后才把 `#` 当注释。

---

## 加一个小游戏

1. 新建场景，根节点挂一个继承 `MinigameBase` 的脚本
2. 实现 `_on_setup()` / `_on_start()`，结束时调用 `finish({"success": true, "score": 5, "max": 5})`
3. 在 `scripts/core/minigame_registry.gd` 的 `REGISTRY` 里加一行：
   ```gdscript
   "my_game": "res://scenes/minigames/my_game.tscn",
   ```
4. 剧本里写 `minigame my_game 参数=值`

主流程一行都不用改。

---

## 开发者工具

### 剧本静态校验

```bash
godot --headless --path . res://tools/audit.tscn
```

一次扫出：解析错误、悬空跳转、**重复结局 id**、未登记结局、空台词、空选项块、未使用标签。
**有错误时退出码为 1**，可以直接挂到 CI 上当门禁。

顺带列出剧本引用的全部素材 id，标出哪些还没有真实文件（缺素材会退回程序化占位图，不影响运行）。

> 写这类静态检查工具时，**先把「所有合法的引用来源」列全** ——
> 选项的 `-> label`、`cg.json` 的 `replay` 起止标签、`chapters.json` 的入口标签，
> 少算一个就会误报一片「死代码」，把真问题淹掉。

### 调试控制台

游戏内按 **`~`** 开关（只在 debug 构建里创建，导出版不带）。

| 命令 | 作用 |
|---|---|
| `jump <标签>` | 跳到当前剧本的任意标签 |
| `goto <文件> <标签>` | 换个剧本文件并跳转 |
| `flag` / `var` / `aff` | 查看或设置旗标 / 变量 / 好感度 |
| `unlock <类型> <id>` / `unlock all` | 解锁收藏 |
| `ending <id>` | 直接触发某个结局 |
| `state` | 打印当前运行状态 |
| `audit` / `assets` | 就地跑校验 / 看缺哪些素材 |
| `reload` | **热重载当前剧本**（从当前标签重开） |
| `rollback [n]` | 回退 n 句（默认 1）；n 为负数表示前进 |
| `read clear` | 清空已读记录 |

写剧本时不用再「改剧本 → 重启 → 从头点到那一句」。

### 剧本编辑器（`tools/editor/`）

双击 `start-editor.bat` 打开（或直接跑 `tools/editor/editor.tscn`）。三个页面：
**剧本块**（表格化改剧本，保真写回）、**源码**、**素材**。

- **所有指令都能编辑**，只是入口不同：对白行 `Enter` 插入；普通指令在「指令类型」
  下拉里换；`if` / `elif` / `else` / `end` / `choice` / `together` 这类块级指令在
  「流程」「结构 / 跳转」组里插。台词内联标记（`[wait=]` `[stop]` `[fx=…]`）
  直接敲在台词里，`F1` 面板有速查表。
- **字段按需显示**：`audio_fx` 只显示当前效果真正用得到的参数（见「音频效果器」一节）；
  立绘的**「位置」下拉多一个「自定义」**，选中它才会出现 `x` / `y` 输入框
  （选中它 = 清掉槽位、写入坐标；再选回槽位会把坐标清掉，免得坐标盖过槽位）。
- `pause` 是 `wait_click` 的别名，菜单里只留规范写法；旁白走说话人下拉的
  「（旁白）」，不单独列 `narr`。
- **改完立刻能看见**：在剧本块里改一行，右侧预览马上跟着更新（不用点别的行再点回来）——
  包括换立绘 / CG / 背景这些下拉。
- **「从此处预览」会先摆好之前的画面**（背景 / 立绘位置 / 表情都按前面几行的累积结果），
  再从光标那一行往后跑 —— 所以中途移动过、换过表情的立绘，预览里的位置就是游戏里的位置。
- **说话人可以在旁白与角色之间来回换**：旁白行选个角色就变成 `角色: 台词`，
  角色行选「（旁白）」就变回 `narr 台词`（两个方向都不会留下多余的冒号）。
- **变量页**（侧栏「变量」标题旁的「详细」）：**单击一个变量 = 选中**，
  右侧侧边栏列出它**全部**读写位置，每条都能点着跳过去。
  只写不读 / 只读不写会直接写在侧边栏的摘要里。
- **已知限制**：`minigame` 的 `k=v` 参数（`rounds=` / `need=` …）是自由形式的，
  取决于具体小游戏，编辑器只给 `id` 一个字段 —— 那些参数会被原样保留，但不能在界面上改。
- 有一套 **OpSpec ↔ 解析器一致性守卫**（`op_spec_test`）盯着「编辑器能写、解析器不读」
  这类静默失效 —— `move alice at=center` 曾经被静默丢掉，就是它抓出来的。

---

## 测试

```bash
# 回归测试 · headless（990 项断言，快，适合 CI）
godot --headless --path . res://tools/smoke.tscn

# 回归测试 · 窗口模式（995 项，多覆盖「真实输入模拟」一节）
godot --path . res://tools/smoke.tscn

# 编辑器：OpSpec ↔ 解析器一致性守卫（headless）
# 「编辑器能写、解析器不读」这类静默失效就是它抓的（`move at=` 曾经被静默丢掉）
godot --headless --path . res://tools/editor/tests/op_spec_test.tscn

# 编辑器：立绘位置「自定义」下拉的端到端验收（要窗口）
godot --path . res://tools/editor/tests/pos_custom_test.tscn

# 自动截图：依次驱动全部界面并各存一张 PNG（共 14 张）
godot --path . res://tools/capture.tscn

# 多周目界面验收：造一个「第 2 周目 + 通关 3 次」的现场，断言标题与记录面板显示出来了
# （headless 只跑断言，窗口模式另外出两张图）
godot --headless --path . res://tools/cycle_demo.tscn
```

截图输出在 `%APPDATA%/Godot/app_userdata/Galgame Skeleton/captures/`。

> 注意：测试脚本是**场景**而不是 `--script`。因为 `--script` 模式下脚本在主循环启动前编译，
> 此时 Autoload 全局标识符还没注册，会直接编译失败。
>
> 「真实输入模拟」一节（用真实鼠标/键盘事件走 GUI 命中测试，能测出「按钮被遮挡」这类问题）
> **必须窗口模式**才有效 —— headless 下视口只有 64×64，命中测试不可用，测试会自动跳过并提示。
>
> 测试会读写 `user://` 下的真实数据，但开头会整份备份、跑完还原，不会清掉你的进度。
>
> **新增带 `class_name` 的脚本后要跑一次 `--import`**（后面加 `--headless` 也行），
> 否则 Godot 不会把它写进全局类缓存，其它脚本会报「Identifier not declared」。

除功能断言外，套件里还有两类**静态守卫**，专门守「测试看不见的问题」：

| 守卫 | 守什么 |
|---|---|
| 着色器静态检查 | 入口函数里不许出现 `return`（违反时 shader 编译失败，但逻辑测试照样全绿） |
| 着色器 modulate 守卫 | 自定义着色器给 `COLOR` 赋值时，**不许**再乘一遍进来的 `COLOR`（重复叠加顶点色，整层恒暗约 40%），**并且必须**把 `vertex()` 里取到的顶点色乘回去（否则 modulate 被丢掉：说话人压暗、淡入淡出一起失效）。两种坏法都只有量像素才看得见 |
| 架构守卫 | 分层规则：`core`/`autoload` 不许碰表现层；表现层不许反向抓编排层；剧本路径只许出现在 `ScriptPaths` |

两个守卫都带**自检**（喂合成源码确认它们抓得到违规、且不误报注释与字符串）——
一个从不失败的守卫等于没有守卫。

画面类问题还有几个**探针**（跑完打印像素级实测值，比肉眼看截图可靠）：

```bash
# 立绘材质的 modulate 语义对照表（无材质 / 只看贴图 / 叠两遍 / vertex varying）：
# 能抓出「一挂材质就变暗」和「一挂材质就不受 modulate 控制（不再被压暗）」两种坏写法
godot --path . res://tools/char_shader_probe.tscn

# 逐句核对「说话人亮 / 听者真的暗了」（渲染色，不是属性）——压暗失效这类 bug 只有它抓得到
godot --path . res://tools/dim_probe.tscn

# 转场遮罩：progress 0/0.5/1 × 四种模式的渲染色保真度（自带「坏写法必须能量出变暗」的自检）
godot --path . res://tools/mask_fidelity_probe.tscn

# 端到端验收：面板外的压暗程度 + 四种转场中途的保真度
godot --path . res://tools/fix_verify.tscn

# 生成「修复前/修复后」对比截图（存到 user://）
godot --path . res://tools/fix_compare.tscn

# 媒体能力实测：动图格式能不能直接播、两条动画路线并排对比、AnimatedTexture 当采样器
godot --path . res://tools/anim_probe.tscn
godot --path . res://tools/anim_route_probe.tscn
godot --path . res://tools/anim_sampler_probe.tscn

# 视频 / 动态立绘的端到端验收（图层映射、缺失素材不卡死、动态立绘渲染 + 表情过渡）
godot --path . res://tools/media_verify.tscn

# 真机播 .ogv（画面推进 / 位置尺寸 / 有没有 alpha / finished / wait 阻塞）
godot --path . res://tools/video_verify.tscn

# 引擎能力清单（有哪些类、认哪些后缀）
godot --headless --path . res://tools/capability_probe.tscn
```

音频行为这类「属性看不出对错」的毛病，也有专门的探针 ——

```bash
# 音乐播放链路：先直压 AudioManager 量「暂停 / 恢复 / 停止」各自做了什么，
# 再走真实 UI 按钮确认面板接对了（分两层是为了把故障定位到具体哪一层），
# 最后还能用 seek 跳到末尾来验「放完一曲之后切哪一首」，不必真等四十多秒。
# 它抓得到属性断言抓不到的一类 bug：
#   · AudioStreamPlayer.playing 在暂停时读回 false → 「点暂停变成了停止」
#   · 切流后引擎补报一次 finished → 列表循环连跳两首
#   · 在 finished 回调里同步换流 → WAV 那首起不来
#   · WAV 的循环区间是空的 → 开了循环反而放不出来
godot --path . res://tools/music_probe.tscn

# 功能窗口尺寸对账：各面板矩形是否与整图贴图逐像素相等（整图模式差一个像素就静默拉伸）
godot --path . res://tools/panel_probe.tscn
```

> 这两个探针都会写 `user://` 真实数据（`music_probe` 解锁收藏、`panel_probe` 写存档槽 1），
> 跑之前先把 `user://` 备份一份。

**纯逻辑测试看不见布局问题**：面板被撑成两倍大、整个被顶到画布外面，`visible` 依然是
`true`。所以除了量尺寸的断言，改完界面一定要跑一次 `capture` 肉眼看图 ——
记录面板「没占全」和调试控制台「按 `~` 看不见」这两个 bug 都是靠截图发现的。

---

## 目录速查

| 路径 | 作用 |
|---|---|
| `scripts/main.gd` | 编排层，唯一知道所有子系统的地方 |
| `scripts/core/gvs_parser.gd` | 剧本编译器 |
| `scripts/core/script_runner.gd` | 指令流状态机（含重播模式） |
| `scripts/core/rollback_buffer.gd` | 回滚历史缓冲（快照环形队列 + 游标） |
| `scripts/core/script_paths.gd` | 剧本文件位置的唯一权威（含语言子目录解析） |
| `scripts/core/screen_fx_spec.gd` | 全屏特效种类表（解析器与演出层共用） |
| `scripts/core/collection_registry.gd` | 收藏品注册表 |
| `scripts/core/gallery_theme.gd` | 鉴赏界面主题 |
| `scripts/autoload/` | Config / Game / Collection / Audio / Save |
| `scripts/stage/stage.gd` | 演出层（背景 / 立绘 / CG / 转场 / 帧序列动画） |
| `scripts/stage/video_screen.gd` | 过场视频层（Ogg Theora，可指定位置与图层） |
| `scripts/stage/screen_fx.gd` | 全屏特效层（在 UI 之上，连对话框一起变形） |
| `shaders/` | 转场遮罩、立绘表情过渡、全屏特效 |
| `scripts/ui/` | 全部界面 |
| `scripts/minigames/` | 小游戏基类与示例 |
| `data/scripts/` | 剧本 |
| `data/collection/` | 收藏品注册表（CG / 音乐） |
| `data/ui/` | 鉴赏界面外观配置 |
| `tools/` | 测试与截图工具 |

---

## 可视化编辑器

项目自带一个图形化编辑器，覆盖**素材 / 剧本 / 演出 / 翻译**四块。
它不是游戏的一部分 —— 游戏跑 `main.tscn` 时完全不加载它，导出游戏包时
把 `tools/editor/` 排除即可；要单独发给别人，把 Godot 导出预设的主场景
指向 `editor.tscn` 就能变成一个独立 exe，代码一行不用改。

### 启动

```bash
godot --path . res://tools/editor/editor.tscn
```

### 界面

三栏：左（剧本文件 / 章节 / 项目素材统计）· 中（编辑区）· 右（实时预览 + 当前行状态），
底部一条**实时校验**（直接调 `ScriptAudit`，与 CI 同一套规则，点一条跳到对应行）。
**分隔条可以拖**，右侧预览会跟着一起放大（16:9 按栏宽等比缩放，不会变形）；
底部校验区也能拖高，或点顶栏「问题 ▾」整个收起。

顶部切换页面：**源码 / 剧本块 / 分支图 / 素材 / 搜索 / 翻译**
（变量清单常驻左侧栏，不占一个页面 —— 见下节）。

| 页面 | 能做什么 |
|---|---|
| 源码 | 语法高亮、行号、if/choice 块折叠、标签跳转（`CodeEdit` + `CodeHighlighter`） |
| 对白表格 | **剧本的可视化编辑器**（见下节），`Ctrl+F` 查找 |
| 分支图 | 分层有向图，标出死路与孤儿标签，点节点跳到源码（只读，不在图上改结构） |
| 素材 | 7 类素材浏览、缺失看板、未使用反查、缩略图、导入 / 重命名 / 删除 / 撤销 |
| 搜索 | **跨全部剧本**搜素材 id / 台词 / 指令，列出命中并跳转（`Ctrl+Shift+F`） |
| 翻译 | 界面文案漏翻检测、剧本台词清单、译文直接编辑并写回 json |

### 变量清单（在左侧栏）

左侧栏有一节 **变量**，把旗标 / 变量 / 好感度列出来，**点一条跳到它在剧本里的第一处**。
有问题的排在清单最前面，不用去别的地方找。

- 每条写清「写 N · 读 M」（鼠标悬停能看到每一处的文件与行号）。
- 揪出两类**静默**错误 —— 剧本不会为此报任何错：
  - ✕ **只读不写**：剧本和引擎里都没人设过。几乎一定是名字拼错了，
    而那条分支**永远走不到**（这是最贵的一种错）。
  - ⚠ **只写不读**：设了但从没被条件用过。可能忘了接上，也可能只是纯记录，所以只提示。
- **引擎侧会读写的名字不算问题**（标 `·`）：小游戏通关、章节解锁
  （`chapters.json` 的 `unlock_flag`）这类旗标本来就是引擎设或读的。
  判定只认**字面量调用**（`get_flag("x")` / `set_var("x", …)`）与 `chapters.json`，
  **注释里出现不算** —— 项目里 `rhythm_qte.gd` 的注释写着「成功时点亮旗标
  `rhythm_qte_cleared`」，但代码里其实没设，那正是要报出来的真问题。
- 判定规则与 `GvsParser.parse_condition` 对齐：`set var x 3` 和 `set x 3` 都认，
  `not flag x` 也算读，`carry <类别> <名>` 也算读；
  `cycle` / `cleared` **不是**变量，不会被列进来。
- 变量很多、想按条件筛的时候，点这一节标题右边的 **详细** 打开完整页
  （带过滤框和「只看有问题的」开关）。

### 全局搜索（`Ctrl+Shift+F`）

搜素材 id、台词、指令、标签，命中按「文件:行号 │ 原文」列出来，点一条就跳过去。
改素材名 / 删素材 / 查一个 flag 用在哪，都先来这里看一眼全貌。

- 大小写不敏感；不做正则（剧本里 `[](){}` 满地都是，正则容易写错）。
- 当前打开的文件**读内存**而不是磁盘 —— 手动保存模式下编辑器里可能有未保存改动。
- 命中上限 800 条，超出会提示「已截断」。

### 对白表格：整个剧本的可视化编辑

表格不是「只改台词」，而是把**每条指令都渲染成对应的编辑控件**：

| 指令 | 表格里长这样 |
|---|---|
| `bg classroom fade=0.8` | `[背景] [classroom ▾] [转场 ▾] [0.8]` —— 下拉项来自素材索引，旁边带缩略图 |
| `show alice expr=smile at=left` | `[立绘入场] [alice ▾] [smile ▾] [left ▾] [入场 ▾] [0.3]` |
| `bgm daily volume=0.7` | `[音乐] [daily ▾] [音量 0.7] [淡入 1.5]` |
| `weather snow intensity=1.0` | `[天气] [snow ▾] [强度 1.0]` |
| `screen_fx glitch strength=1` | `[全屏特效] [glitch ▾] [强度 1] [秒 0.8]` |
| `alice@smile: 早上好。` | `[alice ▾] [smile ▾] [早上好。] [语音]` |

行右侧没有 `+` / `x`：**插入走 `Enter`、删除走 `Backspace`**（见下面的按键表）。
左侧的「指令」列可以点击**换类型**，菜单按用途分组
（背景与 CG / 立绘 / 音频 / 画面特效 / 流程 / 媒体）；
结构类指令（`label` / `jump` / `if` …）在菜单里是「插入一条骨架」，
而不是「把这一行转过去」—— 把一行台词转成 `end` 会让块结构整体变化、后果隐蔽。

顶部还有一条**场景状态条**：显示「执行到当前光标行为止」的累积画面 ——
背景缩略图 + 立绘（含表情与位置）+ 音乐 + 天气 + CG。
GVS 的状态是累积的（`bg classroom` 之后一直有效直到下一条 bg），
所以光看某一行看不出画面长什么样，这条把结果摆出来。

**结构行**（`label` / `jump` / `if` / `choice` / `end`）刻意不给控件，只显示原文：
删掉一个 `end` 会让后面整段落进块里，而剧本不会报错 —— 剧情会静默走错。
所以删除结构行时会弹确认框把这句话说清楚。

**保真的做法没变**：表格只重写被编辑的那一行，其余行原样搬运，
注释、空行、缩进风格一个字节都不会动。改参数用正则只替换那一个 `key=值`，
**不重新拼整行** —— 重拼会打乱作者的参数顺序，让 diff 变得难读，
而剧本是要进版本控制的。

### 预览会跳过什么

预览窗直接复用游戏的 `Stage` + `ScriptRunner`，所以演出效果与实机一致。
但有两类指令编辑器**主动跳过**，因为它们在预览里没有意义、而且会让调度器
停在等待态（表现为「点不动了」，还不报错）：

| 指令 | 预览里的行为 |
|---|---|
| `minigame` | 按「成功」自动提交，剧情继续往下走（状态栏会提示已跳过） |
| `video` | 不播放，直接告诉调度器「播完了」 |
| `choice` | 正常显示选项按钮，点一下继续 |

音频（`bgm` / `se` / `voice`）不播放 —— 反复预览时音乐会互相打架。

### 与 AI 协作：外部改动自动同步

编辑器每 500ms 检查一次当前剧本文件的磁盘变化。**用 AI 或任何文本编辑器
改完 `.gvs` 保存，界面会自动跟上**，不需要手动刷新。

这靠的是「**手动保存 + 冲突提示**」：编辑只改内存（界面即时刷新），`Ctrl+S` 才落盘。
状态栏会显示「● 未保存」。因为工具手里可能攥着未保存的改动，外部改动
**不会**被静默重载 —— 会弹一个对话框让你选「覆盖磁盘 / 加载外部版本」。
写盘前用 mtime + size 做乐观锁，有人插队同样弹这个对话框。

> Godot 运行时没有内建文件监听（`EditorFileSystem` 的信号只在编辑器插件里可用），
> 所以这里用轮询。一次 `stat` 是系统调用、剧本才几 KB，开销可以忽略。

### 保真保证

编辑器把剧本当**行数组**处理，编辑时只替换改动的那几行。有一条自测守着这件事：

```bash
godot --headless --path . res://tools/editor/tests/core_test.tscn
```

其中第一条断言就是「解析成行、再拼回去，必须与原文件**逐字节相同**」——
它一旦不成立，编辑器每保存一次就会悄悄吃掉作者的注释。

### 素材导入

「素材」页可以批量选文件 → 规范化命名（小写、空格转下划线）→ 复制进
`assets/` 对应目录。同名不覆盖，会自动加序号。

刚导入的素材**立刻能在编辑器里预览**（缩略图优先用导入产物，没导入过的才直读源文件，
所以不依赖 `.import`）。但**运行游戏前**需要让 Godot 重新导入一次资源
（在 Godot 编辑器里打开项目，或跑 `godot --headless --path . --import`）——
因为 `.import` 的生成只能在编辑器进程里完成。

### 基本块分隔

「剧本块」页会按**编译原理课上的基本块（basic block）**把剧本切开：
**领导点**（leader）= 文件首行 · 每个 `label`（跳转到达行）· 跳转/结束指令的
**下一行**（`jump` `goto` `jump_file` `return` `ending`）· 块开闭的**下一行**
（`if` `elif` `else` `choice` `end`）。

块首那一行上方会画一条分隔线并多留一段空白，行号按钮的悬停提示里能看到
「基本块 N」。工具栏的「基本块分隔」按钮可以关掉它。

**块层级（嵌套深度）用「缩进 + 背景微亮」表达，不画竖线** ——
竖线在块首/块尾会断成几截，看着像一条折线。越深越亮，一眼看出范围。

**插入 / 删除后，下方那些行的编号会跟着更新**（行号存在节点 meta 里，
显示的数字同步改；这一步不触发容器重排，245 行约几毫秒）。

**落点永远是「当前行」**，插入 / 删除的滚动**只向下、不向上**。
也就是说：滚到别处去看内容时按回车，新行仍然插在你上次工作的那一行之后，
**视图一动不动**；如果那一行不在屏幕上，状态栏会提示「已插入第 N 行（在视口外）」。
（早期版本会去追那一行，把视图从 7139 拽到 794 —— 看起来像「跳到最顶层」。）

**跳到隐藏行时退到最近的可见行**：源码视图的光标常常停在空行上，
而空行默认不显示 —— 切到表格页时如果因为「这一行不显示」就放弃滚动，
视图会停在文件开头，同样像「跳到最顶层」。现在会滚到它最近的可见邻居。

> 这样一眼就能看出：哪些行是跳转的落点、哪些是跳转之后的死代码、
> 哪些行属于同一个执行序列。

### 分支图怎么读

节点 = 一个 `label` 及其到下一个 `label` 之间的内容；连线 = 出口。出口判定与
GVS 语义一一对应：

| 指令 | 出口 |
|---|---|
| `jump` / `goto` | 跳到目标；**后面是死代码**（不再顺流） |
| `jump_file` | 跨文件出口（画成另一个节点，双击会打开那个文件并跳过去） |
| `ending` / `return` | 终结点，无出口 |
| `call` | **有出口**（被调用的标签确实从这里进去），而且会返回、所以还能顺流 |
| `choice` | 每个选项一个出口；选项即出口，`end` 之后不再顺流 |
| 都没遇到 | 顺流到下一个 `label` |

**鼠标悬停在连线上**，会弹一个小提示说清这条线是**怎么来的**：
```
cg_true_end → cg_true_end_end
跳转 · 第 55 行 · if flag talked_to_x
```
类型（跳转 / 调用 / 选项 / 顺流 / 跨文件）· 行号 · 条件（`if`/`elif`/`else`，
choice 则用选项文本）都在里面；同时那条线会被加粗，方便在一堆线里认出来。

**双击连线**就跳到那条边的来源行（在剧本块里定位）。
单击不跳 —— 会和 `GraphEdit` 自己的鼠标处理打架（单击背景取消选中 / 起框选、
按在端口附近开始拉线）。而且**必须等松开之后才跳**：按下就跳的话 `GraphEdit`
收不到「松开」，内部状态会停在「正在连线」，切回来时还挂着一条橡皮筋。
出口信息**不放在节点里** —— 那会把节点撑得很高，`_fit` 只好把整张图缩到 39%、
字全糊了。节点保持「摘要 + 说明」两行，信息都在悬停里给。

初始缩放有**可读下限（55%）**：横向超出就横向滚（流程图本来就该这么看），
想全局概览就按「适应窗口」或用滚轮缩。

**特殊节点一眼可辨**：

| 标记 | 含义 |
|---|---|
| `▶` 绿 | 起点 |
| `★` 品红 | 结局（块里有 `ending`；说明行上也会写「★ 结局」） |
| `↩` 蓝 | 子过程（块里有 `return`，会被 `call`） |
| `⚠` 黄 | 孤儿 —— 没有任何入边，走不到 |
| 蓝紫框 | 跨文件出口（`jump_file`） |

**节点标题可以起备注**：在剧本块的标签行填「备注」，
会写成 `label cg_classroom  # 教室 CG` 这样的行尾注释 ——
备注跟着剧本走（git、源码视图都看得见），而且解析前会先剥掉注释，完全不影响语义。

**图是只读的**：拖端口不会连线（改结构请回剧本块或源码）。
节点**双击**跳到剧本块（单击不跳 —— 否则拖动节点或鼠标扫过都会乱跳）。

**`if` / `elif` / `else` 里的 `jump` 都是出口**（条件跳转），一个块里的多条
都会画出来，块本身也不会在第一个 `jump` 处断掉。

**`call` / `return` 不画返回边**：`call` 是可重入的，一个子过程常被多处调用
（`common_pause` 就被两处 call），返回边会变成一堆交叉线，把「整体结构」这张图搅乱。
改成在节点上标注 —— 子过程节点标题带 `↩`，下面写「子过程（有 return）· 被 N 处调用：…」；
调用方节点写「→ call xxx」。谁调它、会不会回来，一样看得清。

节点下面的「孤儿标签」是**没有任何入边**的标签（`jump` 到不了、也不顺流过来），
它们会被放到最后一列并用警示色标出来。

### 素材页

七类素材分页浏览，每张卡片可看详情（尺寸 / 时长 / 被哪些剧本行引用）。

**导入入口在素材流的尾巴上**：网格最后一张卡片就是「＋」。

| 位置 | 点「＋」会发生什么 |
|---|---|
| 背景 / CG / 音效 / 音乐 / 语音 / 视频页 | 选文件 → 复制进对应目录并规范化命名 |
| 立绘页 | **新建角色**（角色是目录，表情要到角色合集里导） |
| 立绘合集内 | 往**这个角色**的目录导入立绘表情，文件名就是表情名 |

**也可以直接把文件拖进来**（从资源管理器拖到网格上）。立绘页要拖到某个角色卡片上；
拖在空白处会提示「立绘是两级目录」，不瞎猜。

**卡片右上角两个徽章**：

| 徽章 | 作用 |
|---|---|
| `✎` | 重命名。**会同步剧本引用**（见下） |
| `✕` | 删除（先弹确认框，框里会说「还有几处引用会变成死链」） |

**重命名不是只改文件名** —— 它把项目里所有写着旧 id 的地方一起改掉，
否则剧本不报错、只是画面黑掉：

| 素材类别 | 同步改哪些 |
|---|---|
| 背景 / CG / 音效 / 语音 / 视频 | 剧本里对应指令的位置参数（`bg` / `cg` / `unlock cg` / …） |
| 音乐 | 同上，另加 `data/collection/music.json` 的 `id` |
| CG | 另加 `cg.json` 的 `id` 与 `image` 路径、`endings.json` 的 `image` 路径 |
| 立绘角色 | 立绘指令的第一参数、对白前缀 `alice: …`、`affection alice`、`if affection alice >= 10`、`carry affection alice` |
| 立绘表情 | `show … expr=<表情>`、`expr <角色> <表情>`、对白前缀 `alice@<表情>: …` |

⚠️ **只改「结构位置」，绝不全文替换** —— 台词正文里出现同名的词是常事
（`alice@smile: 我笑了 smile。`），全文替换会把台词改坏，而且改坏了不报错。
⚠️ **角色改名不会改存档里的好感度**（存档是玩家数据，工具不碰），确认框里会说清。
⚠️ 手里有未保存改动时会拒绝改素材 —— 因为改素材会连带改剧本文件。

**`↶ 撤销`**：重命名和删除都能一键还原（文件 + 剧本引用一起回滚，最近 30 次）。
这是编辑器里唯一会动文件系统的操作，误删不该只能靠 git 捞。

**侧栏的条目可以点**：「缺失素材」点一下跳到剧本里引用它的那一行；
「未被引用」「素材检查」点一下定位到网格里的那张卡片。

**详情里还有**「用系统看图程序打开」「在资源管理器中显示」——
缩略图只有 74px 高，要看一张立绘画得对不对只能交给系统看图程序。

- **立绘**：**双击**角色卡片进入**立绘合集** —— 该角色所有表情的缩略图，
  静态与帧序列（动态立绘）分开标注。单击只更新右侧详情（详情里也有
  「进入立绘合集 →」入口，双击是隐藏操作，得留条明路）。
  进合集会把整个网格换掉，所以「看」和「进」分开 —— 想连着看几个角色的表情数
  不用反复进出。
- **语音**：也是两级 —— `assets/audio/voice/<角色>/<台词>.ogg`，剧本写 `voice <角色>/<台词>`。
  语音页和立绘页一样按角色浏览，但**密度更高**：条目是「♪ + 名字 + 时长」的紧凑行
  （一行三条），不像立绘那样用大缩略图卡片 —— 语音是纯文字条目，大卡片会留一大片空白。
  - **双击**角色卡片进「语音合集」看那个角色的全部语音；
    合集末尾的「＋」直接导进**那个角色的目录**。
  - **页面会列出所有立绘角色**，包括**还没有语音目录**的（暗色标「还没有语音目录」）——
    这样一眼就知道还有谁没配音。点进去导语音时会自动建目录。
  - **新建分类**：语音页末尾的「＋」卡片 = 新建角色（`assets/audio/voice/<角色>/`），
    建完自动进那个角色的合集。**空目录也会显示成角色卡片**，不会「建了却看不见」。
  - 根目录下的散文件归到「未分组」卡片里。
  ⚠️ **组名要进 id**：只把目录当纯组织的话，两个角色各有一个 `01.ogg` 就撞了，
  而撞了之后游戏会播到另一个角色的语音 —— 这种错极难查。
  角色卡片上的 `✎` / `✕` 改 / 删的是**整个角色目录**（改名会同步剧本里
  所有 `voice <旧角色>/…` 引用），删掉也能 `↶ 撤销`。
- **新建角色**：在 `assets/sprites/<角色 id>/` 下建目录，并顺手放一张从已有角色复制来的
  `normal.png` 占位立绘。`normal` 是**默认表情** —— 剧本写 `show <角色>`（不带 `expr=`）
  取的就是它，不放的话游戏会掉进占位素材生成器，画面里蹦出一个程序化火柴人。
  换成自己的图即可。
  （空目录其实也会出现在立绘页里，只是卡片没有缩略图 —— 占位图的作用是上面那条，
  不是「让它可见」。）

### 结局 / 章节名的双引号

`ending normal "春日的答案"` 的标题、`chapter 第一章 · 春日的答案` 的章节名
都是**位置参数 + 双引号整段**（值里可以有空格和 `·`），不是 kv 参数。
表格里按「整段」读写，改完自动补上双引号。

### 左侧栏：「剧本」与「章节」不是一回事

| 栏 | 来源 | 含义 |
|---|---|---|
| 剧本 | `data/scripts/` 下的每个 `.gvs` 文件 | 一个文件 |
| 章节 | `data/scripts/chapters.json` | 人工排的目录：章节标题 → 某个文件 + 起始标签 |

一个文件可以不属于任何章节（比如只被 `jump_file` 调用的片段）；
一个章节也可以指向别的文件里的标签。**新建剧本不会自动改 `chapters.json`** ——
那是人工排的目录（顺序和标题都是创作决定），工具只在新建出的骨架里写清怎么登记。

每行右边的 **`⋯`** 是这一行的操作菜单：

- **重命名**：改名并**同步三处引用** —— `chapters.json`、`cg.json`（重播片段）、
  各剧本里的 `jump_file <路径>`。
- **删除**：删掉文件（删的是当前打开的那个就先自动切到别的剧本）。
  确认框里会告诉你**还有几处引用会变成死链** —— 章节条目、重播片段、跳转
  都是创作决定，工具不替作者静默清理。

⚠️ **入口剧本（`prologue.gvs`）不能改名也不能删** —— 它的名字写死在
`ScriptPaths.entry()` 里，改了游戏就找不到入口。工具会拦下并说明原因。
⚠️ 手里有未保存改动时会拒绝改名 / 删除，先 `Ctrl+S`。

### 快捷键

| 键 | 作用 |
|---|---|
| `Ctrl+S` | 保存到磁盘（平时只改内存，界面即时刷新） |
| `Ctrl+Z` / `Ctrl+Shift+Z` / `Ctrl+Y` | 撤销 / 重做（源码页归 CodeEdit 自己的撤销栈） |
| `Ctrl+R` | 重新扫描素材索引 |
| `Ctrl+Shift+F` | 全局搜索（跨全部剧本） |
| `Ctrl+F` | 剧本块内查找（仅「剧本块」页） |
| `F5` | 从当前行开始预览 |
| `F1` / `?` | 快捷键一览 |

**对白表格里的键**（焦点不在输入框时才生效）：

| 键 | 作用 |
|---|---|
| 点击整行 / `↑` / `↓` | 选中行 / 换行 |
| `Enter` | 在选中行下方插入一条对白，并聚焦它的台词框 |
| 台词框里 `Enter` | 提交这一句并接下一行（连续写剧本不用摸鼠标） |
| `Backspace` / `Delete` | 删除选中行（结构行会先确认），删完选中吸附到**上一行** |
| `Ctrl+V` | 剪贴板里有多行时，自动拆成多行对白插在当前行之后 |

### 预览：跟随光标

右侧预览默认**跟着光标走**：光标移到哪一行，画面就直接摆出「执行到这一行」的样子
（背景 / 立绘 / 表情 / 位置 / CG / 天气，那一行是对白的话连对话框一起）。

GVS 的状态是累积的（`bg classroom` 之后一直有效直到下一条 `bg`），所以「第 N 行画面长什么样」
可以直接算出来，不必点 `▶` 从头播 —— 否则改一行就要重播一遍，调演出基本没法用。

- 点 `▶ 从此处预览` 会由调度器接管画面（这时候不跟随，免得跟播放打架）；
  按停止之后交还给跟随。
- 不想跟随时把「跟随光标」关掉即可。

### 预览：从光标那一行精确开始

`▶ 从此处预览`（或 `F5`）**从光标所在的那一行开始**，不是从最近的标签重播：

1. 先把「执行到上一行为止」的累积画面摆好 —— 所以前面设过的背景 / 立绘 / 表情都在，
   不会出现「从中间开始预览就一片黑」；
2. 再从这一行对应的指令开始跑。

落点落在注释或空行上会自动往后顺延到第一条可执行指令；
落在 `choice` 的选项上就从那条 `choice` 开始（「从选项中间开始」没有意义）。
只有「这一行之后一条可执行指令都没有」时才不跑，并在状态里说明原因。

预览用的是**内存里的剧本**，不是磁盘 —— 手动保存模式下有未保存改动时，
改完就能直接 `F5` 看到效果。

**文字特效在预览里是真效果**：`[bounce]` / `[blink]` / `[glitch]` 与 Godot 内置的
`[shake]` / `[wave]` / `[rainbow]` / `[fade]` / `[pulse]` 都会渲染出来，
不会连方括号一起漏成正文。节奏标记（`[wait=0.7]` / `[speed=3]`）会被剥掉 ——
那些是给打字机用的，预览里没有打字机。
⚠️ 自定义特效的清单只有一份（`scripts/ui/text_effects/text_effects.gd`）——
没登记的特效标签会**原样漏成文本**，回看面板和预览各漏过一次。
| `Esc` | 从输入框退回「行选中」态 |

表格里每一行左侧的「指令」列可以点击换成别的指令类型（对白 ↔ bg / show / …），
能沿用的参数会跟着搬过去，搬不了/丢掉的会在提示里说出来。

**改完不用非得按回车**：所有内联输入框（数值 / 文本 / 语音 / 跳转目标）在**失焦时**
也会提交 —— 改完直接去点别处不会白改一场。

**结构 / 块级指令**（`label` `jump` `goto` `call` `return` `jump_file`
以及 `choice` `if` `end`）在菜单里是**只能插入、不能转换**的：
选它们会在当前行下面插一条带骨架的新行。理由：把一行现成的台词转成 `end`
会让块结构整体变化，后果隐蔽。

**跳转目标可点击**：`jump` / `goto` / `call` / `jump_file` 的目标渲染成链接，
**`choice` 选项的箭头（`→`）同样可点** —— 点一下就在**剧本块里**定位到那个
`label`（跨文件的会打开另一个剧本，但**仍然留在剧本块页**）。
定位不会把你甩到源码页，省得丢掉正在看的位置。
目标不存在时链接标红 —— 这样「死跳转」在表格里一眼就看得见，不用等静态校验。
（行号按钮仍然跳源码：那是「我要看原始文本」的明确动作，tooltip 里写着。）

### 编辑器的测试

```bash
# 核心自测（106 项）：逐字节保真 / 行分类 / 与解析器语义一致 / 文档编辑 /
# 撤销 / 写盘 / 指令参数写回 / 素材索引 / 文件监听
godot --headless --path . res://tools/editor/tests/core_test.tscn

# 增删改端到端验收（16 项）：插入对白与指令、改参数、删除、撤销。
# 改完还会用 GvsParser 解析一遍，确认语义真的对（不只是字符串看着对）
godot --path . res://tools/editor/tests/edit_test.tscn

# 纯净性验收（4 项）：跑完整流程后，所有剧本与配置文件的 SHA256 必须不变
godot --path . res://tools/editor/tests/purity_test.tscn

# 预览端到端（4 项）：从 start 一路跑到 ending，断言不卡在任何等待态
godot --path . res://tools/editor/tests/preview_test.tscn

# 按行预览 / 行内表情验收（22 项）：解析器给每条指令盖的 line 键 /
# start_at_line 精确落到那一行（落在注释、空行、choice 选项上分别怎么办）/
# 对白行里的内联表情 `alice@smile:` 要进 line_state（否则预览表情永远不变）
godot --headless --path . res://tools/editor/tests/preview_line_test.tscn

# 素材引用重写验收（46 项）：改名时只改「结构位置」——
# 台词正文里的同名词、前缀相同的另一个 id、注释里的名字都不许动；
# 角色改名要连 affection / if 条件一起改；find 与 rewrite 口径必须一致
godot --headless --path . res://tools/editor/tests/asset_refs_test.tscn

# 素材撤销栈验收（23 项）：改名的反向移动、删除的内容还原（含被删掉的中间目录）、
# 空目录的还原、空操作不入栈、后进先出、栈深上限
godot --headless --path . res://tools/editor/tests/asset_undo_test.tscn

# 变量清单验收（26 项）：三种变量 × 写 / 读 × 各种写法
# （`set var x` vs `set x`、`not flag x`、`and` 连接、carry、跨文件累计），
# 以及 `cycle` / `cleared` **不是**变量；只读不写 = error、只写不读 = warn
godot --headless --path . res://tools/editor/tests/var_index_test.tscn

# 外部改动同步端到端验收（8 项，会临时改写入口剧本但保证还原）
godot --path . res://tools/editor/tests/sync_test.tscn

# 对白表格已报 bug 回归（51 项）：置旗标开关的值写回、插入行的落点 /
# 滚动不把画面顶走 / 新对白沿用上一行说话人 / 状态条跟着当前行。
# 跑完还要 grep 一遍控制台有没有 SCRIPT ERROR —— 那条报错不会让断言失败，
# 但值其实没写进去，只有把日志也纳入判定才守得住
godot --path . res://tools/editor/tests/table_bugs_test.tscn

# 剧本块新交互验收（134 项）：点选中行 / 方向键 / 回车加行 / 退格删行 /
# 台词框里回车接下一行 / 指令列换类型（含参数沿用与丢弃）/ 行右不再有 + x /
# 基本块分隔（领导点划分）/ 指令类型配色两两可分 / 块竖线与折叠 / 块间距 /
# 多行粘贴拆行 / 行内错误标记 / 默认不显示空行与注释 / 插入后行号联动 /
# 新增指令类型 / 结构指令是「插入」而非转换 / ending 与 chapter 的标题 /
# 变量指令的可选 var / 跳转目标可点击（含 choice 箭头、死跳转标红、跨文件）
# 且定位**留在剧本块页**（不甩到源码页）
godot --path . res://tools/editor/tests/table_ux_test.tscn

# 分支图验收（57 项）：call 的目标不能成孤儿 / 终结指令不产生假 fall-through /
# jump_file 画成跨文件出口 / if-elif-else 里的跳转全部连上 / 子过程标注 /
# 悬停连线弹提示（原因 · 行号 · 条件）/ 双击连线跳转（单击不跳）/
# 结局与起点的标记与优先级 /
# 标签备注显示在节点上且能在剧本块里编辑 / 双击才跳转（单击不跳）
godot --path . res://tools/editor/tests/graph_test.tscn

# 工具操作验收（110 项，会真建 / 真删文件但自带清理）：新建剧本（骨架 / 重名拒绝 /
# 非法名拒绝）/ 立绘合集（点卡片打开、卡片数对得上、能关）/ 新建角色（建目录 +
# 占位立绘 + 进索引 + 重名拒绝）/ 剧本重命名与删除（jump_file 引用同步、入口剧本
# 保护、删当前打开的先切走）/ 素材 ＋卡片与 ✕ 删除 / 素材重命名（引用同步 + 撤销
# 回滚）/ 全局搜索（跨文件命中、搜不到）/ 剧本块查找（第 N/M 处、上下跳）/ 预览跟随光标
godot --path . res://tools/editor/tests/editor_tools_test.tscn

# 剧本块流畅度验收（21 项）：**真正的守卫是「加一行不许重画整张表」** ——
# 断言已有行控件的实例 ID 原封不动。时间阈值只是宽松哨兵
godot --path . res://tools/editor/tests/table_perf_test.tscn

# 界面截图，输出到 user://captures/editor_*.png（7 张）
godot --path . res://tools/editor/tests/shot.tscn
```

> **纯净性验收守着一个真实踩过的坑**：编辑器曾在「切换页面 / 定位光标 / 跑预览」
> 的过程中，把两行模板文本插进了剧本开头，把原有注释挤掉了。那类损坏不报错、
> 不影响解析、界面也看不出来 —— **只有比对文件才发现得了**。
> 所以这条测试就比对文件，并且顺手在写入路径上加了「行号过期校验」
> （写入前比对目标行的原文，不一致就放弃）与「插入防抖」。

### 代码结构

```
tools/editor/
├── editor.gd / editor.tscn      主控：三栏布局、页面切换、外部改动处理、快捷键
├── ed_theme.gd                  深色 IDE 主题（独立于游戏的 ui_theme.json）
├── core/
│   ├── line_index.gd            行分类器（保真的根基）
│   ├── script_doc.gd            剧本文档：行数组 + 编辑 + 写盘 + 乐观锁
│   ├── project_index.gd         素材索引（7 类素材 / 缩略图 / 缺失 / 未使用）
│   ├── asset_refs.gd            素材 id 的引用点：查找 / 重写（改名同步用）
│   ├── asset_undo.gd            素材操作撤销栈（文件 + 剧本引用一起回滚）
│   ├── var_index.gd             变量清单：旗标 / 变量 / 好感度的写读点
│   └── file_watcher.gd          文件监听（轮询）
├── panels/                      源码 / 剧本块 / 分支图 / 素材 / 搜索 / 变量 /
│                                翻译 / 问题列表 / 预览
└── tests/                       core_test / edit_test / sync_test / purity_test /
                                 asset_refs_test / asset_undo_test / var_index_test /
                                 preview_line_test / preview_test / ui_paths_test /
                                 table_bugs_test / table_ux_test / table_perf_test /
                                 graph_test / editor_tools_test / shot
```

**为什么放在 `tools/` 而不是 `scripts/`**：`scripts/` 下有 smoke 第 27 节的架构守卫
（core/autoload 不许引用表现层、ui/stage 不许引用编排层）。编辑器天然要同时引用
`Stage`（预览）与 `GvsParser`（core），放在 `tools/editor/` 既避开守卫，语义上也正确：
它是工具，不是游戏代码。
