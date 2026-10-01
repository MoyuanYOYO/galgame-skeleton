# Galgame Skeleton — 详细设计方案

> Godot 4.7 · 视觉小说（ADV / galgame）工程骨架
> 目标：把「引擎、系统、演出、存档、打包」全部做完，创作者只需要写剧本和换素材。

---

## 一、设计目标

| 目标 | 落地方式 |
|---|---|
| 零素材也能跑 | 运行时程序化生成占位背景与立绘，`assets/` 空目录也能完整走完流程 |
| 剧本与代码分离 | 自定义行式 DSL（GVS），非程序员可写；改剧本不碰一行 GDScript |
| 模块可替换 | 每个子系统只通过信号 / 公开方法通信，删掉任意一个不影响其余 |
| 存档可靠 | 全部状态可 JSON 序列化；读档能精确复现当时的画面与进度 |
| 小游戏可插拔 | 小游戏 = 独立 Scene + 统一契约，加新玩法不用改主流程 |
| 可自动化验证 | 提供 headless 冒烟测试与截图工具，改完立刻知道有没有坏 |

**关于 rollback**：初版把它列为「明确不做」——理由是它需要完整状态快照栈，看似与「单指令指针」的存档模型冲突。后续实现下来发现冲突是假的：**快照里存的仍然只是那一个 `ip`**（外加软状态与画面摘要），还原时让调度器重新执行该指令即可，完全复用读档路径。所以现在滚轮回滚是标配功能（见 5.16），**回看（Backlog）** 仍然保留 —— 前者用来退回去看 / 改，后者用来快速翻阅大段已读文本，两者用途不同。

---

## 二、技术选型

| 项 | 选择 | 理由 |
|---|---|---|
| 引擎 | Godot 4.7.2 stable | 免费、单文件可执行、`Control` 节点天然适合 UI 密集型画面 |
| 渲染后端 | GL Compatibility | 2D 视觉小说用不上 Forward+；兼容性更好，且可导出 Web |
| 分辨率策略 | 设计分辨率 1920×1080 + `stretch_mode=canvas_items` + `aspect=keep` | 所有坐标写死设计分辨率即可，多端适配由引擎完成 |
| 剧本格式 | 自定义 DSL（非 JSON/YAML） | JSON 写对白反人类；DSL 可以用 `角色: 台词` 这种最自然的写法 |
| 解析策略 | **编译式**（解析成扁平指令数组 + 标签表） | 运行期只需一个整数 `ip` 就能表达全部控制流，存档只需存这个整数 |
| 通信方式 | 信号（Signal） | 调度器不需要知道 UI 存在，可脱离界面做单元测试 |
| 存档格式 | JSON（`user://saves/*.json`） | 可读、可手改、跨版本兼容容易做 |

---

## 三、总体架构

```
┌──────────────────────────────────────────────────────────────┐
│  main.gd  ── 唯一知道所有子系统的地方（编排层）                │
└───────┬──────────────────────────────────────────┬───────────┘
        │ 转发信号                                  │ 转发交互
        ▼                                          ▼
┌────────────────────┐                   ┌──────────────────────┐
│  Stage（演出层）    │                   │  UI 层                │
│  · 背景 crossfade   │                   │  · DialogueBox 打字机 │
│  · 立绘 show/hide   │                   │  · ChoicePanel 选项   │
│  · 转场 Tween       │                   │  · BacklogPanel 回看  │
└────────────────────┘                   │  · SettingsPanel 设置 │
        ▲                                │  · SaveLoadPanel 存读 │
        │ stage_command                  │  · TitleScreen 标题   │
        │                                └──────────┬───────────┘
┌───────┴───────────────────────────────────────────┴───────────┐
│  ScriptRunner ── 指令流状态机                                   │
│  · 持有 _commands / _labels / _ip / _call_stack                │
│  · 抛出 say / choices / minigame_requested / stage_command ... │
│  · 阻塞型指令进入等待态，等外部 advance / submit_*             │
└───────────────────────────┬───────────────────────────────────┘
                            │ 读取 / 写入
        ┌───────────────────┼───────────────────┬───────────────┐
        ▼                   ▼                   ▼               ▼
┌───────────────┐  ┌───────────────┐  ┌──────────────┐  ┌────────────┐
│ GameManager   │  │ SaveManager   │  │ AudioManager │  │ ConfigMgr  │
│ 旗标/好感度/   │  │ 多槽位 JSON   │  │ BGM/SE/语音  │  │ 设置持久化  │
│ 变量/游戏时长  │  │ 纯存储层      │  │ 缺素材静默   │  │ 实时生效    │
└───────────────┘  └───────────────┘  └──────────────┘  └────────────┘
```

### 关键设计决策

**1）为什么把条件块编译成跳转，而不是直接解释？**

`if / elif / else` 在解释器里需要维护「块栈 + 当前分支是否命中」的运行时状态。一旦要存档，就得把这一整坨状态序列化。编译成 `branch_false + jump` 之后，控制流全部塌缩成整数指针，存档只存一个 `ip`。这是本骨架最重要的一个决定。

**2）为什么调度器不直接操作 UI？**

`ScriptRunner` 是纯逻辑节点，`stage_command` / `say` 等全部走信号。好处：
- 可以在 headless 里把整条剧本跑完并断言结果（见 `tools/smoke.gd`）
- 换 UI 风格、换引擎版本都不影响剧本逻辑
- 同一个 runner 可以被测试脚本、截图脚本、正式游戏三种宿主驱动

**3）为什么小游戏用信号而不是返回值？**

小游戏是异步的（玩家要玩几秒到几分钟）。用信号 + 等待态，主流程完全不需要知道小游戏内部结构，也天然支持「小游戏里再触发小游戏」这种嵌套。

### 分层规则

四层，依赖只能自上而下：

| 层 | 位置 | 职责 | 不许做什么 |
|---|---|---|---|
| 表现层 | `scripts/ui/` `scripts/stage/` | 面板与演出 | 不许反过来抓编排层（调试台是白名单例外） |
| 编排层 | `scripts/main.gd` | 唯一知道全部子系统的地方 | —— |
| 服务层 | `scripts/autoload/` | 全局单例（设置 / 状态 / 存档 / 音频…） | 不许引用任何面板或演出层 |
| 核心层 | `scripts/core/` | 纯逻辑：解析器 / 调度器 / 统计 / 校验 / 主题 | 同上；且应尽量能脱离场景跑 |

`UiTheme` 是个有意为之的例外：它是**共享的表现工具**（样式盒工厂、按钮贴图装配），
不是某个面板，所以 `ConfigManager` 可以在最早的时机（autoload 的 `_ready`，早于主场景
和所有面板的 `_ready`）调它来装载调色板与字体 —— 这是全局字体能生效的唯一时机。

**这些约定由 smoke 第 27 节的「架构守卫」静态扫描守着**：

- `core` / `autoload` 里不得出现任何表现层类型名
- `ui` / `stage` 里不得出现 `_main`（调试台按白名单豁免，理由写在它文件头）
- `res://data/scripts` 这个字面量只允许出现在 `script_paths.gd` 里

守卫本身也带自检（喂合成源码，确认它抓得到真违规、且不会误报注释与字符串）——
**一个从不失败的守卫等于没有守卫**。

写这类静态检查有两个坑：GDScript 的注释是 `#` 而不是 `//`；而 `#` 也出现在字符串里
（`"[color=#a9a3d0]"`），所以必须**先剥字符串再砍注释**，顺序反了会把代码行从中间截断。
另外正则要用词边界，否则 `Stage` 会命中 `StageXxx`。

### 布局坑：CanvasLayer 下的 Control 尺寸

**代码创建、直接挂在 `CanvasLayer` 下的 `Control`，锚点拿不到父级尺寸。**
它的 `size` 会由内容撑出来 —— 记录面板就因此变成约 1422×890 的「卡片」卡在左上角，
右边和下边各留一大片空（「记录界面没占全」的根因）。

`main.tscn` 里定义的面板没这个问题（场景加载时拿到了尺寸），所以只有运行时创建的
`RecordsPanel` / `DebugConsole` 需要手工处理。做法是把**锚点固定在左上角**，
让矩形完全由 offset 决定：

```gdscript
set_anchors_preset(Control.PRESET_TOP_LEFT)
offset_left = 0.0
offset_top = 0.0
offset_right = rect.x      # 视口宽
offset_bottom = rect.y     # 视口高
```

**这里有个反直觉的陷阱**：写成 `PRESET_FULL_RECT` + `offset_right = rect.x` 看起来更
「正确」，实际会得到「视口宽 + 视口宽」—— FULL_RECT 的左右锚点是**非等值**的
（left 0 / right 1），矩形 = 锚点位置 + offset，于是 1920 的视口撑出 3840 的矩形。
调试控制台就这么被坑了很久：矩形两倍大 + 面板锚在**底部** → 整个控制台被顶到画布外，
按 `~` 什么都看不见，而逻辑测试只断言 `visible`，一路绿灯。

