# Galgame Skeleton

Godot 4 视觉小说（galgame）工程骨架。引擎、系统、演出、存档、工具链全部做完，
**零素材、零配置即可运行**——直接打开工程按 F5 就能走完序章到结局的完整流程。

- 详细设计：[`DESIGN.md`](DESIGN.md)
- 剧本语言规格：[`DESIGN.md` 第四节](DESIGN.md#四剧本语言-gvs-规格)

---

## 快速开始

1. 打开 Godot 4.7+，`导入` → 选择本目录的 `project.godot`
2. 按 `F5` 运行（主场景已设为 `scenes/main.tscn`）
3. 点「开始游戏」

命令行运行：

```bash
"D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path "D:/Work/WorkBuddy AI/galgame"
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
- **音乐鉴赏**：曲目列表（当前曲目高亮）+ 播放控制 + 旋转唱片 / 跳动频谱
- **界面高度自定义**：配色、字体、按钮尺寸与贴图、对话框位置全在 `data/ui/ui_theme.json`；
  鉴赏界面的列数/卡片/可视化在 `data/ui/gallery_theme.json`
- **回滚**：滚轮在历史里前后翻，还原当时的画面与状态，退到选项处可改选
- 回看、设置（音量 / 文字速度 / 全屏 / 跳过策略 / 滚轮回滚 / 已读变暗，即时生效并持久化）

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
assets/audio/bgm/<id>.ogg           BGM（也支持 mp3 / wav）
assets/audio/se/<id>.ogg            音效
assets/audio/voice/<id>.ogg         语音
```

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

1. 把 `.ttf` / `.otf` 放进 `assets/fonts/`
2. 在配置里填路径：

```json
"fonts": {
  "body": "res://assets/fonts/main.ttf",
  "title": "res://assets/fonts/title.ttf",
  "dialogue": "res://assets/fonts/main.ttf"
}
```

留空 = 用 Godot 内置默认字体。文件不存在会打警告并自动回退，**不会崩**。

字号在同文件的 `font_sizes` 段：`title` / `subtitle` / `heading` / `dialogue` / `speaker` / `backlog` / `button` / `label` / `small`。

### 换按钮尺寸

按钮按「预设」管理，共 6 个：`title`（标题界面）、`choice`（选项）、`hud`（右上角）、`track`（曲目）、`default`、`small`。

```json
"buttons": {
  "title": { "width": 340, "height": 68, "font_size": 26, "radius": 10, "pad_h": 24, "pad_v": 12 }
}
```

`width: 0` 表示宽度自适应内容（HUD 按钮就是这么配的）。

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
| BGM | `assets/audio/bgm/` | 剧本里 `bgm daily` → `daily.ogg` | ogg / mp3 / wav |
| 音效 | `assets/audio/se/` | 剧本里 `se bell` → `bell.ogg` | 同上 |
| 语音 | `assets/audio/voice/` | `voice <id>` | 同上 |

**找不到就退回程序化占位图（背景/立绘/CG）或静默跳过（音频），代码零改动。**

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

### 换外观

改 `data/ui/gallery_theme.json` 就行，**不用碰代码**：

```json
{
  "palette": { "accent": "#e0603c" },
  "layout":  { "columns": 4, "card_width": 300 },
  "text":    { "locked_label": "？？？", "replay_button": "重温这一幕" },
  "visualizer": { "mode": "spectrum" }
}
```

可以只写关心的键，其余自动用默认值。`visualizer.mode` 支持 `disc`（旋转唱片）/ `spectrum`（频谱）/ `both` / `none`。

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

改完直接重新运行即可，不需要任何编译步骤。完整指令表见 `DESIGN.md`。

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
| `[wait=0.5]` | 在此处停顿 0.5 秒 |
| `[pause=0.3]` | 同上（别名） |
| `[speed=3]...[/speed]` | 这一段按 3 倍速逐字显示 |

基准速度是玩家设置里的「文字速度」（默认 45 字/秒），`[speed=N]` 是相对它的倍数。

**节奏标记不占可见字符**，和特效标记能混用且对齐正确。单字等待有 0.35 秒上限 —— 写 `[speed=0.001]` 也不会把节奏拖死。

底层实现：`TypingTimeline` 把带标记的文本预编译成「每个可见字符在第几秒出现」的时间轴，播放时二分查表。所以停顿、变速、跳过、暂停都不会让进度错乱。

**标记只会留在对话框里**。回看面板和存档预览显示的是剥掉节奏标记之后的文本 ——
不剥的话，那两处会直接出现 `[wait=0.7]`、`[speed=2.5]` 这样的字样。

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

### 语音

```gvs
voice alice_001          # 写在台词「前面」，会被认领成这一句的语音
alice: 早上好。
```

播完之后**点对话框上的名字牌可以重播**这一句。文件放 `assets/audio/voice/<id>.ogg`，
没有素材时静默跳过，不会报错。

同一句里连写多条 `voice`，会**依次排队播完**（不会后一条把前一条掐掉）：

```gvs
voice alice_001
voice alice_002
alice: 两句配音连在一起。
```

但如果玩家**推进到下一句**，上一条语音会立刻中断、队列也一并清空 ——
让旧语音拖到新台词上会声画错位，玩家听到的是上一句、看到的却是新的一句。

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
"D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --headless --path . res://tools/audit.tscn
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

---

## 测试

```bash
# 回归测试 · headless（643 项断言，快，适合 CI）
"D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --headless --path . res://tools/smoke.tscn

# 回归测试 · 窗口模式（648 项，多覆盖「真实输入模拟」一节）
"D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/smoke.tscn

# 自动截图：依次驱动全部界面并各存一张 PNG（共 14 张）
"D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/capture.tscn
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
| 架构守卫 | 分层规则：`core`/`autoload` 不许碰表现层；表现层不许反向抓编排层；剧本路径只许出现在 `ScriptPaths` |

两个守卫都带**自检**（喂合成源码确认它们抓得到违规、且不误报注释与字符串）——
一个从不失败的守卫等于没有守卫。

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
| `scripts/stage/stage.gd` | 演出层（背景 / 立绘 / CG / 转场） |
| `scripts/stage/screen_fx.gd` | 全屏特效层（在 UI 之上，连对话框一起变形） |
| `shaders/` | 转场遮罩、立绘表情过渡、全屏特效 |
| `scripts/ui/` | 全部界面 |
| `scripts/minigames/` | 小游戏基类与示例 |
| `data/scripts/` | 剧本 |
| `data/collection/` | 收藏品注册表（CG / 音乐） |
| `data/ui/` | 鉴赏界面外观配置 |
| `tools/` | 测试与截图工具 |