**教训**：这类问题只有截图能发现。改完面板布局务必跑一遍 `tools/capture.tscn` 肉眼看图；
对应的断言要量**尺寸**（`console.size` 是否等于视口），而不是只查可见性。

---

## 四、剧本语言 GVS 规格

### 4.1 基本写法

```gvs
# 井号开头是注释（引号内的 # 不会被当注释）

label start              # 标签：跳转目标
chapter 序章 · 新学期     # 设置章节名（显示在存档槽上）

bg classroom fade=0.8            # 背景
bgm daily volume=0.7 fade=1.5    # 背景音乐
se bell                          # 音效

show alice expr=normal at=left fade=0.5   # 显示立绘
alice: 早上好。                            # 对白
alice@smile: 又是游戏。                    # 对白 + 同时切表情
narr 四月的风从半开的窗户灌进来。            # 旁白
"也可以直接写引号旁白。"                     # 旁白（另一种写法）

hide bob fade=0.4      # 隐藏立绘
move alice center fade=0.6   # 移动立绘
expr alice angry       # 只换表情
clear                  # 清空背景与全部立绘
wait 0.6               # 等待 0.6 秒
wait_click             # 等待玩家点击
```

### 4.2 选项

```gvs
choice
    "「游戏也是艺术。」" -> defend_games
    "「……我错了。」"    -> admit_fault
end
```

### 4.3 条件

```gvs
if affection alice >= 10
    alice@smile: ……不过，你今天倒是挺老实的。
elif affection alice >= 0
    alice@normal: 算了。
else
    alice@angry: 哼。
end

if flag rhythm_qte_cleared     # 裸标识符等价于 flag <名字>
    ...
end

if not flag talked_to_alice
    ...
end

if var stance == "yield"
    ...
end
```

### 4.4 状态与跳转

```gvs
set var hp 10           # 也接受 set hp 10
add var hp 5            # 也接受 add hp 5
sub var hp 3            # 也接受 sub hp 3
flag talked_to_alice    # 点亮旗标（可写 flag xxx false 熄灭）
affection alice 10      # 好感度 +10（可写负数）

jump after_choice                              # 同文件跳转
call common_pause                              # 调用子过程
return                                         # 从子过程返回
jump_file res://data/scripts/chapter1.gvs chapter1_start   # 跨文件跳转
```

### 4.5 小游戏与结局

```gvs
minigame rhythm_qte rounds=5 need=3 speed=1.5
ending good "并肩的归途"
```

### 4.6 完整指令表

| 指令 | 语法 | 说明 |
|---|---|---|
| `label` | `label <名字>` | 定义跳转目标 |
| `chapter` | `chapter <标题>` | 设置章节名，显示在存档槽 |
| `jump` / `goto` | `jump <标签>` | 无条件跳转 |
| `call` / `return` | `call <标签>` / `return` | 子过程调用与返回 |
| `jump_file` | `jump_file <路径> [标签]` | 切换剧本文件 |
| `bg` | `bg <id> [type=] [fade=]` | 切换背景，`type` 见转场表 |
| `show` | `show <角色> [expr=] [at=left\|center\|right] [type=] [fade=]` | 显示立绘，`type` 见滑入表 |
| `hide` | `hide <角色> [type=] [fade=]` | 隐藏立绘 |
| `move` | `move <角色> <位置> [duration=] [ease=]` | 移动立绘 |
| `expr` | `expr <角色> <表情> [fade=]` | 只换表情（shader 交叉混合） |
| `hop` | `hop <角色> [height=] [times=] [duration=]` | 原地小跳 |
| `zoom` | `zoom <角色> <倍数> [duration=] [ease=]` | 靠近 / 远离（以脚底为轴缩放） |
| `shake` | `shake <角色> [strength=] [times=] [duration=]` | 立绘抖动 |
| `screen_shake` | `screen_shake [strength=] [times=] [duration=]` | 全屏震动（舞台与 UI 一起抖） |
| `screen_flash` | `screen_flash [color=] [duration=]` | 全屏闪光 |
| `screen_fx` | `screen_fx <种类\|none> [strength=] [duration=]` | 全屏后处理：错乱 / 扭曲 / 马赛克 / 色差 / 反色 / 模糊（**连 UI 一起变形**） |
| `bg_motion` | `bg_motion [scale=] [x=] [y=] [duration=] [ease=]` | 背景缓慢推拉运镜 |
| `weather` | `weather <none\|rain\|snow\|sakura> [intensity=]` | 天气粒子 |
| `clear` | `clear` | 清空背景与立绘 |
| `cg` | `cg <id> [fade=]` | 全屏展示 CG **并计入收藏** |
| `hide_cg` | `hide_cg [fade=]` | 收起 CG |
| `unlock` | `unlock <类型> <id>` | 只解锁收藏，不改画面（用于隐藏要素） |
| `bgm` | `bgm <id>\|stop [volume=] [fade=]` | 背景音乐（播放时自动解锁该曲目） |
| `se` | `se <id> [volume=]` | 音效 |
| `voice` | `voice <id> [volume=]` | 语音，写在台词**前**，播完点名字牌可重播 |
| `wait` | `wait <秒>` | 计时等待 |
| `wait_click` / `pause` | — | 等待点击 |
| `set` | `set [var] <变量> <值>` | 赋值（值支持 int/float/bool/null/字符串） |
| `add` / `sub` | `add [var] <变量> <数值>` | 数值增减 |
| `flag` | `flag <名字> [true\|false]` | 设置旗标 |
| `affection` | `affection <角色> <增减值>` | 好感度增减 |
| `if` / `elif` / `else` / `end` | `if <条件>` | 条件块 |
| `choice` … `end` | `choice` + `"文本" -> 标签` | 选项块 |
| `minigame` | `minigame <id> [k=v ...]` | 调用小游戏 |
| `ending` | `ending <id> [标题]` | 结局，终止剧本 |
| `narr` / `narration` | `narr <文本>` | 旁白 |
| `<角色>: <文本>` | — | 对白 |
| `<角色>@<表情>: <文本>` | — | 对白并切表情 |
| `"<文本>"` | — | 旁白 |

**条件表达式**：`flag <名>` / `not flag <名>` / `affection <角色> <比较符> <值>` / `var <变量> <比较符> <值>`
比较符：`== != > < >= <=`。两侧都能解析成数字时按数值比较，否则按字符串比较。

---

## 五、核心模块

### 5.1 GvsParser（编译式解析器）

`scripts/core/gvs_parser.gd` · 静态方法 `parse(text, source_name) -> Dictionary`

两遍处理：
1. **逐行编译**：维护一个块栈，把 `if/elif/else/end` 和 `choice/end` 编译成 `branch_false` / `jump` 指令；未解析的标签引用先记进 `pending`。
2. **回填标签**：标签表建好后，把所有 `pending` 里的跳转目标填成指令下标。

返回 `{ok, commands, labels, errors}`。**任何未定义标签、未闭合块都会进 `errors`**，调用方据此拒绝加载剧本——不会带着半截控制流跑起来。

### 5.2 ScriptRunner（指令流状态机）

`scripts/core/script_runner.gd`

```
状态：IDLE → RUNNING → {WAITING_SAY | WAITING_CHOICE | WAITING_TIMER
                        | WAITING_CLICK | WAITING_MINIGAME} → ENDED
```

- `_step()`：`while _state == RUNNING` 循环取指令执行，直到撞上阻塞型指令
- 阻塞型指令把状态切到等待态，等外部调用 `advance()` / `submit_choice()` / `submit_minigame()`
- `wait` 用 `Time.get_ticks_msec()` 时间戳驱动（不是累加 delta），保证暂停/跳过不会错乱
- `get_state()` / `restore_state()` 支持存档

**存档指针的关键细节**：处于阻塞态时 `_ip` 已经越过了当前指令，所以 `get_state()` 会返回 `_ip - 1`。读档后重新执行那条指令，就能精确复现当时的那句对白或那个选项。

### 5.3 GameManager（软状态）

`scripts/autoload/game_manager.gd` — 旗标 `Dictionary`、好感度 `Dictionary`、剧本变量 `Dictionary`、游戏时长。

两个细节：
- `add_var` 会在变量不存在时以 0 为起点，剧本里不用先初始化
- `from_dict` 会做 `_normalize_value`：JSON 把整数读回来是 float，这里还原成 int，否则界面会显示 `2.0`

### 5.4 SaveManager（纯存储层）

`scripts/autoload/save_manager.gd` — 它不认识 runner / stage / game，只负责把 `main.gd` 组装好的 payload 写进 `user://saves/`。

- 槽位 0 = 自动存档，1..6 = 手动存档
- `get_slot_info()` 返回轻量摘要，存档界面不用解析整个存档
- **自动存档在每句对白后刷新**（`main.gd._on_say` 里调 `_autosave()`）。
  这样「继续游戏」才能精确回到玩家离开时那一句。
  只在选项处存是不够的——那样「继续游戏」永远只能跳回上一个选项，
  玩家在选项之后读的整段内容都会丢失。
  payload 里 backlog 只保留最后 60 条，单文件约 3~5 KB，每句写一次的开销可忽略。
- **写操作都要过一次确认**（在 `SaveLoadPanel` 里，不在这一层）：
  覆盖已占用的槽位、删除存档都要先问一句。存档是玩家几十小时的进度，
  误点一下就没了，这是最不该图快的地方。
- **自动存档槽只可读、不可手动写入**：它归系统管，手动写进去也会被
  下一句的自动存档冲掉，写它只会骗自己。

### 5.5 AudioManager（静默降级）

`scripts/autoload/audio_manager.gd`

**素材缺失时静默跳过**——这是骨架能空目录跑起来的前提。按 `ogg → mp3 → wav` 顺序查找，找不到就只在控制台提示一次，返回 null，不影响流程。BGM 用 Tween 做淡入淡出；SE 用 6 路播放器池轮转，避免连点音效互相打断。

**BGM 必须循环**。它的「循环」不是引擎默认打开的：`AudioStreamOggVorbis` /
`AudioStreamMP3` 的字段叫 `loop`，`AudioStreamWAV` 叫 `loop_mode`（枚举）。
素材缺失时这个问题完全看不出来，一放进真实曲子才会发现「播完一遍就静音了」。
所以 `enable_stream_loop()` 按**属性探测**而不是写死类型。

**语音有队列**。同一句里连写多条 `voice` 时，后写的排在前一条后面依次播完
（`_voice_player.finished` → `_finish_voice()` → 取下一条）。
但玩家推进到下一句时**立刻打断并清空队列**——旧语音拖到新台词上会声画错位，
玩家听到的是上一句、看到的却是新的一句。
队列里连**已解析好的流**一起存，而不是只存 id 到时候再查一次。

**没有素材的语音会被静默跳过**，且不占队列位置、不打断正在播的那条 ——
否则「缺一条素材」会连带把正常语音也掐掉。

### 5.6 ConfigManager（设置）

`scripts/autoload/config_manager.gd` — 设置项集中在 `DEFAULTS` 表里，任何 `set_value()` 都会发 `config_changed` 信号，AudioManager 订阅后实时改音量，不需要重启。

### 5.7 Stage（演出层）

`scripts/stage/stage.gd`

- 背景用两个 `TextureRect` 做 crossfade（A 显示 / B 淡入 / 完成后 B 转正）
- 立绘坐标由 `POSITION_RATIOS`（left 0.22 / center 0.5 / right 0.78）算出，基于 1920×1080 设计分辨率
- **每一路动画都保存 Tween 引用，新指令到来先 kill 旧的**——这是防止快速连点把立绘卡在半透明状态的关键
- `get_state()` / `restore_state()` 保存背景 id 与全部可见立绘（角色 / 表情 / 位置）

### 5.8 UI 层

| 脚本 | 关键点 |
|---|---|
| `dialogue_box.gd` | 打字机由时间戳驱动：记开始毫秒数，每帧用 `已流逝时间 × 速度` 反算应显示到第几个字 |
| `choice_panel.gd` | 按钮完全由代码生成，剧本几条分支就几个按钮 |
| `backlog_panel.gd` | RichTextLabel + BBCode 上色；打开后等两帧布局完成再滚到底部 |
| `settings_panel.gd` | 全部控件由 `SLIDERS` / `TOGGLES` 表驱动生成，加设置项只需加一行 |
| `save_load_panel.gd` | 同一面板两种模式；读取模式下空槽位禁用 |
| `title_screen.gd` | 开始 / 继续 / 读取存档 / 鉴赏 / 设置 / 退出。有存档时才点亮「继续游戏」和「读取存档」 |
| `gallery_panel.gd` | 鉴赏主面板，CG / 音乐两个页签；卡片按注册表运行时生成 |
| `cg_viewer.gd` | CG 全屏详情 + 重播入口（未配置 replay 时置灰并说明） |
| `music_panel.gd` | 曲目列表（当前曲目高亮）+ 播放控制 + 可视化宿主 |
| `record_disc.gd` | 程序化绘制的旋转唱片 |
| `spectrum_bars.gd` | 跳动的频谱条（读 BGM 总线上的频谱分析器） |
| `lock_icon.gd` | 程序化绘制的锁图标 |
| `ui_theme.gd` | 视觉规范集中地：调色板 + StyleBox 工厂 + 按钮/标签样式 |

### 5.9 小游戏系统

`minigame_base.gd` 定义契约：

```gdscript
extends MinigameBase            # 继承
func _on_setup() -> void        # 读取 params
func _on_start() -> void        # 开始
finish({"success": true, "score": 5, "max": 5})   # 结束
```

主流程侧：`main.gd._on_minigame_requested` → 从 `MinigameRegistry` 取场景 → 实例化到 `MinigameLayer` → 连接 `minigame_finished` → 回调 `runner.submit_minigame(result)`。

结果会自动写入变量 `minigame_success` / `minigame_score` / `minigame_max`，成功时点亮旗标 `<id>_cleared`，剧本里直接 `if flag rhythm_qte_cleared` 就能分支。

**新增小游戏只要两步**：写好场景（继承 `MinigameBase`）+ 在 `minigame_registry.gd` 的 `REGISTRY` 里加一行映射。主流程一行都不用改。

内置示例 `rhythm_qte.gd`：指针在横条上往返扫动，玩家在指针进入绿色判定区时按下空格/回车/左键。参数 `rounds=5 need=3 speed=1.5`。

### 5.10 收藏品与鉴赏系统

四个部件，职责严格分离：

| 部件 | 职责 |
|---|---|
| `data/collection/*.json` | 声明「有哪些可收集项」——id、标题、贴图、提示文案、重播配置 |
| `CollectionRegistry` | 读注册表 + 缓存（纯静态，不持有状态） |
| `CollectionManager`（Autoload） | 只管「解锁了没有」，落盘 `user://collection.json` |
| `GalleryPanel` / `CgViewer` / `MusicPanel` | 纯展示，数据全部来自上面两者 |

**收藏进度独立于存档**。落盘到 `user://collection.json` 而不是存档里 —— 玩家重开新游戏不该丢掉已看过的 CG，这是 galgame 的惯例。

**解锁的三个来源**：

1. 剧本 `cg <id>` —— 展示 CG 的同时解锁
2. 剧本 `bgm <id>` —— AudioManager 播放时通知解锁（语义是「到达了会播放这首曲子的剧情点」，所以即使当前没有音频文件也照样解锁）
3. 剧本 `unlock <类型> <id>` —— 手动解锁隐藏要素

**剧情重播（Scene Replay）**

注册表里每条 CG 可以带一段 `replay`：

```json
"replay": {
  "file": "res://data/scripts/prologue.gvs",
  "label": "cg_rooftop",
  "end_label": "cg_rooftop_end"
}
```

剧本里用成对标签把可重播的那段包起来。`ScriptRunner.start_replay(file, start, end)` 会只跑 `[start, end)` 这一段，跑到 `end_label` 就自动收尾。

三个必须处理的问题：

1. **不能污染玩家进度**。片段里可能也有 `set` / `affection` / `cg`。做法是重播前把 `GameManager` + `Stage` + 回看记录整份快照下来，结束后原样还原。
2. **不能写自动存档**。否则会把玩家真实进度覆盖成片段里的位置。用 `_autosave_enabled` 闸住。
3. **`call` 会破坏终止判定**。片段里可能 `call` 一个定义在终点之后的子过程，那时 `_ip` 会跳到终点之后 —— 所以终止条件必须加 `_call_stack.is_empty()` 守卫，否则子过程会被误判成「已经播完」。

**可视化（唱片 / 频谱）**

`AudioManager` 给 BGM 建了一条独立总线并挂上 `AudioEffectSpectrumAnalyzer`，`SpectrumBars` 通过 `get_magnitude_for_frequency_range()` 分频段读取幅度。

配置项 `visualizer.mode` 支持 `disc` / `spectrum` / `both` / `none`：

- `disc` —— 旋转唱片。唱片主体与纹路是旋转对称的，光靠它们看不出在转，所以标签上画了一个**偏心标记**
- `spectrum` —— 跳动的频谱条
- `both` —— 频谱铺底 + 唱片居中

没有音频在播时（骨架阶段没有素材）频谱会退化成一条缓慢起伏的**呼吸波**，而不是死平的一条线。

### 5.11 界面自定义

界面的全部视觉参数都在两个 JSON 里，**代码中没有任何写死的视觉常量**：

| 文件 | 管什么 |
|---|---|
| `data/ui/ui_theme.json` | 全局：配色、字体、按钮预设（尺寸 / 圆角 / 内边距 / 九宫格贴图）、面板圆角、对话框位置 |
| `data/ui/gallery_theme.json` | 鉴赏界面专属：CG 卡片尺寸与列数、可视化模式、鉴赏文案 |

两个都由对应的静态类加载（`UiTheme` / `GalleryTheme`），并且都做了**深合并** —— 配置文件可以只写你关心的那几个键，其余自动用内置默认值。

```json
// ui_theme.json
{
  "palette":    { "accent": "#7f77dd", "text": "#ece9ff", "speaker": "#f1c774", ... },
  "fonts":      { "body": "res://assets/fonts/main.ttf", "title": "", "dialogue": "" },
  "font_sizes": { "title": 78, "dialogue": 30, "speaker": 26, "button": 24, ... },
  "buttons":    { "title": { "width": 340, "height": 68, "texture": "", "texture_margin": 14 }, ... },
  "panels":     { "default": { "radius": 16, "border_width": 1 }, ... },
  "dialogue":   { "offset_left": 130, "offset_top": -320, "pad_h": 46, "pad_v": 30, ... }
}
```

**加载时机很关键**：`UiTheme.reload()` 在 `ConfigManager._ready()` 里调用。Autoload 的 `_ready` 早于主场景实例化，而子节点的 `_ready` 又早于父节点 —— 如果在 `Main._ready` 里加载，所有界面早就用默认值把自己画完了。这是唯一能保证调色板生效的位置。

**字体**：`install_global_font()` 往根 Window 的 `theme.default_font` 装一次，全局生效；各处的 `add_theme_font_size_override` 仍然管字号，两者不冲突。字体文件缺失只打警告并回退到内置字体，不会崩。

**按钮九宫格**：`apply_button(btn, preset)` 先看预设有没有 `texture`。有就用 `StyleBoxTexture`（按 `texture_margin` 切九宫格），没有就用程序化的 `StyleBoxFlat`。只配一张贴图时，hover / pressed / disabled 用 `modulate_color` 做色调区分，不必画四张。这延续了项目一贯的「有真素材就用，没有就用占位」策略。

**按钮位置不放进配置** —— 位置是布局而非样式，放在 `main.tscn` 里用编辑器拖最直观。唯一例外是对话框，因为它的位置需要在不同分辨率下由代码统一应用，所以放进了 `dialogue` 段。

**按钮音效自动挂载**：`apply_button()` 里顺带调用 `attach_button_sfx()`，所以只要按钮走了这个入口就自带点击/悬停音效，**不需要在每个 `pressed.connect` 旁边再写一行 `play_se`**。三个设计点：

1. **用 `button_down` 而不是 `pressed`** —— 按下的瞬间出声比松开时更跟手。
2. **用 `set_meta` 防重复挂** —— 同一个按钮被 `apply_button` 调用多次（换皮、重新应用预设）不会变成一声响两下。
3. **禁用状态静音** —— 回调里检查 `btn.disabled`；`mouse_entered` 在禁用按钮上仍会触发，必须挡掉。

音效 id 与音量走 `audio` 段，按钮预设可用 `sfx_click` / `sfx_hover` 单独覆盖，或写 `"sfx": false` 让这类按钮静音。文件缺失时 `AudioManager.play_se` 静默跳过 —— 删素材不会让按钮报错。

自己搭样式盒的按钮（曲目列表）手动加一行 `UiTheme.attach_button_sfx(btn, "track")` 即可。

### 5.12 文字特效与打字节奏

两个独立的机制，可以混用：

**（一）文字特效 —— 交给 `RichTextLabel`**

`[shake]` `[wave]` `[rainbow]` `[fade]` `[pulse]` `[tornado]` `[flip]` 是 **Godot 内置**的 BBCode 效果，开箱即用。项目另外实现了三个（`scripts/ui/text_effects/`）：

| 效果 | 实现要点 |
|---|---|
| `[bounce]` | `abs(sin(t·speed + idx·0.55))` 做垂直位移 —— 用 `abs` 才有「触底回弹」的弹跳感，普通正弦只是上下摆 |
| `[glitch]` | **确定性哈希噪声 + 时间片**，不是逐帧 `randf()`。逐帧随机会让字抖到完全没法阅读；按 `rate` 分片跳变才像数字故障 |
| `[blink]` | 只改 `color.a`，不动位置（位置交给 `[bounce]` / `[shake]`）；相邻字符错开相位，避免整段同时亮灭像闪屏 |

挂载方式：`_text_label.custom_effects = [BounceEffect.new(), ...]`。

> **Godot 4.7 的坑**：`CharFXTransform` 只有 `relative_index`，旧版文档里的 `absolute_index` / `character` **已经不存在**了（赋值会报 `Invalid access`）。查证方法：`fx.get_property_list()` 打印一遍。

**（二）打字节奏 —— 自己编译时间轴**

原来的实现是「已流逝时间 × 速度」直接算显示到第几个字。这个式子只能线性推进，**没法在某处停顿、某段加速**。

改成两步：`TypingTimeline.build(text, cps)` 把带标记的文本编译成「每个可见字符在第几秒出现」的时间轴，播放时用二分查表。

```
"前[wait=0.5]后"  →  display="前后",  times=[0.1, 0.6]
"慢[speed=2]快快[/speed]" → display="慢快快", times=[0.1, 0.15, 0.2]
```

四个必须处理的点：

1. **节奏标记要从显示文本里剥掉**。`RichTextLabel` 对未知 BBCode 会**原样输出**，不剥离的话对话框里会出现 `[wait=0.5]` 字样。
2. **剥离后可见字符数与时间轴长度必然一致** —— 因为节奏标记本来就不产生可见字符。这条不变式是整段逻辑的基础。
3. **单字等待要有上限**（0.35s），否则 `[speed=0.001]` 会把节奏拖死。
4. **时间轴用 `PackedFloat64Array` 而不是 `Float32`**。float32 存不下 `0.1`（实际是 0.10000000149），会让「到首字时刻」的判定失败、字符晚一帧出现。这个是写测试时才暴露出来的。

用二分而不是每帧线性扫描，长文本（200+ 字）也不会成为每帧的开销。

**凡是要把台词渲染成静态文字的地方，都得先剥标记** —— 对话框只是其中之一。
回看面板与存档预览最初漏了这一步，玩家会看到
`alice: 明天，[speed=2.5]要不要一起走？[/speed]` 这种东西（截图对比时一眼看到）。

两处的剥法还不一样，因为**控件类型不同**：

| 位置 | 控件 | 剥法 |
|---|---|---|
| 对话框 | `RichTextLabel`（挂了自定义特效） | `TypingTimeline.build()` 的 `display`，只剥节奏标记 |
| 回看面板 | `RichTextLabel`（同样挂特效） | `TypingTimeline.strip()`，同上 |
| 存档预览 | 普通 `Label`（**不解析 BBCode**） | 标签全部丢掉，一个都不留 |

回看面板还要额外做两件事：给每个标签挂上那三个自定义特效（否则 `[bounce]` 会因为
「未知标签」漏成文本），以及整页共用同一组特效实例 —— 三个特效都是无状态的
（只存了一个 `bbcode` 名字），没必要每行都 `new` 一遍。

存档预览的控件是 `Label`，所以 `[color=#f00]` 这类标准 BBCode 也会漏出来，
必须全剥 —— 这也是它不能复用 `TypingTimeline.strip()` 的原因。

### 5.13 立绘与画面动效

**World 层的引入**。原来所有舞台元素直接挂在 `Stage` 下。要让「整个画面震动」，最直接的想法是震 `Stage` 自己 —— 但 `Stage` 是 full-rect 锚点节点，`position` 会被布局系统覆盖（和 §五.3 那条同一个坑）。

所以加了一个中间层：

```
Stage (Control, full-rect 锚点)
└── World (Control, size=DESIGN)      ← 震它 = 震整个画面
    ├── BgA / BgB
    ├── CharRoot
    └── CgRect
```

`World` 是普通 Control（手动设 `size`，不参与布局），所以改 `position` 是有效的。闪光层 `Flash` 加在 `World` **之后**，所以盖在整个画面之上。

**缓动**。`move_char` 原本是裸 Tween，也就是线性位移 —— 看起来像电梯。加了 `apply_ease()` 把名字映射到 `trans`/`ease` 组合，**默认 `out_cubic`**。共 11 个预设（linear / in|out|in_out × quad|cubic|quart / out_back / out_elastic / out_bounce）。

**立绘动效的三个细节**：

1. **缩放 pivot 放在脚底中心**（`pivot_offset = Vector2(w/2, h)`）。放大的时候脚不动、往上长，这才是「靠近」；pivot 在左上角会整体往右下漂。
2. **跳跃的上升段 EASE_OUT、下落段 EASE_IN**。这是抛物线的物理感，两段都用 linear 会像坐电梯。
3. **动效被打断后从基准位重启**。`char_jump` / `char_shake` 开头都会先把 `position` 归到 `_char_position(at)` —— 否则上一次动画被 kill 在半空时，下一次会从半空续跳。

**状态复位**。`clear()` 会复位 `World.position`、立绘 `scale`、闪光 alpha。`hide_char()` 完成时也会把 `scale` 归 1 —— 否则放大过的角色再次出场还是放大的。这两条都是「读档 / 重播后画面残留」的来源。

**顺带修掉的一个解析器 bug**：`strip_comment()` 原本遇到任何 `#` 就截断，导致 `screen_flash color=#ff0000` 里的颜色被吃掉。改成**只在行首或前面是空白时**才算注释开始。这条对写十六进制颜色是必需的。

**「只震舞台等于没震」—— 一个被实测推翻的初版设计**。

初版 `screen_shake` 只震 `World`，幅度默认 18px。实测峰值 14.2px、占画布宽 **0.74%**，截图对比几乎看不出差别。原因不是幅度公式写错，而是：

> **背景是铺满画面的渐变，整体平移它没有参照物。**

纯色 / 渐变背景平移 20px 和没动一样；只有**有明确边界的东西**（立绘、对话框、HUD）位移才看得出来。

所以最终方案是**两层一起震**：

| 层 | 怎么震 | 实测峰值 |
|---|---|---|
| 舞台（`World`） | `Stage.screen_shake()` 改 `_world.position` | 24~33 px |
| UI（`UILayer`） | `main.gd._shake_ui()` 改 `CanvasLayer.offset` | 36~56 px |

UI 用 `CanvasLayer.offset` 而不是动子节点：`offset` 只影响渲染位置，不污染各面板自己的坐标，震完复位没有副作用（代价是震动期间点击热区跟着偏，可接受）。

**另一个被实测抓出来的问题**：抖动偏移原本是「各轴独立随机」——

```gdscript
Vector2(randf_range(-s, s), randf_range(-s, s) * 0.5)
```

这经常抽出**接近零的向量**（两个分量恰好都很小），实测峰值只有设定值的 35%，看起来像没动。改成极坐标：

```gdscript
static func shake_offset(magnitude: float) -> Vector2:
	var angle := randf() * TAU
	var scaled := magnitude * randf_range(0.65, 1.0)   # 幅度始终 65%~100%
	return Vector2(cos(angle), sin(angle) * 0.55) * scaled
```

方向随机、幅度有下限，再也不会「抖了个寂寞」。

诊断工具 `tools/fx_diag.tscn` 会打印实测峰值并把「静止 / 震动中」两帧拼成对比图 —— 调幅度时用它比反复跑游戏快得多。

### 5.14 玩家便利功能

**跳过已读**。`ReadTracker`（Autoload）记录玩家看过的每句台词，跳过键遇到未读内容就自动停下。

键用**台词内容的 hash**，不用「文件 + 行号」：改剧本、插删行都不会让记录错位。代价是两处一模一样的台词会被当成同一处 —— 对跳过来说这个误差无害。

数据存 `user://read_text.json`，**和存档分离**：已读是「这台机器上的记忆」，不该跟着某个存档槽走（读旧档不应该让新剧情变成已读）。

落盘时机：不每句都写文件，而是搭在自动存档上顺带 flush（`ReadTracker.save_now()`），外加关窗时兜底。

**已读率必须限定在「当前剧本」里数（`read_count_of()`）**。这是个容易写错的口径问题：

| 方法 | 统计范围 |
|---|---|
| `read_count()` | **全局**去重计数 —— 跨存档、跨剧本版本，连测试随手标的探针句子都算 |
| `read_count_of(texts)` | 只在给定的一批台词里数 |

分母（`ScriptStats.total_lines()`）是当前剧本的台词数，分子如果直接用 `read_count()`，
就会显示出「**已读 150 / 62 句**」这种分子大于分母的结果 —— 而且 `minf(1.0, ...)` 那层
钳位会把它悄悄变成「100%」，看起来还挺正常，所以这个 bug 挂了一阵子没人报。

已读率走 `RecordsPanel.read_progress()` 这一个出口。收藏进度（`CollectionManager.get_progress`）
本来就是对的 —— 它在注册表条目里数，分子天然不会超过分母。

**存档缩略图**。存成**独立 PNG**（`user://saves/slot_01.png`）而不是塞进 JSON：

- 存档 JSON 保持可读、可手改
- 不会因为图片膨胀到几百 KB
- 删除存档时一并删图，不留孤儿文件

三个坑：

1. **抓图前必须把存档面板藏起来**，否则拍进去的是面板自己。而且要**等两帧**再抓 —— 只等一帧可能那帧已经把面板画进去了。
2. **抓图是 GPU→CPU 回读，很贵**。自动存档的缩略图有 15 秒节流，不能每句都抓。`_last_thumb_ms` 初值取负值，让第一次自动存档也能抓到。
3. **抓之前要等 0.6 秒**。刚切场景时背景还在淡入，立刻抓下来是一片黑。先更新时间戳再 `await`，这样连点快进时不会堆起一堆并发抓图。

**槽位行的布局**。按钮的 `text` 多行对齐不可控，所以按钮只当「整行可点」的容器 + 背景，文字交给子节点：

```
HBoxContainer
├── Button (自适应宽 x 104，text 留空)
│   ├── TextureRect   (锚点 CENTER_LEFT，mouse_filter = IGNORE)
│   └── VBoxContainer (锚点 FULL_RECT + 左边距，两行 Label)
└── Button (96 x 104，删除) — 只在该槽有存档时可用
```

三个要点：子节点用**锚点**而不是绝对坐标（按钮的真实尺寸要等容器布局完才定）；子节点设 `mouse_filter = IGNORE` 让点击穿透到按钮，这样点图片也能触发、hover 高亮是整行一起亮；**删除按钮排在主按钮外面**而不是塞进去当子节点 —— 按钮套按钮时内层点击很容易被外层吞掉，分开排最省心。

**确认弹层**做在面板内部（`CenterContainer` + `PanelContainer`，盖住槽位列表），而不是弹独立窗口 —— 独立窗口要处理暂停与焦点回传，这里只是一句话加两个按钮。要执行的动作存成 `Callable`，而不是给每种操作写一个 `if` 分支。

**已读文本变暗**。`ReadTracker` 本来只服务于「跳过已读」，同一个信息顺手能让重看的台词压暗，玩家一眼看出哪些读过。默认关闭，在设置里开。

实现上只改 `RichTextLabel` 的**默认字色**，不去给文本包一层 `[color]` —— 包起来会跟剧本里已有的颜色标记、自定义特效打架（[`rainbow`] 这类就是靠 shader 改 COLOR 的）。

这里有个**顺序坑**：`_on_say` 是「先 `mark_read`、再 `show_line`」。如果 `show_line` 自己去查 `ReadTracker`，查到的永远是「已读」—— 于是每一句（包括第一次看到的那句）都会被压暗。所以「这句以前看过没有」必须由 `_on_say` 在标记**之前**问出来，作为参数传进 `show_line`。

### 5.15 转场遮罩 / 滑入滑出 / 多立绘协同

**转场遮罩**。原来的背景转场只是两张 `TextureRect` 交叉改 `modulate.a` —— 这个做法做不出「溶解」「擦除」这类**有形状**的过渡。

改成 shader 遮罩（`shaders/transition.gdshader`）：把 `progress` 从 0 推到 1，上层图按不同图案显现。四种模式：

| mode | 图案 | 关键式子 |
|---|---|---|
| 0 溶解 | 噪声阈值 | `smoothstep(hash(floor(UV*density)) ± softness, progress)` |
| 1 擦除 | 左→右扫 | `smoothstep(UV.x ± softness, progress)` |
| 2 百叶窗 | 叶片展开 | `smoothstep(fract(UV.y*density) ± softness, progress)` |
| 3 圆形 | 中心扩散 | `1 - smoothstep(radius ± softness, distance(UV, 0.5))` |

四个式子都满足同一个边界条件：`progress=0` 时 mask 恒 0、`progress=1` 时恒 1。**这个不变式是判断式子写没写对的标准** —— 否则转场结束会留下一条没显现的边。

`fade` 不走遮罩（`transition_mode` 返回 -1），继续用 alpha 交叉淡入。两条路径的差别只在「显现与否由谁决定」：fade 交给 `modulate.a`，遮罩交给 shader 的 mask，遮罩路径下 `modulate.a` 直接给满。

退场时遮罩**反向走一遍**（progress 从 1 推回 0），这样 CG 淡出也是同样的图案。

`density` 的取值影响观感：12 在 1080p 上每块 160px，太粗；**30（约 64px）才接近常见的溶解观感**。这个是抓了演示图对比后调的，不是拍脑袋定的。

**滑入滑出**。`show_char` / `hide_char` 的 `transition` 参数原来只判断 `"none"`，其他一律淡入。加了 `_entry_offset()` 把 `slide_left` / `slide_right` / `slide_up` 映射成屏幕外的起点偏移：

```gdscript
"slide_left":  return Vector2(-CHAR_WIDTH, 0.0)
"slide_right": return Vector2(DESIGN.x, 0.0)
"slide_up":    return Vector2(0.0, DESIGN.y)
```

滑入时 **alpha 直接给满**，不做「边滑边淡入」—— 起点在屏幕外，玩家本来就看不出「突然出现」，加淡入只会显得拖沓。

**多立绘协同**。`focus_speaker()` 在每次 `_on_say` 时自动调用，说话人保持明亮、其他人压暗。

关键约束：**只改 `modulate` 的 rgb，不碰 alpha**。alpha 归淡入淡出管，两边都写同一个 `modulate` 会互相踩（角色淡入到一半被压暗逻辑改成全不透明之类）。所以压暗用独立的 `entry["dim_tween"]` 和 `tween_property(rect, "modulate:r/g/b", ...)`。

旁白（`speaker` 为空）时不做区分，全部恢复明亮 —— 否则旁白时所有立绘都暗着，画面很闷。

压暗程度走 `ui_theme.json` 的 `stage` 段，和其他视觉参数一致。

```json
// gallery_theme.json
{
  "palette":  { "accent": "#7f77dd", "card": "#1c1932", "highlight": "#f1c774", ... },
  "layout":   { "columns": 3, "card_width": 350, "card_ratio": 0.5625, "grid_spacing": 22, ... },
  "text":     { "tab_cg": "CG 鉴赏", "locked_label": "???", "replay_button": "重播剧情", ... },
  "locked_icon": { "size": 58 },
  "visualizer":  { "mode": "both", "disc_radius": 104, "disc_speed": 0.85, "spectrum_bars": 32, ... }
}
```

`GalleryTheme` 会把它与内置默认值**深合并**，所以配置文件可以只写你关心的那几个键 —— 比如只想换主色，就只写 `"palette": {"accent": "#e0603c"}`。

想换皮到什么程度：

| 需求 | 改哪里 |
|---|---|
| 换配色 | `palette.*` |
| 改每行几张 CG | `layout.columns` |
| 改卡片大小 / 圆角 / 间距 | `layout.card_width` / `card_ratio` / `card_radius` / `grid_spacing` |
| 换文案（含多语言） | `text.*` |
| 唱片改频谱 / 都关掉 | `visualizer.mode` = `disc` / `spectrum` / `both` / `none` |
| 换掉整个可视化控件 | 覆写 `music_panel.gd` 的 `_build_visualizer()` |
| 换掉卡片布局 | 覆写 `gallery_panel.gd` 的 `_build_card()` |

面板本身也是运行时按注册表生成的 —— 往 `cg.json` 加一条就多一格，不需要动界面代码。

### 5.16 回滚（Rollback）

`scripts/core/rollback_buffer.gd` 是一个「只存快照与游标」的环形队列，不认识任何节点，
因此能脱离场景单独单测（smoke 第 20 节）。

**记在哪**：`main.gd` 在 `_on_say` 与 `_on_choices` 各记一份。对白与选项是玩家能停下来
做决定的两个点；其余指令（`bg` / `show` / `affection` …）都夹在其间，跟着最近的一格一起还原。

**记什么**：调度器位置（file / ip / call_stack）、软状态（`GameManager.to_dict()`）、
画面（`stage.get_state()`，含晴雨天气）、当前说话人与文本、语音 id、回看记录长度、
以及全屏特效的种类与强度。一份只有几百字节，容量 100 格。

特效单独带一份、而不是塞进 `stage.get_state()`，因为那个形状**存档也要用**，
而特效是瞬时状态、不该跟着存档走（读档进来不该屏幕上还糊着错乱）。
但它必须进回滚快照：往回翻一句就把十行前设的持续特效抹掉，玩家会以为是自己看错了。

**怎么还原**：走和读档**完全相同**的路径 —— `runner.restore_state()` 让调度器重新执行
那条指令，对白 / 选项于是自己重新出现。不为回滚另写一套展示逻辑，两者就不会各自漂移。
还原期间用 `_restoring` 闸门挡住两件事：快照采集（否则历史里全是重复项）与回看记录追加
（`line_logged` 会被重放，不挡就多出一条重复对白）。

**分支截断**：`push()` 在游标不在末尾时先砍掉「未来」那一截。玩家退到选项改选之后，
被放弃的那条支线不会再出现在历史里 —— 否则继续前翻会翻进一条其实没走过的剧情。

**边界**：小游戏进行中、CG 重播中、标题界面一律拒绝回滚；新开局 / 读档 / 回标题 / 进入重播
都会清空历史（这些动作意味着「跳到了别处」，旧历史不再连续）。

**不还原的东西**（见第十二节）：`bg_motion` 的镜头位置会被 `clear()` 复位；天气只还原种类、
不还原强度；正在播的 BGM 不受影响（既不重播也不停止）。

---

### 5.17 全屏特效（ScreenFx）

`scripts/stage/screen_fx.gd` + `shaders/screen_fx.gdshader` + `scripts/core/screen_fx_spec.gd`。

**为什么单独一层排在 UI 之上。** 场景里 `StageLayer` 是 0、`UILayer` 是 10、
`MinigameLayer` 是 20，特效层 `FxLayer` 拿的是 **30**。

这一条是整个功能的关键，而不是随手排的。全屏后处理读的是「**那一刻已经画好的整屏**」，
所以它必须排在它想影响的东西**后面**：

- 排在 `StageLayer` 里（跟 `Stage` 同层）→ 只能读到背景 / 立绘，对话框纹丝不动地浮在
  扭曲的画面外面，像贴纸；
- 排在 UI 之上 → 对话框、HUD、小游戏一起变形，「整个世界不对劲」才成立。

这也是它必须**另起一层**、而不能塞进 `Stage` 的原因：`Stage` 自己就在 0 层里。

**BackBufferCopy 为什么是必须的，且必须紧挨着排在前面。**
`hint_screen_texture` 读的是 back buffer，而 back buffer 由 `BackBufferCopy` 在它**自己的
绘制时刻**填充。放在特效的后面（或做成它的子节点）就太晚了 —— 读到的是一张空图，
结果是整屏变黑。所以 `_ensure_copy()` 建出它之后立刻 `move_child(copy, get_index())`，
把它插到自己前面一位。

**为什么是惰性创建。** 第一版在 `_ready()` 里建，结果报
`Parent node is busy setting up children, add_child() failed` —— 场景实例化时父节点
正忙着装配子节点，此时加兄弟会被拒，紧接着 `move_child()` 还会因为「不是它的子节点」
再报一次。改成首次 `play()` 时（父节点早就装配完了）才建，顺带还有个好处：
**没有特效的时候这个节点根本不存在**，也就没有每帧一次的全屏拷贝开销。
`_sync_visibility()` 是唯一决定可见性的地方，它同时开关 `BackBufferCopy.copy_mode`，
避免出现「看不见但每帧都在全屏拷贝」的层。

**两种语义。** `duration > 0` 是脉冲：15% 时长冲上去（错乱要「啪」地一下），
剩下 85% 用 `EASE_IN` 收干净。`duration <= 0` 是持续，一直挂到显式关闭。
关闭统一走 `screen_fx none`，和 `weather none` 一个写法，不另发明一条 `off`。

**未知种类当场报错。** 解析器对 `screen_fx` 的非法种类**直接报错**，没有沿用 `weather`
那种静默降级成 `none` 的做法。理由：种类是封闭的小集合，写错基本只有「拼错」一种可能，
而静默降级的后果正是本项目最忌讳的那类 bug ——「剧本写了、演出就是不出来」，
只有控制台一行 warning。`tools/audit` 会把它变成 CI 的非零退出码。

**模态面板自动压下。** 特效层在 UI 之上意味着打开设置面板时，玩家正在读的那一屏
会被一起糊掉 —— 那恰恰是最不该糊的。所以 `main.gd` 把各个面板的 `visibility_changed`
统一接到 `_refresh_fx_suspension()`：只要有面板显示就 `set_suspended(true)`（只是不显示，
**强度保留**），全关掉后原样接着演，长镜头不会被打断。
挂信号而不是在每个开关处各写一行 —— 面板的入口太多（按钮 / 快捷键 / 标题界面 / 剧本），
漏一处就是一个「面板糊了」的 bug。

**复位点。** 新开局 / 读档 / 重播结束 / 回标题都会 `clear()`：这些都是「跳到了别处」，
残留一层扭曲会一直糊在新画面上。回滚是例外 —— 它从快照里**原样还原**特效，
而不是清掉。

---

## 六、存档格式

`user://saves/slot_01.json`：

```json
{
  "version": 1,
  "slot": 1,
  "saved_at": "2026-09-30 00:03:21",
  "chapter_title": "第一章 · 春日的答案",
  "preview": "明天，要不要一起走？",
  "speaker": "alice",
  "play_time": 128.4,
  "game": {
    "flags": { "talked_to_alice": true, "rhythm_qte_cleared": true },
    "affection": { "alice": 28 },
    "vars": { "stance": "defend", "chapter": 1 },
    "play_time": 128.4,
    "chapter_title": "第一章 · 春日的答案"
  },
  "runner": {
    "file": "res://data/scripts/prologue.gvs",
    "ip": 42,
    "call_stack": []
  },
  "stage": {
    "bg": "rooftop",
    "chars": [{ "char": "alice", "expr": "smile", "at": "center" }]
  },
  "backlog": [ { "speaker": "alice", "text": "明天，要不要一起走？" } ]
}
```

读档顺序（`main.gd._load_slot`）：`GameManager.from_dict` → `Stage.restore_state` → `runner.restore_state`。最后一步会重新执行 `ip` 指向的那条指令，于是那句对白/那个选项原样重现。

---

## 七、资源约定与占位策略

### 目录约定

```
assets/
├── bg/<id>.png                    背景，1920×1080
├── cg/<id>.png                    CG 事件图，1920×1080
├── sprites/<角色>.png             立绘整图
├── sprites/<角色>/<表情>.png      立绘差分（优先级更高）
├── ui/<名字>.png                  按钮九宫格贴图等 UI 素材
├── fonts/<名字>.ttf|otf           字体
├── audio/bgm/<id>.ogg|mp3|wav
├── audio/se/<id>.ogg|mp3|wav
└── audio/voice/<id>.ogg|mp3|wav
```

### 占位策略

`placeholder_assets.gd` 在找不到真实素材时按 id 生成占位贴图：

- **背景**：`GradientTexture2D`，色相由 `id.hash()` 派生 → 同一个 id 每次颜色一致
- **立绘**：逐扫描线画人形剪影（头 + 脖子 + 梯形躯干），色相由角色 id 派生；胸前一条小色带的颜色由 `角色/表情` 共同决定，所以换表情时肉眼可见

真实素材一旦出现就自动优先使用，**代码零改动**。

---

## 八、目录结构

```
galgame/
├── project.godot                    工程配置（7 个 Autoload、1920×1080 canvas_items 拉伸）
├── icon.svg
├── data/
│   ├── scripts/                     剧本（纯文本，非程序员可改）
│   │   ├── prologue.gvs             序章：演示全部常用指令 + 可重播片段
│   │   └── chapter1.gvs             第一章：演示跨文件跳转与多结局
│   ├── collection/                  收藏品注册表
│   │   ├── cg.json                  有哪些 CG、各自的贴图与重播配置
│   │   └── music.json               有哪些曲目
│   └── ui/
│       ├── ui_theme.json            全局外观（配色 / 字体 / 按钮预设与贴图 / 对话框）
│       └── gallery_theme.json       鉴赏界面外观（配色 / 布局 / 文案 / 可视化）
│   └── i18n/
│       └── en.json                  界面文案翻译表（key 是中文原文）
├── scenes/
│   ├── main.tscn                    唯一主场景（分层结构见下）
│   └── minigames/rhythm_qte.tscn
├── scripts/
│   ├── main.gd                      编排层
│   ├── core/
│   │   ├── gvs_parser.gd            剧本编译器
│   │   ├── script_runner.gd         指令流状态机（含重播模式）
│   │   ├── script_paths.gd          剧本文件位置（含语言子目录解析）的唯一权威
│   │   ├── rollback_buffer.gd       回滚历史缓冲（快照环形队列 + 游标）
│   │   ├── screen_fx_spec.gd        全屏特效种类表（解析器与演出层共用）
│   │   ├── typing_timeline.gd       打字节奏编译器（停顿 / 变速 → 时间轴）
│   │   ├── minigame_registry.gd     小游戏注册表
│   │   ├── collection_registry.gd   收藏品注册表
│   │   ├── gallery_theme.gd         鉴赏界面主题
│   │   ├── json_util.gd             JSON 读写（兼容编辑器与导出版）
│   │   └── placeholder_assets.gd    占位素材生成（背景 / 立绘 / CG）
│   ├── autoload/                    Config / Game / Collection / Audio / Save / ReadTracker
│   ├── stage/stage.gd               演出层（背景 / 立绘 / CG / 转场）
│   ├── stage/screen_fx.gd           全屏特效层（排在 UI 之上）
│   ├── ui/                          对话框 / 选项 / 回看 / 设置 / 存读 / 标题
│   │   │                            / 鉴赏 / CG 详情 / 音乐 / 唱片 / 频谱 / 锁图标 / 主题
│   │   └── text_effects/            自定义文字特效（弹跳 / 错乱 / 闪烁）
│   └── minigames/                   基类 + 节奏 QTE
├── shaders/
│   ├── transition.gdshader          转场遮罩（溶解 / 擦除 / 百叶窗 / 圆形）
│   ├── screen_fx.gdshader           全屏后处理（错乱 / 扭曲 / 马赛克 / 色差 / 反色 / 模糊）
│   └── char_expr.gdshader           立绘表情交叉过渡
└── tools/
    ├── smoke.gd / smoke.tscn        headless 回归测试（643 项断言）
    ├── capture.gd / capture.tscn    自动截图工具（14 张）
    ├── button_compare.tscn          按钮样式前后对比（拼接图）
    ├── text_fx_demo.tscn            文字特效多帧演示（拼接图）
    ├── motion_demo.tscn             立绘缓动位移多帧演示（拼接图）
    └── stage_demo.tscn              转场 / 多立绘演示（拼接图）
```

`main.tscn` 分层：

```
Main (Control)
├── StageLayer  (CanvasLayer, layer=0)   ── Stage 演出层（含 CG 层）
├── UILayer     (CanvasLayer, layer=10)  ── DialogueBox / ChoicePanel / HudBar
│                                           TitleScreen / Backlog / Settings / SaveLoad
│                                           GalleryPanel / CgViewer
└── MinigameLayer (CanvasLayer, layer=20) ── 小游戏运行时挂载点
```

---

## 九、扩展指南

### 加一条新指令

1. `gvs_parser.gd` 的 `KEYWORDS` 加关键字
2. `Builder.feed()` 的 `match` 里加分支，写一个 `_do_xxx()` 生成指令字典
3. `script_runner.gd` 的 `_execute()` 里处理该 `op`

### 加一个小游戏

1. 新建场景，根节点挂继承 `MinigameBase` 的脚本
2. 实现 `_on_setup()` / `_on_start()`，结束时调 `finish(result)`
3. `minigame_registry.gd` 的 `REGISTRY` 加 `"id": "res://scenes/minigames/xxx.tscn"`

### 加一项设置

`settings_panel.gd` 的 `SLIDERS` 或 `TOGGLES` 加一行，同时 `config_manager.gd` 的 `DEFAULTS` 加默认值。界面、持久化、实时生效三件事一起完成。

### 加一张 CG / 一首曲子

1. `data/collection/cg.json`（或 `music.json`）的 `items` 里加一条，写好 `id` / `title` / `hint`
2. 剧本里写 `cg <id>`（音乐则是 `bgm <id>`）
3. 想把这张 CG 做成可重播的：在剧本里加一对标签 `cg_xxx` / `cg_xxx_end` 包住那段剧情，
   然后在注册表的 `replay` 里填上 `file` / `label` / `end_label`

界面会自动多出一格，不需要动任何 UI 代码。

### 接正式美术

把文件按第七节的目录约定丢进 `assets/`，不用改代码。

---

## 十、验证

```bash
# 回归测试 · headless（643 项断言，快，适合 CI）
"D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --headless --path . res://tools/smoke.tscn

# 回归测试 · 窗口模式（648 项，多覆盖「真实输入模拟」一节）
"D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/smoke.tscn

# 自动截图（窗口模式，14 张）
"D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/capture.tscn

# 按钮样式前后对比（窗口模式，出一张拼接图）
"D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/button_compare.tscn

# 文字特效多帧演示（窗口模式，出一张拼接图）
"D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/text_fx_demo.tscn

# 立绘缓动位移多帧演示（帧间距能看出加速）
"D:/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe" --path . res://tools/motion_demo.tscn
```

冒烟测试覆盖：Autoload 注册 → 剧本解析与跳转回填 → **外观配置（配色 / 字号 / 按钮预设 / 九宫格贴图通路 / 未定义预设回退 / 文字颜色覆盖 / 按钮音效挂载与触发链路）** → **文字特效与打字节奏（时间轴编译、停顿、变速、标签剥离、边界与精度、二分查表、特效注册与时间片行为）** → **演出动效（hop / zoom / shake / screen_shake / screen_flash / screen_fx 的解析与行为、缓动生效、被打断后从基准位重启、clear 复位）** → 调度器控制流（if/else、choice、call/return、flag、affection、minigame、ending）→ 存档往返（含 JSON 整数还原）→ 立绘定位 → 序章端到端跑通并断言最终好感度为 44 → 自动播放/跳过的连续性 → 标题读档 → 「继续游戏」恢复精度 → 鉴赏系统（注册表、主题、解锁语义、落盘往返、锁图标数量、曲目高亮、可视化控件）与剧情重播（片段边界、快照还原、自动存档闸门）→ **转场遮罩与滑入滑出（四种转场模式映射、滑入起点在屏幕外、滑入时 alpha 给满、剧本 type 参数解析）** → **多立绘协同（说话人亮 / 他人压暗 / 旁白全亮）** → **玩家便利（已读追踪、跳过已读语义、已读文本变暗、存档删除与覆盖确认、存档缩略图读写与清理、隐藏 UI）** → **回滚（缓冲区边界与分支截断、快照采集、回退 / 前进、退到选项处改选、滚轮输入、设置开关）** → **音频（BGM 循环开关、语音队列的入队 / 接力 / 打断 / 缺素材跳过）** → **标记不外漏（回看 / 存档预览里不得残留 `[wait]` `[speed]`）** → **剧本路径解析（语言回退、逻辑路径不变、非剧本路径放过）** → **全屏特效（种类表与 mode 一一对应、持续 / 脉冲两种语义、层必须排在 UI 之上、BackBufferCopy 恰好在前一位、未知种类被拒且不顶掉当前特效、模态面板自动压下、四个复位点、回滚能还原）** → **着色器静态检查（入口函数不得出现 return）** → **架构守卫（分层规则 + 守卫自检）** → **真实输入模拟** → **指令端到端覆盖（每条指令都真的经调度器跑一遍）**。

**关于「指令端到端覆盖」**：第 18 节针对一类特定 bug —— 解析器认识某条指令、调度器却没给它转发分支。
表现是「剧本写对了，演出就是不出来」，不崩不报错，只有一条 `push_warning`。
`hop / zoom / shake / screen_shake / screen_flash / screen_fx / bg_motion / weather / voice` 九条就曾这样静默失效过。

**关于「着色器静态检查」**：第 22 节针对另一类同样「测试看不见」的 bug —— Godot 的着色语言
不允许在 `fragment()` / `vertex()` 里用 `return`，违反时着色器**编译失败**，但逻辑测试照常全绿，
现象只是「某个过渡效果就是不出来」，很容易被当成没做。`char_expr.gdshader` 就真踩过这个坑
（表情交叉过渡整段失效）。这一节扫 `shaders/` 下每个文件的入口函数体，用词边界匹配查 `return`，
先剥掉 `//` 注释，避免把说明文字误判成语句。

光断言「解析结果正确」抓不到它（当年漏掉正是因为动效测试只查 parser 产出、从不经 runner 执行）。
所以这一节给 `GvsParser.KEYWORDS` 里的每条指令都准备一个最小剧本，用 `ScriptRunner` 真跑一遍，
断言它既没落进未知指令分支（`ScriptRunner.last_unknown_op` 为空），也确实把信号发到了演出层或音频层。
样本表自身的完整性也有断言 —— 新增指令却忘了补样本会直接 FAIL，不会悄悄失效。

**关于「真实输入模拟」**：前面所有测试都是直接调内部方法，绕过了 GUI 层。第 10 节改用真实 `InputEvent` 走完整链路（`push_input` → 视口命中测试 → `_gui_input` → 信号 → 业务逻辑），这是唯一能抓到「按钮被别的控件挡住」「锚点算错位置点不到」「`mouse_filter` 配错」的手段。

它有两个约束，都踩过：
1. **必须窗口模式**。headless 下视口只有 64×64，命中测试不可用（测试会自动跳过并提示）。
2. **`push_input` 收的是窗口坐标，不是画布坐标**。项目用了 `canvas_items` 拉伸（画布 1920×1080 → 窗口 1280×720），直接把 `get_global_rect()` 的结果丢进去会命中错误的目标。正确做法是过一次 `Viewport.get_final_transform()`。

测试会读写 `user://` 下的真实数据，所以开头会把自动存档 / 收藏记录 / 设置整份备份，跑完原样还原 —— 否则跑一次测试就把玩家进度清了。

**为什么冒烟测试要用场景而不是 `--script`**：`--script` 模式下脚本在主循环启动前编译，此时 Autoload 全局标识符尚未注册，会直接编译失败。所以测试脚本必须是 `extends Node` 的场景，用 `res://tools/smoke.tscn` 作为位置参数运行。

---

## 十一、界面本地化（I18n）

`scripts/autoload/i18n.gd`，配置键 `language`，表在 `data/i18n/<语言>.json`。

**key 就是中文原文。** 中文是源语言，不需要自己的表（查不到就返回 key，正好等于原文）；
其它语言只写差异。这样新增文案不用登记 key，缺翻译也只影响那一句，
**绝不会把界面显示成一串 `menu.start`**。没用 Godot 内置 `TranslationServer`：
它的 `.translation` 资源要先导入才能用，改一次文案就得重新导入一遍；这里是纯 JSON，
和 `ui_theme.json` 保持同一种玩法。

界面文字分两类，处理方式不同：

| 类型 | 例子 | 做法 |
|---|---|---|
| 静态文案（写在 `.tscn` 里） | 开始游戏、设置、关闭 | `I18n.apply_tree()` 遍历替换 |
| 代码拼出来的 | 存档 3、已读 12 / 89 句 | 生成处显式调 `I18n.t()`，参数用 `{name}` |
| 内容 | 对白、CG 标题、曲名 | **不翻译**，靠多语言剧本与注册表 |

**最关键的一条：原文必须存进节点元数据。** 静态文案第一次被替换时把原文记进 `i18n_src`，
之后每次切语言都拿**原文**查表。如果拿已翻好的英文去查，表里没有这条 key，
就会原样返回英文 —— 界面永久卡在英文上，而且很难发现。smoke 第 19 节专门守这个。

同理，凡是代码里已经翻译过的动态节点都打了 `i18n_skip` 标记，
否则 `apply_tree` 会把译文当原文再存一遍，下次就翻不回来了。

`apply_tree` 只收 `Button` / `Label` / `CheckBox`：刻意排除了 `RichTextLabel`
（对白框和回看记录都是它，装的是剧本内容）、`LineEdit`（玩家输入）、
`OptionButton`（装的是语言名，本来就该用各自语言显示）。

切语言时主流程做三件事：重新翻译整棵界面树 → 重建设置面板（标签与语言选项都要重来）→
刷新存档面板（槽位名是代码拼的）。

---

## 十二、已知限制与后续路线

| 限制 | 说明 | 建议路线 |
|---|---|---|
| ~~无 rollback~~ **已实现** | 滚轮前后翻历史，还原软状态与画面，退到选项处可改选。设计见 5.16，测试见 smoke 第 20 / 21 节 | — |
| 回滚不还原运镜与 BGM | 快照存背景 / 立绘 / CG / 天气 / 全屏特效；`bg_motion` 的镜头位置会被复位，BGM 不重播也不停 | 需要时把 BGM id 与运镜目标一并纳入快照，并在还原后按目标值重设 |
| 小游戏期间不可回滚 | 小游戏是独立场景，翻历史会打乱它的进度指针，故直接拒绝 | 把「小游戏之前那一句」当作落点，而不是小游戏本身 |
| 界面已 i18n，剧本尚无多语言 | 界面文案走 `data/i18n/`；剧本**路径解析**已经支持语言子目录（`ScriptPaths`），缺的只是译文内容本身 | 在 `data/scripts/<lang>/` 下放同名 `.gvs`（缺哪个回退哪个），`chapters.json` 同理 |
| ~~语音无队列~~ **已实现** | 同句多条 `voice` 依次播完；换句打断并清队列；缺素材静默跳过。见 5.5 与 smoke 第 23 节 | — |
| 自动播放不等待语音 | `_arm_auto_deadline()` 按「文字长度 ÷ 速度」估算停留时间，没有把语音时长算进去 | 让 AudioManager 暴露当前语音剩余时长，自动播放取「两者较大值」 |
| 无右键交互 | 右键目前完全没绑定（galgame 习惯是打开菜单或隐藏 UI） | 加一个右键系统菜单，或至少让右键等价于隐藏 UI |
| 重播片段需自包含 | 片段里的 `if` 按**当前**状态求值，不是「解锁当时」的状态 | 在解锁时把 `GameManager` 快照一起存进收藏记录 |
| 重播片段不宜含选项 | 玩家一旦选择就会跳到片段之外，终点判定随之失效 | 用成对标签只圈线性段落，或让选项分支都 jump 回片段内 |
