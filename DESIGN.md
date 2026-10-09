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
        ▲
        │ 开新周目时把继承数据写回 / 抵达结局时取值
┌───────┴────────────┐  ┌───────────────┐  ┌──────────────┐
│ CycleManager       │  │ CollectionMgr │  │ ReadTracker  │
│ 周目数/通关记录/    │  │ CG/音乐/结局   │  │ 已读文本     │
│ carry 继承数据      │  │ 跨周目保留     │  │ 跨周目保留   │
└────────────────────┘  └───────────────┘  └──────────────┘
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

if cycle >= 2                  # 当前周目数（多周目，见 5.18）
    ...
end

if cleared true_end            # 这个结局通关过没有（跨周目记录）
    ...
end

if not cleared bad
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
| `carry` | `carry <flag\|var\|affection> <名字>` | 标记「下一周目继承它」，取值发生在抵达结局时 |
| `if` / `elif` / `else` / `end` | `if <条件>` | 条件块 |
| `choice` … `end` | `choice` + `"文本" -> 标签` | 选项块 |
| `minigame` | `minigame <id> [k=v ...]` | 调用小游戏 |
| `ending` | `ending <id> [标题]` | 结局，终止剧本 |
| `narr` / `narration` | `narr <文本>` | 旁白 |
| `<角色>: <文本>` | — | 对白 |
| `<角色>@<表情>: <文本>` | — | 对白并切表情 |
| `"<文本>"` | — | 旁白 |

**条件表达式**：`flag <名>` / `not flag <名>` / `affection <角色> <比较符> <值>` / `var <变量> <比较符> <值>`
/ `cycle <比较符> <周目数>` / `cleared <结局id>`（可加 `not`）
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
| `record_disc.gd` | 程序化绘制的旋转唱片（**当前未接线**，音乐鉴赏改版后没有调用方，见 5.10） |
| `spectrum_bars.gd` | 跳动的频谱条，读 BGM 总线上的频谱分析器（同上，未接线） |
| `lock_icon.gd` | 程序化绘制的锁图标 |
| `ui_theme.gd` | 视觉规范集中地：调色板 + StyleBox 工厂 + 按钮/标签样式 |

**面板样式只有一条构造路径**：`UiTheme.apply_panel(node, preset)` → `panel_stylebox(preset)`，
预设在 `data/ui/ui_theme.json` 的 `panels` 段。历史上 `gallery_panel` 与 `cg_viewer`
各自手拼过 `UiTheme.stylebox(...)`，两次都出事：前者把内边距硬编码成 `(0, 0)` 让文字贴边，
后者干脆让面板贴图失效（素材烘焙好了却一直没人用，只能在画程序化圆角矩形）。
`smoke` 现有一条例守「面板上的 stylebox 与预设同源」—— 注意它比的是**类型是否一致**，
不是「必须是贴图」，因为删掉 png 走程序化回退是受支持的行为。

**面板贴图有两套机制，按「尺寸是否恒定」二选一**：

- **九宫格**（`texture_margin` > 0）：四角原样贴、四边单轴拉伸、中心双轴拉伸。
  角和边框粗细不随控件尺寸变，代价是底纹没法平铺（拉伸会糊），而且尺寸各异的面板
  之间圆角半径会各不相同。给 `default` / `card` 这类**尺寸由内容决定**的面板用。
- **整图**（`texture_margin` = 0）：贴图直接铺满控件，1:1 零拉伸。圆角恒为正圆、
  边框粗细恒定、水彩那种不规则边缘也能做（九宫格的规则切边做不到）——
  前提是**控件尺寸恒定**。本项目设计分辨率固定 1920×1080（`canvas_items` + `aspect=keep`），
  面板矩形只是 `anchor + offset` 的算术结果，`backlog` / `save_load` / `records` /
  `gallery` / `cg_viewer` / `settings` 六个窗口都实测过三档窗口尺寸不变，所以能烘焙。

整图的失败模式很隐蔽：**尺寸差几个像素就静默拉伸**，不报错、不 warning，
只有把截图放大才看得出圆角被捏成椭圆、边框变粗。为此 `apply_panel` 挂了一条
`resized` 自检，控件尺寸与贴图像素不等就 `push_warning`（只报一次，避免布局过程中刷屏）。
真值核对仍然靠 `tools/panel_probe.tscn`。

`settings` 是唯一要额外处理的：它没有滚动区，高度原本被 11 行内容撑出来
（静态算 740、实测 798），换语言或改字号就又不样了。现在把 `offset` 钉成
`1000×810`（正好等于烘焙图尺寸），中间插一层 `ScrollContainer` ——
内容再多也只是滚动，不会回头去撑面板。

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
| `GalleryPanel` / `CgViewer` / `MusicPanel` / `VideoViewer` | 纯展示，数据全部来自上面两者 |

**收藏进度独立于存档**。落盘到 `user://collection.json` 而不是存档里 —— 玩家重开新游戏不该丢掉已看过的 CG，这是 galgame 的惯例。

**四类收藏品**：`cg` / `music` / `video` / `endings`，各对应一个 JSON。加一类只要
加一个文件 + 在 `CollectionRegistry.SOURCES` 里加一行。

**解锁的四个来源**：

1. 剧本 `cg <id>` —— 展示 CG 的同时解锁
2. 剧本 `bgm <id>` —— AudioManager 播放时通知解锁（语义是「到达了会播放这首曲子的剧情点」，所以即使当前没有音频文件也照样解锁）
3. 剧本 `video <id>` —— 播放影片时解锁（同上，素材缺失也照样解锁）
4. 剧本 `unlock <类型> <id>` —— 手动解锁隐藏要素

**视频鉴赏（第三个页签）**

与 CG 网格同一套卡片（`GalleryPanel._build_card(item, unlocked, tab)`），点了发
`video_activated` → `main` 打开 `VideoViewer`。

- **页签与网格是代码建的**，没写进 `main.tscn`：加一个页签不值得动场景文件，
  而结构与 CG 页签完全对称，代码里复制一份比手抄 20 行节点更不容易出错。
- `VideoViewer` 也完全由代码搭建（同 `RecordsPanel` 的理由），用
  `AspectRatioContainer(16:9, STRETCH_FIT)` 兜住比例 —— 面板矩形不是 16:9，
  直接铺满会把影片横向拉长。
- 打开时 `pause_bgm()`、关闭时按「原来在响才恢复」的条件 `resume_bgm()` ——
  影片自带音轨，两路声音叠着没法听；但无条件恢复会把玩家自己按的暂停顶掉。
- 素材缺失**不静默黑屏**：提示行直接写「该视频素材缺失」。玩家点了没反应是最糟的体验。
- 影片在鉴赏里**循环播放**（`loop = true`），玩家可以反复看。

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

**音乐播放器（列表 + 播放器卡片）**

左栏是可滚动的曲目列表（当前曲目高亮 + `♪` 前缀），右栏是一张内容高度的播放器卡片：
状态 / 曲名 / 艺术家 / 进度条 / 时间 / 上一首·播放暂停·停止·下一首 / 播放模式。

早期版本右栏放的是「旋转唱片 + 跳动频谱」。唱片有旋转对称的问题（主体和纹路转了也看不出来，
得靠一个偏心标记才看得出在转），频谱又依赖 BGM 总线上那个 `AudioEffectSpectrumAnalyzer` ——
为了一个装饰控件养一条效果器链、还要处理「没素材时的呼吸波」，性价比不高，索性换成纯信息布局。
`AudioManager` 的总线、分析器与 `get_spectrum_magnitudes()` 都保留着，
`record_disc.gd` / `spectrum_bars.gd` 也留在 `scripts/ui/` 下（本身是可复用控件），要接回来随时能接。

**进度条**用 `HSlider`，`max_value` = 当前曲目时长。两个闸门缺一不可：

- `_seeking`（`drag_started` / `drag_ended`）—— 拖手柄时 `_process` 不许回写 `value`，否则手柄被拽回去
- `_syncing` —— 自己回写 `value` 时置起，忽略随之而来的 `value_changed`，否则「刷新进度条」会被当成「用户跳转」递归下去

**播放模式**（列表循环 / 单曲循环 / 随机播放 / 顺序播放）靠 `AudioManager.bgm_finished` 驱动。
那条信号**只在流不循环时触发**，所以鉴赏试听必须 `play_bgm(..., loop = false)`，
而剧本 BGM 一律循环 —— 两边共用 `play_bgm`，用 `loop` 参数分开。
不循环带来的副作用是「试听曲放完就静音」，所以 `main` 在**进鉴赏前记下剧本的 BGM**、
关面板时放回去（`_bgm_before_gallery` + `_preview_started`，没点过试听就完全不碰音频）。

「顺序播放」是**顺着列表往下放到最后一首才停**，不是「只放这一首就停」——
不循环的播放器里它指的是「走得完整张列表，只是不回头」。
`_step_track(step, wrap)` 用 `wrap = false` 表达这个语义：走到尽头返回 false，
由调用方收尾；按钮那条路走默认的 `wrap = true`，手动点「下一首」在末尾绕回第一首。

**`AudioManager.finished` 这里踩了两个引擎坑，都写成了守卫**（smoke 各一条）：

1. **切歌后引擎会补报一次「上一次的结束」。** 切流并 `play()` 之后，新流的 playback
   在 AudioServer 那边还没注册成 active，**下一帧（约 15ms）`finished` 会再报一次**。
   要命的是这次补报的引擎状态和「真的放完」一模一样（`playing = false`、位置归零、
   `get_bgm_length()` 已经是新流的长度），看状态区分不了 —— 唯一可靠的差别是**时间**：
   补报在起播后一帧，而最短的曲子也有 38 秒。不挡就会**连跳两首**
   （现象：列表循环放完「主题曲」直接落到「终曲」）。
2. **不能在 `finished` 里同步换流。** Godot 是在 `NOTIFICATION_INTERNAL_PROCESS` 里发这个
   信号的，在这一刻改 `stream` 再 `play()`，**WAV 那首起不来**（`playing` 恒 false、
   位置停在 0；换成 ogg 或挪到普通帧都正常）。所以信号本身 `call_deferred` 出去。

顺带发现 **WAV 光设 `loop_mode` 不够**：它的循环区间是 `loop_begin` / `loop_end`，
导入时 `edit/loop_mode=0` 的话区间是空的，这时开 `LOOP_FORWARD` 播放会**立刻结束** ——
症状是「这首曲子根本放不出来」且不报错。`enable_stream_loop()` 现在会把空区间补成整段。

这三条都靠 `tools/music_probe.tscn` 的 C 段量出来（用 `seek` 跳到末尾加速，
不然一首要等四十多秒）。

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

**（三）停顿点与「点击跳到停顿处」**

`build()` 除了 `display` / `times`，还返回两个表：

| 键 | 内容 |
|---|---|
| `stops` | 停顿点 `[{index: 可见字符数, gate: 是否需点击}]`，按 index 升序 |
| `events` | 效果器触发点 `[{index, kind, bus, duration, strength, pitch}]` |

- `[wait=0.5]` / `[pause=]` / `[delay=]` → 停顿点，`gate = false`（停一下**自动**继续）
- `[stop]` / `[click]` → 停顿点，`gate = true`（**等点击**才继续）
- `[fx=…]` → 效果器触发点（见 §5.20）

**点击的落点改成「下一个停顿点」**，不再是「直接显示全文」：

- 停在点击门控上 → 放行，继续显示
- 正在打字 → 快进到下一个停顿点（没有下一个就补完整句）
- 已经打完 → 返回 false，交给 `main` 推进剧本

跳过 / 自动播放仍然调 `complete_typing(silent)` 一次给全（并且 `silent = true`
**不触发**剩余的效果器 —— 快进时把整句的 glitch 一次性全放出来只会是一团噪音）。
设置里可以关掉「点击先跳到下一个停顿」，回到「一点就显示全文」的老手感。

三个坑：

1. **停顿下标必须是「可见字符数」，不能拿 `display.length()`**。`display` 里还留着
   `[shake]` / `[color=…]` 这类渲染用标记，字符串长度 ≠ 可见字符数，而
   `RichTextLabel.visible_characters` 数的正是可见字符。差一个就会「停早了/停晚了」。
2. **闭合写法必须一起剥离**。`[/speed]` / `[/fx]` 若落到「渲染用标记」那条分支，
   RichTextLabel 会把它们当未知标签**连方括号一起显示**。所以判断顺序是
   「先按名字匹配（不分闭合）→ 再看是不是闭合决定要不要记事件」。
3. **点击快进要用「拨时钟」而不是「改可见字数」**。`_seek_to(index)` 直接把
   `_reveal_start_ms` 往回拨到 `times[index-1]`，于是下一帧 `_process` 自然算出
   正确的 reveal。改 `visible_characters` 是没用的 —— 下一帧就被 `_process` 覆盖回去。

**（四）回看 / 存档预览的剥离**

凡是要把台词渲染成静态文字的地方，都得先剥标记 —— 对话框只是其中之一。
回看面板与存档预览最初漏了这一步，玩家会看到
`alice: 明天，[speed=2.5]要不要一起走？[/speed]` 这种东西（截图对比时一眼看到）。

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

**状态复位**。`clear()` 会复位 `World.position`、立绘 `scale`、闪光 alpha。`hide_char()` 完成时也会把**动画缩放**归 1 —— 否则放大过的角色再次出场还是放大的。这两条都是「读档 / 重播后画面残留」的来源。

**站位与基准缩放（绝对坐标）**。`at=` 的五个预设槽位（left / center / right / off_left / off_right）是骨架期的默认姿势，但它表达不了「这个人往左挪 40px、比旁边的矮一截」。所以 `show` / `move` 另开了三个可选键：`x`（立绘**框中心**的设计像素）、`y`（立绘**脚底**的设计像素）、`scale`（基准缩放）。

三个设计点：

1. **锚点选脚底中心，而不是左上角**。`pivot_offset` 本来就在 `(CHAR_WIDTH/2, CHAR_HEIGHT)`，缩放时脚不动、往上长。把 `y` 也定义成「脚底在哪个像素」，那么「调高度」与「调远近」是同一个旋钮 —— 而且和 `zoom` 共用一套几何，不会互相打架。
2. **坐标用绝对像素，不用比例**。比例（0~1）看着「分辨率无关」，但调参时每次都要心算 1920×0.78 是多少；而本项目的坐标本来就全部建立在固定设计分辨率 1920×1080 上（`canvas_items` + keep），像素值所见即所得，没有收益损失。
3. **基准缩放与动画缩放分开存**。`entry["base_scale"]`（角色设定，进存档）和 `entry["scale"]`（`zoom` 的临时倍率）相乘后落到 `rect` 上。合成一个字段的后果是：一次 `zoom` 会把「这个角色本来就小」永久改掉，`clear()` / `hide_char()` 又把它抹回 1.0 —— 两头都不对。

配套的三条一致性要求：**不写就回到默认**（`show` 里没给的轴不会沿用上一次，否则「x=500 之后再 at=left」会半个位置沿用旧值，极难排查）；**覆盖值必须进 `get_state()`**，否则读档 / 回滚后立绘会跳回预设站位；**`NAN` 不能进 JSON**，所以未覆盖的轴干脆不写这个键（用 `NAN` 当「未设置」的哨兵，序列化只在真的覆盖过时才落字段）。

调参工具是 `tools/stage_grid.tscn`：一张 1920×1080 的图，叠 100px 网格、坐标刻度、预设锚点线、默认脚底线 `y=1130` 与立绘框参考，再按不同参数摆几个样本立绘。调 `x` / `y` / `scale` 时先跑它看图，比反复「改剧本 → 重启 → 点到那一句」快得多；控制台同时把样本的实测坐标打出来，和剧本里写的值对账。

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

**「改 `modulate` 属性」≠「画面上真的暗了」**。这一条后来被实测推翻过一次，值得记下来：
立绘一旦挂上表情材质（`char_expr.gdshader`），渲染就交给 shader 了。而 canvas_item 的
fragment 里，进来的 `COLOR` **已经等于「贴图 × 顶点色」**（顶点色 = modulate ×
self_modulate × 各级父节点）。于是：

| 写法 | 结果 |
|---|---|
| `COLOR = texture(TEXTURE, UV)` | 顶点色被丢掉 —— modulate 彻底失效。属性还是 0.55，画面纹丝不动 |
| `COLOR = texture(TEXTURE, UV) * COLOR` | 顶点色叠两遍（贴图² 量级）—— 一挂材质就恒暗约 40% |
| `COLOR = texture(TEXTURE, UV) * vcol`，`vcol` 在 `vertex()` 里取 | ✅ 唯一正确的写法 |

症状的迷惑性在于：**女主只在最开始两句会被压暗，换过一次表情之后就再也不暗了** ——
因为第一句时她还没材质。而 `get_char_brightness()` 读的是 `modulate` 属性，全程 0.55，
逻辑测试一路全绿，只有逐像素量渲染色才看得出来。当初修掉「一挂材质就变暗」时，
只验证了「modulate=1 时颜色一致」，于是把结论写成了「顶点色由引擎在 fragment 之后叠加」
—— 这个假设是错的，代价就是压暗静默失效。

修法是两个着色器都在 `vertex()` 里把 `COLOR` 存进 varying，fragment 里乘回去。
smoke 第 22 节的守卫现在**同时守这两种坏法**：`_color_assigns_reapplying_modulate`
（重复叠加）与 `_keeps_vertex_color`（丢掉顶点色），两者都带自检。
`tools/char_shader_probe.gd` 保留一张对照表（无材质 / 只看贴图 / 叠两遍 / varying），
`tools/dim_probe.gd` 逐句核对「该暗的到底暗没暗」—— 后者原本只查了说话人有没有被压暗，
正好漏掉这个方向。

```json
// gallery_theme.json
{
  "palette":  { "accent": "#7f77dd", "card": "#1c1932", "highlight": "#f1c774", ... },
  "layout":   { "columns": 3, "card_width": 350, "card_ratio": 0.5625, "grid_spacing": 22, ... },
  "text":     { "tab_cg": "CG 鉴赏", "locked_label": "???", "replay_button": "重播剧情", ... },
  "locked_icon": { "size": 58 }
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
| 换音乐播放器按钮文案 | `text.play_button` / `pause_button` / `stop_button` / `mode_*` |
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

### 5.18 多周目（NG+）

**要解决的核心问题是「哪些状态跨周目、哪些不跨」。** 本骨架原本已经有两类状态：
`GameManager` 的软状态（旗标 / 好感度 / 变量，每次 `reset_run()` 全清）
和「这台机器的记忆」（`CollectionManager` / `ReadTracker` / `RouteTracker`，
落盘在 `user://` 下、和存档分离）。多周目恰好卡在两者之间 ——
它既要跨周目累积，又要能被剧本读到、被存档带着走。

于是新增第五个 autoload：**`CycleManager`**（落盘 `user://cycle.json`），
它只管三件事：

| 字段 | 含义 |
|---|---|
| `cycle` | 当前第几周目，1 起 |
| `clears` / `clear_order` / `total_clears` | 每个结局被抵达过几次、先后顺序 |
| `inherited` | 上一周目通关时快照下来的继承数据（kind → {name: value}） |

**周目什么时候推进？** 不是「抵达结局」时 —— 那一刻玩家还在第 1 周目里看结局演出。
`record_ending()` 只把 `_advance_pending` 置起，真正的 `cycle += 1` 发生在
下一次 `begin_new_run(advance = true)`（也就是标题界面的「开始游戏」）。
章节选择走 `advance = false`：它是「跳到某一章重玩」，不该白送一个周目。

**继承的两阶段设计。** 剧本里的 `carry` 指令**只打标记**，取值统一发生在
`record_ending()`：

```
剧本执行 carry affection alice     →  _carry_marks["affection:alice"] = {...}
抵达结局 record_ending()           →  _snapshot_carry() 把当前值抄进 _inherited
下次开始游戏 begin_new_run()        →  _apply_inheritance() 写回 GameManager
```

为什么不在 `begin_new_run()` 时取值？因为那时 `GameManager.reset_run()` 已经跑过，
软状态是一张白纸，取不到任何东西。两阶段拆开之后还有个副作用好处：
作者把 `carry` 写在剧本哪一行都不影响结果，继承的永远是「这一周目结束时」的值。

`_snapshot_carry()` **只抄真的存在的键**。剧本写了 `carry flag 某个旗标`、但那一周目
根本没走到点亮它的地方时，不凭空造一个 `false` —— 「明确没点亮」和「还没有这个旗标」
在调试台列全部旗标时看得出区别。

**存档里只带一个字段。** `to_save_dict()` 只返回 `{cycle, advance_pending}`，
`clears` / `inherited` 一律不进存档。理由和「CG 收藏不进存档」完全一样：
通关战绩是这台机器上的长期记忆，读一份一周目的旧档不该让它退回从前。
反过来 `cycle` 必须进存档 —— 它决定剧本走哪条分支，是**进度**的一部分。

**清空继承标记的时机**在 `begin_new_run()` 开头：本周目的 `carry` 由本周目的剧本
重新声明，不清的话上一周目标记过的键会一直挂着。

**剧本侧的两个条件**（`ScriptRunner._evaluate`）：

- `cycle <比较符> <n>` —— 走 `CycleManager.get_cycle()`
- `cleared <结局id>` —— 走 `CycleManager.has_cleared()`，跨周目记录，所以二周目
  读它永远是 true

**`cleared` 写错 id 是最难发现的一类 bug** —— 那段 NG+ 内容永远不会出现，
而且完全不报错，和「解析器认识、调度器不转发」是同一种静默失效。
所以 `ScriptAudit` 会检查 `cleared` 引用的 id 在不在 `endings.json` 里；
`carry flag X` 而剧本里没有 `flag X` 也会报提醒。

**界面上的三个出口**：标题界面一行「第 N 周目 · 已通关 M 次」（一周目且没通关过时
整行隐藏，不提前剧透）、记录面板的「多周目」板块（含「下一周目继承」摘要）、
调试台的 `cycle` 命令（查看 / 拨周目 / 清空）。

---

### 5.19 可视化编辑器（tools/editor/）

**定位**：项目内的独立工具场景。与游戏共享同一套代码（`GvsParser` / `ScriptAudit` /
`Stage` / `UiTheme`），但不是游戏的一部分 —— 游戏跑 `main.tscn` 时不加载它，
导出时可整目录排除；把导出预设的主场景指向 `editor.tscn` 即成为独立 exe，代码不变。

**为什么放在 `tools/`**：`scripts/` 受 smoke 第 27 节架构守卫约束（core/autoload 不许
引用表现层、ui/stage 不许引用编排层），而编辑器天然要同时引用 `Stage`（预览）与
`GvsParser`（core）。放 `tools/editor/` 既避开守卫，语义上也正确：它是工具，不是游戏代码。

| 层 | 文件 | 职责 |
|---|---|---|
| 行分类器 | `core/line_index.gd` | 逐行分类 + 块栈；**原文一字不改**，保真的根基 |
| 文档层 | `core/script_doc.gd` | 行数组 + 编辑 + 写盘 + 撤销 + 乐观锁 |
| 索引层 | `core/project_index.gd` | 7 类素材索引 / 缩略图 / 缺失看板 / 未使用反查 |
| 监听层 | `core/file_watcher.gd` | 轮询 mtime + size |

**关键设计决策**：

1. **不做「解析 → 编辑 AST → 序列化」**。`GvsParser` 是编译式的，`strip_comment()` /
   `strip_edges()` / 空行过滤会丢掉注释、缩进、空行 —— 那等于每保存一次就吃掉作者的注释。
   所以文档的真实状态是**行数组**，编辑只替换改动的那几行，其余原样搬运。
   有一条自测守着这件事：解析成行再拼回去，必须与原文件**逐字节相同**。

2. **两个职责分离**：结构 / 定位 / 保真交给编辑器的行分类器；语义 / 校验交给
   `GvsParser` / `ScriptAudit`。判定规则必须逐条一致，所以注释剥离、关键字表、对白切分
   全部直接调 `GvsParser` 的静态工具，不另写一份。交叉验证守着：行分类器数出的
   对白数 / label 数 / choice 数，以及每条对白的文本与顺序，必须与 `GvsParser.parse()`
   的结果完全一致。

3. **无脏状态**。编辑即写盘（500ms 防抖），工具不持有未保存改动 → 外部改动
   （AI 直接改 `.gvs`）可以整体重载，冲突从根本上消失。代价是撤销必须靠内存快照栈。
   写盘前用 mtime + size 做乐观锁，有人插队就提示而不是静默覆盖。
   轮询而非监听的原因：Godot 运行时的 `EditorFileSystem` 信号只在编辑器插件里可用。

4. **分支图只读**（节点**双击**跳源码；不要用 `node_selected`，见下面第 13 条）。
   用 `GraphEdit` + `GraphNode` 渲染（拖拽 / 缩放 / 连线内建），
   但**不做结构性拖拽编辑**：拖拽改结构要「图 ↔ 文本」双向映射，其中「拖动节点改变
   物理顺序」会静默改掉 fall-through 语义 —— 那类错误不报错、只让剧情走错。
   图的价值在看清结构（死路 / 孤儿标签 / 汇聚），改结构回源码做。

5. **预览不加载 `main.tscn`**。`ScriptRunner` 是纯信号驱动的，`main.gd` 的职责只是把
   `stage_command` 转发给 `Stage`，所以编辑器写一份精简转发即可，省掉整套 UI
   （对话框 / HUD / 存读档 / 鉴赏）。尺寸用 `SubViewport.size_2d_override` 承载
   1920×1080 设计分辨率，画面自动缩放到小窗且不变形。

6. **素材缩略图直读**（`Image.load_from_file()`），不依赖 `.import` —— 刚导入的素材
   立刻可见。但运行游戏前仍需一次 `--import`，因为导入产物只能在编辑器进程里生成。

**对白表格的交互与性能约定**（都由真实报障逼出来的，改动前请先看这里）：

1. **表格有自己的「当前行」（`TablePanel._current_no`），不借源码视图的 `caret_line`。**
   `caret_line` 属于源码视图：表格页上它只是历史残留，而且 `load_doc()` 会把 CodeEdit
   整篇换掉、光标回到第 1 行，CodeEdit 随后**延迟**发出 `caret_changed`（延迟发出意味着
   用「同步中」布尔量挡不住）。若照单全收，表格里每改一次「当前行」就被拽回文件开头 ——
   表现出来是状态条显示第 1 行画面、插入落到文件开头。
   所以 `_on_caret_moved()` 只在 `_current_page == "script"` 时才改 `caret_line`；
   面板要改它必须走 `set_caret_from_panel()`。

2. **键盘模型**：点整行选中 → `↑`/`↓` 换行 → `Enter` 在下方插一行对白并聚焦台词框 →
   `Backspace`/`Delete` 删行 → `Esc` 退出编辑态。
   台词框里按 `Enter` 是「提交并接下一行」（连续写剧本不用摸鼠标）；
   焦点在 `LineEdit` 里时方向键/退格一律归输入框 —— `_unhandled_key_input` 里唯一
   的排除项就是它。

3. **左侧「指令」列可点击换类型**（非结构行）。转换时把「新指令也认」的参数搬过去，
   规则刻意保守：只搬新指令确实声明过、且类型一致的字段；搬错比不搬更糟
   （`show alice expr=smile` 转成 `bg` 时若把 `expr` 带过去，解析器会静默忽略它）。
   **位置参数必须走 `set_directive_arg`**，走 `set_directive_param` 会把角色写成
   `char=bob` 这种谁也不认的 kv 参数。结构行不给下拉（骨架指令，改类型请到源码）。
   行右侧不再有 `+` / `x`：插入走 `Enter`、删除走 `Backspace`。
   ⚠️ **菜单下标一律用 `item_count` 现取**：`PopupMenu.add_separator()` 也占一个下标，
   自己数计数器会从第二组起整体错位 —— 每个选项挂的是**前一项**的 metadata，
   于是「点 A 插出 B」（prologue.gvs 里那几行模板残留就是这么来的）。
   另：Godot 4.7 的 `PopupMenu` 没有 `set_item_checkable`，
   而这类报错会**中断整个填充函数**，表现成「点了没反应」。
   ⚠️ **回调必须从行节点取行号**（`_no_of(row)`）—— 行号 meta 挂在行上，
   从子控件取会恒得 0，处理函数开头就 return，同样是「点了没反应」。

4. **滚动分两种意图**：`_scroll_to_line(no, pin)`。
   插入 / 删除用 `pin = false` —— **只在那一行真的不在视口里时才滚，且只滚到刚好露出来**。
   以前一律 `scroll_vertical = row.position.y`（滚到顶端），对「在某一行下面插一行」
   来说动作太大：整屏内容突然上移一格，用户看到的就是「跳到别的地方去了」。

5. **行控件常驻，`visible` 表达「显示 / 不显示」。**
   过滤、折叠、隐藏注释都只切 `visible`，**不重建整表**。
   行号与建行时的原文存在节点 meta 里（`line_no` / `raw`），回调通过 `_no_of(row)`
   现取 —— 所以插入 / 删除后只要 `_rebind_after_insert` 改一下 meta，
   其余行一个都不用重建。这是「加一行不再卡」的根本。
   实测：加一行从 ~600ms 降到 ~30ms。

6. **重建走「离屏组装 → 一次性换掉 `_body`」，并且只在打开文件时走一次**
   （`on_shown` 用 `_built_revision` 判断，文档没变就直接走快路径）。
   ⚠️ **不要退化成逐个 `add_child`**：往挂在 `ScrollContainer` 里的容器逐行加，
   每次都会触发「最小尺寸 → 滚动条」整条链重算，是 O(n²)，
   247 行实测 322ms；而且即使容器是离屏的，`add_child` 本身也会重算容器最小尺寸，
   所以「先离屏再挂上去」只能省掉上层传播，省不掉那一半。
   真正要守住的是**别重建**（第 5 条）。

7. **缩略图优先用导入产物**（`ResourceLoader.exists` → `load()`），
   没导入过的新素材才退回 `Image.load_from_file` + CPU 缩放。
   现解一张 1920×1080 PNG 约 30ms，而选中一行就要刷一次状态条；
   缩略交给 `TextureRect` 在 GPU 上做。状态条还会比对累积状态，
   没变就只改标题 —— 这一条曾占「点一下行」耗时的大头（134ms）。

8. **Variant 写回剧本必须过 `_fmt_value()` / `_as_bool()`，绝不能写 `String(v)` / `bool(v)`。**
   Godot 4 的 `String()` 只接受 String / NodePath / StringName，`bool()` 只接受
   bool / int / float —— 传别的类型进来**只在运行时**抛
   `Invalid call. Nonexistent 'String' constructor.`，而界面照常重绘、值却没写进去，
   看起来就是「点了没反应」。位置参数的值来自控件（开关给 bool、数字给 float），
   正好踩在这条上。「置旗标」的开关就是被这个坑住的。
   同理 `ScriptDoc.set_directive_arg` 定位位置参数必须按「词」扫，不能 `raw.find(旧值)` ——
   `flag true_flag true` 里找 `"true"` 会命中旗标名，把名字改坏且不报错。

9. **`ScriptDoc.begin_batch` / `end_batch`：一次用户操作 = 一个撤销点。**
   类型转换内部要改好几处（换整行 + 补参数），不合并的话 Ctrl+Z 只能退回一半。
   ⚠️ **批量里也必须 `_reparse()`**：派生视图 `lines` 不跟上，后续操作会按旧内容
   定位，把前一步覆盖掉（踩过：`show bob` 变成了 `bob@smile: 第二句。 char=bob`）。

10. **保存策略：手动（`auto_save = false`，Ctrl+S）。**
    代价是工具手里会有未保存改动，所以外部改动**不能再静默整体重载**，
    必须弹冲突提示让用户选「覆盖磁盘 / 加载外部版本」。
    源码视图改成懒同步（`mark_dirty_from_panel` + `sync_if_stale`）：
    以前每次改动都整篇重设 `CodeEdit`，17ms 全文重解析之外还会**清空它自己的撤销栈**。
    撤销快捷键：非源码页 `Ctrl+Z` 走 `ScriptDoc` 快照栈，源码页归 `CodeEdit` 自己管。

11. **基本块分隔（`_recompute_blocks`）**：按编译原理课上的 **leader** 划分 ——
    文件首行 · 每个 `label`（跳转到达行）· 跳转/结束指令的**下一行**
    （`jump` `goto` `jump_file` `return` `ending`）· 块开闭的**下一行**
    （`if` `elif` `else` `choice` `end`）。
    渲染用**行样式**（`content_margin_top = 16` + `border_width_top = 1`），
    **不往表体里插分隔行控件** —— 行控件是常驻的、定位靠「行号 → 控件」，
    插非行的子节点会让所有定位重算。工具栏「基本块分隔」可关。

12. **分支图的出口判定**（`graph_panel._exits`）：
    `jump`/`goto` → 唯一下一跳（后面是死代码）；`jump_file` → 跨文件出口（同样是终结）；
    `ending`/`return` → 无出口；`call` → **有出口**（被调用的标签确实从这里进去）
    且会返回、所以还能顺流；`choice` → 每个选项一个出口且**不再顺流**；
    都没遇到 → 顺流到下一个 `label`。
    ⚠️ **终结必须显式记在 `terminated` 里，不能靠「out 为空」判断。**
    老写法对 `ending`/`return` 直接 `return out`（out 是空的），
    于是紧接着的 fall-through 补丁照样生效 —— 实测把 `ending_normal` 连到了
    `ending_bad`、把以 `jump_file` 结尾的 `ending_together` 连到了 `ending_alone`，
    还把只被 `call` 调用的 `common_pause` 丢成了孤儿节点。三条都是假边。

13. **分支图的跳转必须双击**。不要接 `GraphEdit.node_selected` ——
    它在**鼠标按下**时就发，于是「拖动节点」和「鼠标扫过节点」都会跳到源码页，
    图根本没法用。改成各 `GraphNode` 的 `gui_input` 里判 `double_click`。

14. **`if` / `elif` / `else` 里的跳转是「条件跳转」**：`_exits` 用 `LineIndex` 的
    `depth` 判断这一行在不在块里 —— `depth > 0` 时**不终结、也不 `break`**。
    老代码遇到第一个 `jump` 就 `break`，于是 `if … jump A / elif … jump B /
    else … jump C` 只画出 A，B、C 没有入边 → 被当成孤儿丢到最后一列
    （实测 `ending_normal` / `ending_bad` 就是这么「被独立出来」的）。

15. **`call` / `return` 不画返回边，改用节点标注**。
    `call` 可重入（`common_pause` 被两处调用），返回边会变成交叉线，
    把「整体结构」这张图搅乱。所以：子过程（块里有 `return`）的节点标题加 `↩`、
    标注「被 N 处调用：…」；调用方标注「→ call xxx」。信息量一样，图不脏。

16. **指令类型配色集中在 `EdTheme.TAG_COLORS`**，八类在色相环上大致等距
    （25/50/90/168/205/240/275/330）。⚠️ 曾经 `CHAR`（立绘）与 `SAY`（对白）
    共用 `SYN_SPEAKER` —— 而这两类恰恰最需要区分（一个改画面、一个改台词）。
    有一条断言守着「八类两两色相至少差 20°」。

17. **剧本块默认不显示空行与注释**（`_show_structure = false`）。
    剧本里空行很多（分隔用），一上来铺满会把「有内容的行」稀释掉。

18. **「剧本」与「章节」是两件事**：前者是 `data/scripts/` 下的每个 `.gvs`；
    后者是 `chapters.json` 里人工排的目录（标题 → 文件 + 起始标签）。
    **新建剧本不自动改 `chapters.json`** —— 顺序与标题都是创作决定，
    工具替作者改容易把目录弄乱；只在骨架注释与提示里说清怎么登记。

19. **新建角色会顺手放一张 `normal.png` 占位立绘**（从已有角色复制）。
    `normal` 是**默认表情** —— 剧本 `show <角色>` 不带 `expr=` 时取的就是它，
    不放的话游戏会掉进 `PlaceholderAssets` 蹦出一个程序化火柴人；
    另外新角色的卡片也立刻有缩略图可看。
    ⚠️ 但**「不放就看不见这个角色」是错的**：`_scan_chars` 给 `assets/sprites/` 下
    **每个目录**都建条目（只是 `exists = false`），空目录照样出现在立绘页里，
    只是卡片没有缩略图、写着「0 表情」。占位图的作用是上面两条，不是「可见性」。
    ⚠️ 顺带一个盲点：`ScriptAudit.has_real_asset("char", id)` 只看**目录存不存在**，
    所以一个立绘被删光的角色**不会**出现在「缺失素材」看板上（只会出现在
    「未被引用」里）。

20. **块层级用「背景微亮 + 缩进」表达，不画竖线**（`DEPTH_TINTS`）。
    竖线的问题：块首（`if` / `choice`）自己不在块里、没有线，块尾 `end` 也不在，
    所以线天然断成几截 —— 看着就是一条难看的折线。按嵌套深度给背景加一点白
    （0.035 / 0.060 / 0.080 / 0.095）既看得出范围，又没有硬边。

21. **插入 / 删除的滚动「只向下、不向上」**（`_scroll_to_line`，`pin = false`）。
    **落点永远是「当前行」**（`_anchor_no`），不因为它在屏幕外就改。
    ⚠️ 这里踩过两次，两次都是「治错了地方」：
    - 一开始是「一律滚到视口顶端」→ 用户滚到别处按回车，视图被拽回屏幕外那一行
      （实测滚动位置从 7139 跳到 794），用户描述成「跳到最顶层」。
    - 接着我改成「当前行不在视口里就落到视口顶端那一行」→ **更糟**：
      等于替用户把内容写到别处，新行冒到最顶上，而且他完全不知道为什么。
    - 正解：**落点不动，只让滚动不去追它**。目标行在视口上方时什么都不做
      （用户主动滚去看别处是有意为之），新行不在视口里就明确提示一句
      「已插入第 N 行（在视口外）」，免得「按了回车屏幕没变」被当成没生效。
      这条与 VS Code 一致：光标在视口外时按回车，文本插在光标处，视图不动。

22. **退格删行之后选中吸附到上一行**（`_nearest_visible(no - 1, -1)`）。
    与「文本编辑器里退格合并到上一行」的直觉一致；落到下一行会让光标往下掉一格，
    连续删的时候手感很别扭。上一行可能是个默认隐藏的空行，所以要朝上找第一个可见的。

23. **`_row_in_view` 要把「还没布局好的行」当成在视口里**（`size.y <= 0` → true）。
    新插入的行控件在容器重排之前 `position`/`size` 都是 0，按矩形相交算会得出
    「不在视口里」—— 任何依赖这个判断的逻辑都会在插入后的那一两帧里出错。
    同理 `_top_visible_no()` 要跳过 `size.y <= 0` 的行，并且**量不到时返回 0**
    （返回 1 会让调用方以为「视口顶端是文件第一行」，把内容插到最顶上去）。

24. **插入 / 删除后，行号按钮上显示的数字也要跟着改**（`_renumber`）。
    行号存在节点 meta 里，回调现取 —— 但**光改 meta 不改界面**，
    下面那些行显示的编号就还是旧的（用户报的「插了一行之后下方行数不更新」）。
    `Button.text` 只在文本宽度超过 `custom_minimum_size` 时才影响最小尺寸，
    而 `W_NO` 够宽，所以这一步不会引发容器重排（245 行几毫秒）。

25. **「双引号整段」是位置参数，不是 kv**（`F_TEXT` 上的 `quoted` + `rest`）。
    `ending normal "春日的答案"` 的标题、`chapter 第一章 · 春日的答案` 的章节名
    都属于这种：值里可以有空格。早先把 `ending` 的标题当 kv 处理，
    于是界面上读不出来、手输了也会「按回车就消失」—— 因为解析器在
    `ending` 分支里 `return` 得很早，kv 参数根本没进 `params`。
    写回要走 `ScriptDoc.set_directive_rest`（替换「从第 N 个位置参数到最后一个」），
    不能按词替换。

26. **结构 / 块级指令在类型下拉里是「插入」而不是「转换」**。
    把一行现成的台词转成 `end` 会让块结构整体变化、后果隐蔽；
    而用户在菜单里选 `jump`，想要的本来就是「我要用这条指令」。
    所以 `_on_type_index` 判断 `is_structural(op) or _touches_blocks([op])`
    就走 `_insert_block`。结构指令没有字段规格，用 `STRUCTURAL_TEMPLATES` 给骨架。

27. **跳转目标渲染成可点击链接**（`F_LABEL`），并在**目标不存在时标红** ——
    「跳到了不存在的标签」是剧本里最容易写错、最难查的一类，
    标红让它一眼可见，不用等静态校验。跨文件（`jump_file`）的链接会
    `_open_at_label` 打开另一个剧本并跳过去。

28. **`goto_line` 落到隐藏行时要退到最近的可见行**（`_reveal_no`）。
    源码视图的光标常常停在空行上，而空行默认不显示 ——
    如果因为「这一行不显示」就整个放弃滚动，视图会停在文件开头，
    用户看到的就是「切到表格页时跳到最顶层」。
    ⚠️ 排查时注意：**隐藏的行控件本来就不会被容器排版**（位置停在 `(0,0)`、
    尺寸是自己的最小尺寸），这是**正确行为**，别当成 bug 去修。

29. **剧本块里的「定位」一律留在剧本块页**（`_goto_row` / `_goto_label`）。
    用户在剧本块里工作，点了跳转却被打到源码页会丢掉他看的位置。
    `choice` 选项的箭头（`→`）也是「点击定位」的一环。
    跨文件（`jump_file`）走 `Editor._open_at_label_in_table` ——
    `_open(path, initial, keep_page)` 的第三参就是「别切页」。
    行号按钮**仍然跳源码**：那是「我要看原始文本」的明确动作，tooltip 里写着。

30. ⚠️ **`_hook_row` 会给行里每个按钮接一个「把本行设为当前行」**，
    而它是在行建好之后才挂的 —— **同步执行，会把按钮自己的动作覆盖掉**。
    实测：点跳转链接跳到第 8 行，紧接着被拽回本行的第 6 行。
    所以「点了要跳走」的按钮（跳转链接、choice 箭头）要打 `no_touch` 标记，
    `_hook_control` 见到就跳过。

31. **分支图的出口信息走「悬停连线 / 点连线」，不放进节点里。**
    `GraphEdit` 的连线画不了标签，一度把出口逐条列在节点上 —— 但那会把节点撑到
    5 行高，`_fit()` 为了让整条链塞进窗口只能缩到 **39%**，字全糊了
    （用户的原话：「太紧凑」）。所以节点回到「摘要 + 说明」两行，
    信息改由悬停提供，**双击连线跳过去**。⚠️ 这里有两个坑：
    - **单击不行**：会和 `GraphEdit` 自己的鼠标处理打架（单击背景取消选中 /
      起框选、按在端口附近开始拉线）。
    - **按下就跳也不行**：双击的第一下被它当成「按在端口上开始拉线」，
      而我们一按就切页走了 —— 它**永远收不到「松开」**，内部状态停在「正在连线」，
      切回来时还挂着一条橡皮筋（用户描述成「像多了一个鼠标按住一个点」）。
    正解：按下时只**记下**目标，**松开时**再跳，而且用 `call_deferred`
    让 `GraphEdit` 先把这次松开处理完。**另外鼠标悬停在连线上也会弹提示**：
    `GraphEdit` 既没有「连线 tooltip」也没有 hover 信号，所以用
    `get_closest_connection_at_point(local, 14)` 做命中测试
    （`gui_input` 里的鼠标位置就是 GraphEdit 的局部坐标，直接用），
    命中就自己画一个浮层 Label 跟着鼠标，并用 `set_connection_activity` 把那条线加粗。
    ⚠️ 不要指望 `_graph.tooltip_text` —— 鼠标停住后 Godot 才弹 tooltip，
    悬停过程中改文本不会刷新，而且拿不到「悬停在哪条线」。
    每条出口带**类型 + 行号 + 条件**：
    条件由 `_cond_at()` 往上找最近的 `if`/`elif`/`else` 得到，
    choice 选项则直接用选项文本。点一条 → 到**剧本块**定位到那一行
    （与剧本块里的跳转链接同一套约定：定位不甩到源码页）。

32. **节点的「身份」用标题前缀 + 颜色表达**（`_node_style`），优先级：
    孤儿 `⚠` > 结局 `★` > 子过程 `↩` > 起点 `▶`（前缀只放得下一个）。
    ⚠️ **但「结局」标记在说明行上再写一次** —— 一个结局节点常常同时是
    孤儿或子过程，而「这里会结束流程」是最不该被挤掉的信息。

33. **标签备注写成行尾注释**（`label X  # 备注`），不另开 sidecar 文件：
    它跟着剧本走（git / 源码视图 / 别的工具都看得见），
    `LineIndex` 解析前会先 `strip_comment` 所以不影响语义，
    剧本块的标签行直接就能编辑它。分支图的节点把它显示在说明行上。

34. **`_fit()` 要有「可读缩放下限」**（初始 `READABLE_ZOOM = 0.55`）。
    「全塞进窗口」对一条 11 个节点的链意味着 39% —— 用户要的是「看得清」，
    不是「一眼看全」。所以初始只保证竖着放得下、字看得清，横向超出就横向滚；
    「适应窗口」按钮仍允许缩得更小（那是用户明确要的全局概览）。

35. **分支图是只读的**：拖端口不会连线（`GraphEdit` 的 `connection_request`
    我们没接，所以不会产生任何连接）。这一点写进了顶部提示，
    免得用户以为「拖拽功能坏了」。

36. **左侧剧本列表用常驻的「⋯」菜单做重命名 / 删除**，不用右键菜单当唯一入口 ——
    左栏很窄、右键是隐藏操作，作者不一定想得到。
    - **重命名必须同步三处引用**：`chapters.json` 的 `file`、`data/collection/cg.json`
      的 `file`（重播片段）、各剧本里的 `jump_file <路径>`。
      实现是**纯文本替换**而不是重新序列化 JSON —— 那两个 json 是人工维护的
      （带 `_comment`、带缩进），`JSON.stringify` 会把格式和注释一起冲掉。
    - **入口剧本（`ScriptPaths.entry()`，写死的 `prologue.gvs`）拒绝改名与删除**：
      改/删之后游戏直接起不来，而工具看不出这层因果关系 —— 只能拦下并说明原因。
    - **删除当前打开的那个文件时先自动切走**（切到入口剧本，没有就切到任意别的剧本），
      最后一个剧本不允许删。
    - 删除**不做静默的引用清理**：章节条目、重播片段、跳转都是创作决定，
      工具替作者删容易删错；改为在确认框里报出「还有 N 处引用会变成死链」。
    - 手动保存模式下，手里有未保存改动时拒绝改名 / 删除（会丢改动），提示先 `Ctrl+S`。

37. **素材面板的导入入口长在素材流的尾巴上**（网格最后一张「＋」卡片），
    工具条上不再重复放按钮。同一张卡片按上下文有三种含义：
    | 位置 | 含义 |
    |---|---|
    | 背景 / CG / 音效… 页 | 往**当前类别**的目录导入文件 |
    | 立绘页 | **新建角色**（角色是目录，表情要在角色合集里导） |
    | 立绘合集内 | 往**那个角色**的目录导入立绘表情 |
    卡片右上角的 `✕` 负责删除：平铺素材删文件，立绘删单个表情（帧序列目录整个删），
    立绘页的卡片删整个角色目录。**所有删除都先过同一个确认框**
    （待执行动作放在 `_pending_delete` 里，这样一个对话框能覆盖三种删除）。
    - ⚠️ **`✕` 必须是卡片的最后一个子节点**：它才盖在缩略图之上、先拿到鼠标事件，
      点它不会连带触发卡片自己的 `pressed`（打开详情 / 立绘合集）。
    - ⚠️ **`✕` 不要设 `flat = true`**：那会让 Button 走空样式盒，normal / hover 覆盖失效。
    - ⚠️ 立绘导入的「不重名」不能用 `ProjectIndex.unique_file_name` ——
      它按**类别目录**拼路径，而立绘要多一层 `<角色>/`，会误判成不冲突然后覆盖掉。
      用 `_unique_in_dir(dir_path, base, ext)`。

38. **素材工具条只留「类别芯片 + 过滤框」**。曾经还有「导入素材 / 重新扫描 / 新建角色」
    三个按钮，与末尾的「＋」卡片、顶栏的「重新扫描」完全重复 ——
    重复入口的代价是用户不知道该点哪个，已删。

39. **右侧预览的尺寸不能靠 `custom_minimum_size` 钉死高度。**
    `AspectRatioContainer` 的 `STRETCH_FIT` 是「装得进就装」：高度锁在 186px 时，
    横向再宽也只会缩着不动（超过 330px 就白给），**拖分隔条画面一点不变大**
    （用户报的「预览太小、拉不开」）。正解是让容器纵向 `SIZE_EXPAND_FILL`，
    高度跟着栏宽一起长。另外「当前行状态」那一块要装进**定高的 `ScrollContainer`**：
    立绘多的时候它能长到十几行，会把上面的预览挤没。

40. **素材改名不是「只改文件名」，必须同步全部引用**（`core/asset_refs.gd`）。
    旧 id 还写在剧本、收藏表里，不改就是死链 —— 而且**剧本不报错**，
    只是画面黑掉、收藏品解锁不了。三条规矩：
    - **只改「结构位置」，绝不全文替换。** 台词正文里出现同名的词是常事
      （`alice@smile: 我笑了 smile。`），全文替换会把台词改坏且静默。
      做法：按 `LineIndex` 分类，指令行只换**指定下标的那个位置参数**（按词扫定位，
      不 `raw.find(旧值)`）、kv 只换整词相等的那个；对白行只改 `:` **之前的前缀**。
    - **角色 id 比别的素材多几个藏身处**：对白前缀、`affection <角色>`、
      `carry affection <角色>`、以及 `if affection <角色> >= 10`（条件不是 kv，
      `LineIndex` 把整段留在 `cond_text` 里，只能按词扫原文）。
      漏掉的话会出现「画面里没有 alice、好感度面板里却有 alice」的幽灵角色。
    - **收藏表用「带引号的精确模式」替换**：`cg.json` 里还有
      `"label": "cg_classroom"` —— 那是**剧本里的标签名**，跟着 id 一起改会让
      「重播剧情」跳不到（标签没了，剧本也不报错）。
    ⚠️ **角色改名改不了存档里的好感度**（存档是玩家数据，工具不碰），确认框里写清楚。

41. **素材操作要能撤销**（`core/asset_undo.gd`）。
    重命名 / 删除**动的是文件系统**，是编辑器里唯一会「弄丢东西」的操作
    （剧本编辑有 `ScriptDoc` 快照栈兜底，素材这边原来什么都没有）。
    做法：每一步记成「怎么反过来做」，撤销时**倒着**执行。
    - 只有三种可逆步骤：`move`（挪回去）、`content`（写回旧字节）、`dir`（把空目录建回来）。
    - ⚠️ **「删除」和「改写」在撤销层是同一件事**，都是「记下旧内容、撤销时写回」。
    - ⚠️ **先开记录、先抄下「可能被改到的文本」，再动文件系统** ——
      顺序反了，撤销栈里存的就是改完之后的内容。
    - 记文本时**故意记多不记少**（全部剧本 + 全部收藏表）：漏记一个文件 =
      撤销之后剧本引用还是断的，那种「撤了一半」比不能撤销更糟。
    - ⚠️ 撤销 `content` 时父目录可能已被一起删掉，要先 `make_dir_recursive`。

42. **拖拽导入：Godot 只有窗口级的 `files_dropped`**（Control 没有 per-node 拖放目标），
    所以收到之后要自己判断该不该管：不是素材页就忽略；合集开着就导进那个角色；
    立绘页按**鼠标落点**命中卡片（卡片上存了 `asset_id` meta），落空就提示
    「立绘是两级目录，拖到某个角色卡片上」——不瞎猜。
    ⚠️ 拖放和徽章一样是**同步改文件系统**，所以同样要过 `_guard_dirty()`。

43. **全局搜索是独立一页**（`panels/search_panel.gd`，`Ctrl+Shift+F`）。
    改素材名 / 删素材 / 查一个 flag 用在哪，都是「先要看清全貌」的动作。
    - **当前打开的文件读内存而不是磁盘**：手动保存模式下编辑器里可能有未保存改动，
      按磁盘搜会搜出「我刚写的怎么搜不到」。
    - 大小写不敏感，**不做正则**（剧本里 `[](){}` 满地都是，正则反而容易写错）。
    - 打字走 0.25s 防抖：逐键全量扫在剧本多了以后会卡。

44. **「查找」和「过滤」是两件事**，剧本块里两个都要有：
    - 过滤（工具条那个框）= 改**可见性**，只让命中的台词留下；
    - 查找（`Ctrl+F` 那条）= 改**当前行**，逐条跳过去，不动可见性。
    混在一起的话作者想看命中处的上下文就做不到 —— 过滤会把它藏掉。
    ⚠️ 查找**只搜当前显示的行**（折叠块里、被隐藏的注释不参与）：
    找到了也跳不过去（`goto_line` 落到隐藏行会退到最近的可见行），
    高亮停在别的行上比搜不到更让人困惑。

45. **预览默认「跟随光标」**：光标移到哪一行，画面直接摆出「执行到这一行」的样子。
    GVS 的状态是累积的（`bg classroom` 之后一直有效），所以「第 N 行画面长什么样」
    可以直接算（`ScriptDoc.line_state`），不必点 ▶ 从头播 ——
    改一行就要重播一遍的话，调演出基本没法用。
    - 复用 `Stage.restore_state`（本来就是给读档用的「一次性摆好画面」，语义完全一致），
      只要把字段名从 `id` 换成 `char`。
    - 光标那一行是对白的话，对话框也一起摆出来，否则「跟随」只跟了一半。
    - **播放中不跟随** —— 那是调度器在驱动 Stage，跟着光标改会把播放搅乱；
      按停止之后交还给跟随。

46. **底部校验区用 `VSplitContainer` 包起来**：能拖高看全，也能一键收起
    （`VSplitContainer` 会**跳过不可见的子节点**，所以「收起」就是直接 hide）。
    顶栏再加一个 `?` / `F1` 的**快捷键总览**弹窗 —— 键散在 README 里没人记得住，
    加键的时候也不容易忘（`SHORTCUTS` 常量就在编辑器里）。

47. ⚠️ **成员名不要和 Node 的虚函数同名**（`_input` / `_process` / `_draw` …）。
    踩过：`SearchPanel` 里写 `var _input: LineEdit`，脚本内部用着没事，
    但外部通过 `Control` 类型的引用访问 `panel._input` 时，
    **解析到的是 Node 的 `_input()` 虚方法（一个 Callable）**，
    于是 `panel._input.text` 报 `Cannot find member "text" in base "Callable"`。
    改成 `_query` 即可。（`scripts/ui/debug_console.gd` 有同一个坑，已一并改掉。）

48. **行内输入框的提交要挂在两个信号上：`text_submitted`（回车）与 `focus_exited`（失焦）。**
    只挂回车的话，「改完数值直接去点别处」（改下一个框 / 点另一行 / 滚页面）值就丢了 ——
    而界面看着像已经改了，作者按保存也还是旧值
    （用户报的「点击离开框后源代码没有更新」）。
    表格里所有内联 `LineEdit`（数值 / 文本 / 语音 / 选项目标）都补了失焦提交。
    ⚠️ 失焦提交必须**幂等**：数值按数比而不是按字符串比（界面是 `0.80`、文档是 `0.8`），
    否则「点一下别处就多写一次盘」，还会白推一个撤销点。

49. **素材索引变了要主动作废剧本块的缓存。** 剧本块的行控件是**常驻**的，
    素材 / 表情下拉的选项在**建行那一刻**就定死了（`_asset_field` 读 `index.ids(kind)`）；
    而它判断「要不要重建」用的是 `doc.revision` —— 导入素材**不改剧本**，
    所以不作废的话，旧行的下拉永远停在旧选项上，只有新插入的行才有新素材
    （用户报的「原来的行没有新素材的选项」）。
    做法：`Editor.invalidate_asset_views()` → `TablePanel.invalidate_assets()`
    把 `_built_revision` 置 -1，下次显示时整表重建。调用点是 `_rescan()`
    与 `AssetPanel._after_asset_change()`（导入 / 改名 / 删除 / 新建角色都走它）。

50. **`ScriptDoc.line_state()` 必须算上「对白行里的内联表情」**（`alice@smile: 文本`）。
    `GvsParser._do_dialogue` 把 `@` 后面的东西放进 `say` 指令的 `expr`，
    而 `ScriptRunner` 执行它之前会**先发一条 `expr` 舞台指令** ——
    所以「执行到这一行」的画面里表情是已经变过的。
    ⚠️ 只遍历 `DIRECTIVE` 行的话，预览永远停在 `show` 时那个表情
    （用户报的「表情没有变化，只有立绘入场的表情」）。
    角色不在台上时不动它，与 `Stage.set_expr` 的「找不到就忽略」保持一致。

51. **「从此处预览」要精确到行，靠的是解析器给每条指令盖的 `line` 键。**
    编译结果里唯一的定位点是标签，所以原来只能「从最近的标签开始」——
    点第 60 行却从第 20 行的标签重播一遍，中间台词演出全部又走一次；
    而且如果背景是在那个标签**之前**设的，画面直接是黑的
    （用户报的「不是在行的位置预览」「有时候无法正常显示背景」）。
    现在两步：
    1. `_restore_stage(doc.line_state(no - 1))` —— 先把「执行到上一行为止」的
       累积画面摆好（复用 `Stage.restore_state`）；
    2. `ScriptRunner.start_at_line(no)` —— 找**第一条 `line >= no` 的指令**
       （指令按源码顺序发出，所以这就是命中点；落在注释 / 空行上会自动往后顺延）。
       ⚠️ 命中点在某个 `choice` 的**选项行**上时要从那条 `choice` 开始 ——
       「从选项中间开始」没有意义，所以选项也盖了 `line`。
    找不到就**不跑**并说明原因，**不悄悄退回按标签重播**（那正是被抱怨的行为）。
    另外预览改走 `ScriptRunner.load_text(doc.to_text(), path)`：从**内存**编译，
    这样未保存的改动也能预览，而且行号与编辑器看到的一致（否则 ② 会落到别处）。

52. **自定义 BBCode 特效的清单只能有一份**（`scripts/ui/text_effects/text_effects.gd`）。
    ⚠️ **没登记的特效标签会连方括号一起漏成正文** —— RichTextLabel 把未知标签当普通字符。
    这个坑踩过两次：回看面板一次（注释里写着），编辑器预览一次
    （用户报的「有些文本特效没有在预览窗口实现」）。
    所以 `dialogue_box` / `backlog_panel` / 预览三处统一 `TextEffects.all()`。
    Godot 内置的 `[shake]` / `[wave]` / `[rainbow]` / `[fade]` / `[pulse]` 不用登记。
    另外预览要把节奏标记（`[wait=]` / `[speed=]`）用 `TypingTimeline.strip()` 剥掉 ——
    那是给打字机用的，预览里没有打字机，留着会原样显示。

53. **分组素材的 id 要带组名**（语音：`assets/audio/voice/<角色>/<台词>.ogg` → `voice <角色>/<台词>`）。
    只把目录当纯组织的话，两个角色各有一个 `01.ogg` 就撞了，而撞了之后
    游戏会播到**另一个角色**的语音 —— 这种错极难查。
    带组名的好处是**零成本**：路径拼出来就是 `VOICE_DIR + "alice/line01" + ".ogg"`，
    所以 `AudioManager._find_stream` 与 `ScriptAudit.has_real_asset` 一行都不用改。
    `ProjectIndex._scan_grouped()` 扫一层子目录；`_valid_id` 允许**一层** `/`（每段各自校验）；
    `groups(kind)` 给素材页做「按角色」浏览。根目录下的散文件仍按文件名当 id。
    ⚠️ **两级素材的浏览方式要统一**：网格页只列「组卡片」，双击进合集看组内条目。
    立绘（组=角色、条目=表情）和语音（组=角色、条目=语音）共用
    `_open_gallery(kind, group)` 那一套；语音只是把缩略图换成「♪ + 时长」。
    ⚠️ 组卡片上的改 / 删作用于**整个目录**：改名要把该组所有成员 id 一起重写
    （`AssetRefs.rewrite_asset` 一次只认一个 id，所以是逐条改 + 统一提交），
    删除走 `_record_dir` + `_delete_dir_recursive`，两者都可撤销。
    ⚠️ **必须有一个「建分类目录」的入口**。第一版只在「磁盘上已经有子目录」时才显示
    角色卡片，于是新项目里根本没有办法建第一个分类（用户反馈「我没见到分类」）。
    现在语音页的「＋」卡片就是它（`_open_new_role_dialog` → `_create_voice_role`），
    建完直接进那个角色的合集；空态时 `_stat` 里也会指一句。
    立绘和语音共用那个「新建」对话框（`_new_group_kind` 决定建哪一类）。
    ⚠️ 语音的「＋」**不是**导散文件 —— 散文件只能靠拖拽进（落到「未分组」），
    免得作者顺手把语音全堆在根目录。
    ⚠️ **`groups()` 要以目录为准，不能从 id 反推**。第一版是遍历 id 取 `/` 前面那段，
    于是**空目录（刚建好、还没放语音）根本不算一个组** —— 表现成
    「新建角色 → 返回，那个文件夹不见了」（用户报的）。现在
    `ProjectIndex.group_dirs[kind] = {组名: 目录路径}` 在扫描时记下来（空目录也记），
    `groups()` / `group_dir()` / `group_exists()` 都查它。
    ⚠️ **语音页要列出所有立绘角色**（`index.char_ids()`），把还没建语音目录的标成
    「还没有语音目录」（暗色）—— 这是一份「还有谁没配音」的清单，
    点进去导语音时 `_import_flat` 会自动建目录。不列的话作者无从知道（用户反馈
    「语音界面不会显示已有角色」）。
    ⚠️ **语音条目用紧凑行卡片，不要套立绘的大卡片**（用户反馈「ui 做得太长」）：
    语音是纯文字条目，`CARD_W × (THUMB_H+46)` 的大卡片会留一大片空白。
    现在角色卡片 46px 高、语音卡片 30px 高（`♪ + 名字 + 时长 + ✎✕`），
    网格列数语音 3 列 / 立绘 5 列，合集语音 2 列 / 立绘 6 列；
    紧凑行里的时长用 `_fmt_clock`（`3:31`）而不是 `_fmt_duration`（`3 分 31 秒`）——
    后者宽 40px，168px 的卡片里会把台词名挤没。
    ⚠️ **空状态的说明文字必须挂在网格外面**。带 `autowrap` 的 Label 最小宽度是 0，
    放进 `GridContainer` 会被分到一个「最小宽度」的格子 → 被压成一条竖线、
    **一个字一行**（用户报的「界面还是长」就是它）。挂在网格上面的 VBox 里，
    它才是整行宽、正常换行的一段话。
    ⚠️ **卡片里垫的那层 overlay `Control` 一定要给 `set_anchors_preset(FULL_RECT)`**。
    `Button` / `PanelContainer` 都不是 Container，不会替子节点排版；不给锚点它就是 0×0，
    里面 `SIZE_EXPAND_FILL` + `clip_text` 的 Label 会被压成 0 宽、**整条名字看不见**
    （语音卡片的台词名就这么消失过；只有量 `Label.size.x` 的断言抓得到，文字断言查不出来）。

54. **「看」和「进」要分开**：立绘卡片**单击看详情、双击进合集**。
    进合集会把整个网格换掉，作者想连着看几个角色的表情数就得反复进出。
    ⚠️ `Button` 没有双击信号，所以双击走 `gui_input` 里的 `double_click` 标志
    （双击的第一次按下仍会触发 `pressed`，顺便更新详情，可以接受）。
    ⚠️ 双击是**隐藏操作**，必须在详情里留一条「进入立绘合集 →」的明路，
    光靠 tooltip 不够。

55. **变量清单（`core/var_index.gd` + `panels/var_panel.gd`）的价值全在「判定对不对」**——
    判错会给出**假的安全感**。所以规则必须与 `GvsParser.parse_condition` 对齐：
    - 写：`flag <名> [true|false]` / `set|add|sub [var] <名> <值>` / `affection <角色> <值>`
      （⚠️ `set var x 3` 与 `set x 3` 两种写法项目里都在用，不能只认一种）
    - 读：`if|elif` 条件里的 `[not] flag|var|affection <名>`、以及 `carry <类别> <名>`
    - ⚠️ `cycle` / `cleared` **不是**变量，别列进来
    - 两类问题：**只读不写 = error**（几乎一定是拼错，那条分支永远走不到，这是最贵的错）、
      **只写不读 = warn**（可能只是纯记录，不能当错误）
    - ⚠️ **引擎侧会读写的名字要排除**（标 `info`，不计入问题数）：小游戏通关、
      章节解锁（`chapters.json` 的 `unlock_flag`）这类旗标本来就是引擎设/读的，
      不排除的话会报一堆假错，作者看两次就不信这个功能了。
      判定只认**字面量调用**（`get_flag("x")` / `set_var("x", …)`）与 `chapters.json` ——
      **注释里出现不算**：项目里 `rhythm_qte.gd` 的注释写着「成功时点亮旗标
      `rhythm_qte_cleared`」但代码里没设，那正是要报出来的真问题。
      `engine_names()` 结果按进程缓存（改了游戏代码要重开编辑器才刷新）
    - 侧栏「变量」一节常驻（`Editor._refresh_vars()`），**有问题的排最前面**，
      点一条跳到第一处；完整页（过滤 / 只看有问题）从这一节标题的「详细」进。
      ⚠️ 用户反馈过「做成单独一页要反复切页很麻烦」——所以主视图在侧栏，页面是补充。
      刷新挂在 `_push_issues()` 上（打开 / 保存 / 重扫 / 新建 / 改名 / 删除剧本），
      **不跟每次击键**

56. **破坏性素材操作不许碰素材根目录，而且必须留流水。**
    - 闸门：`AssetPanel._safe_target(path)` 拒绝 `ProjectIndex.KIND_DIRS` 里的任何一个
      根目录（也拒绝空路径）。接在 `_delete_dir_recursive` / `_record_dir`
      （两个真正落盘的地方）以及 `_delete_voice_role` / `_rename_voice_role` 上。
      ⚠️ 为什么必须有：语音的「未分组」组名是**空串**，`_voice_dir_of("")`
      就是 `assets/audio/voice/` 本身 —— 只要有一条路径把空串当组名传下去，
      删一次就把整个分类目录连同里面所有语音清空。**真实发生过**（整目录被抹平，
      靠 Godot 的导入缓存才把原始字节救回来）。
    - 流水：`_log_op(op, path)` 把删除 / 改名追加到 `user://asset_ops.log`。
      ⚠️ 素材被误删过一次却**查不出是谁干的**（测试？编辑器？资源管理器？），
      所以宁可留一条带时间戳的记录 —— 下次直接翻日志，不用再靠推理。
      验证过：跑完全套测试 + 截图后，日志里只有测试自己的临时路径，
      素材根目录一次都没被碰过。

57. **新增指令要在三处同时接线，缺一处就是静默失效**：`GvsParser.KEYWORDS` +
    解析分支、`ScriptRunner._execute` 的转发、`OpSpec.specs()` 的字段规格
    （还要挂进 `insert_menu()` 的某个分组）。`audio_fx` 这条就是这么加的。
    - ⚠️ **下拉的候选值不要手抄**。`audio_fx` 的音轨 / 效果器清单直接取自
      `AudioFxSpec`（core 层的规格类，与 `ScreenFxSpec` 同一个套路）——
      手抄一份的后果是「编辑器给了一个运行时拒绝的选项」，不报错、只是没效果。
    - ⚠️ **新指令要给它一个 `tag`**（指令类型那一格的颜色）。加 `AFX`（红，
      色相 0°）时**必须同时把它加进 `table_ux_test._test_tag_colors` 的 `groups`** ——
      否则新色可以跟任何一色撞在一起而「两两分得开」的断言照样全绿，那张表就成了摆设。
    - 语料侧还有一处：`tools/smoke.gd` 的 `OP_SAMPLES` 表。少一条样本时
      「样本表覆盖了全部指令」会直接变红，这正是它的作用。
    - `unlock` 的类别下拉加了 `video`，与 `CollectionRegistry.SOURCES` 一一对应。

58. **字段规格的第三种形态：`tail`（吃到行尾）。**
    `rest`（`ending` 标题那种）只吃到**最后一个位置参数**，遇到 kv 就停 ——
    而 `call 打招呼 who=alice count=2` 的参数**是 kv**，用 `rest` 会整段读不出来
    （界面永远空白，写回去还会插到 kv 前面拼出 `call f who=bob who=alice`）。
    所以加了 `tail`：读取走 `ScriptDoc.directive_tail(raw, index)`，
    写回走 `set_directive_tail()` —— 从第 N 个位置参数（不存在则从最后一个位置参数
    之后）一直替换到行尾。三种形态的分工：
    | 修饰 | 吃到哪 | 例子 |
    |---|---|---|
    | （无） | 一个词 | `show alice` 的 `alice` |
    | `rest` | 到最后一个位置参数 | `ending normal "春日的答案"` |
    | `tail` | 到行尾（含 kv） | `call 打招呼 who=alice count=2` |

59. **块级指令要同时进四处**，漏一处就是「缩进/折叠不对」或「菜单里没有」：
    `LineIndex.Line.opens_block()` + `_update_stack()`（行分类与折叠）、
    `TablePanel.BLOCKY`（改动后要全量重建）、`OpSpec.STRUCTURAL` +
    `STRUCTURAL_TEMPLATES`、以及 `_insert_block()` 里的多行骨架分支。
    `together` 这条就是这么加的 —— 它的骨架带两行注释说明用法
    （注释行不参与解析，作者照着替换即可）。

60. **字段可以带显示条件 `"when": {"key": …, "in": [...]}`。**
    起因是用户的一个问题：「音频特效是每个特效都有三个参数吗？为什么改特效种类
    的时候都是三个参数」。真相是**只有 `duration` 通用** ——
    `strength` 有 9 个效果用得到，`pitch` 只有 `pitch` 一个用得到
    （`glitch` / `error` 的音高抖动是内部按 strength 随机生成的，不读 `pitch=`）。
    三个参数全摆出来，等于告诉作者「写了就有用」，而运行时压根不读 ——
    和「编辑器给了一个运行时拒绝的选项」是同一类**界面骗人**。
    - 条件求值在 `OpSpec.fields_for(op, ctx)`，`ctx` 是「字段 key → 当前取值」；
      `when_keys()` 告诉调用方要算哪些值，`default_context()` 给插入模板用。
    - `TablePanel._field_context(line)` 负责算 `ctx`。条件字段一改 →
      `_field_write` → `_refresh_row` **整行重建**，字段自然跟着出现 / 消失，
      不需要额外的监听。
    - 白名单（`STRENGTH_KINDS` / `PITCH_KINDS` / `effect_kinds()`）放在
      `AudioFxSpec`，与音轨 / 效果名一样是**唯一一份**。
    - `default_text()` 也要过滤 —— 插入模板里不该出现对默认条件毫无作用的参数。
    - 顺带把 `muffle` / `underwater` / `radio` 的 `strength` 真正接上
      （截止频率除以强度、混响湿度乘强度…），`strength=1.0` 正好等于原来的固定值，
      老剧本听感不变。这样「哪些参数有用」就只剩 `pitch` 一处例外。

61. **OpSpec ↔ 解析器一致性守卫**（`tools/editor/tests/op_spec_test.gd`，headless）。
    守的是「编辑器能写、解析器不读」这类静默失效 —— 界面上能选能填，
    写进剧本却没人理，不报错、只是没效果。做法：拿每条指令的**插入模板**当底稿，
    用编辑器真实的写入路径（`set_directive_arg` / `set_directive_param` /
    `set_directive_rest` / `set_directive_tail`）把每个字段改成测试值，
    再交给 `GvsParser` 解析，逐字段断言「写进去的值读得回来」。
    - 字段名与指令字典的键一致时**严格比对**；不一致的（`bg` 的 `fade` 存成
      `duration`、`show` 的 `type` 存成 `transition`）退一步查「值有没有出现」——
      够抓「参数被静默丢掉」，也不会因为改名而误报。
    - 测试值**故意不等于当前值**，否则「压根没写进去」会被误判成通过；
      数字按字段轮换，避免「三个字段只写进去一个」也过。
    - `step >= 1` 的字段按**整数**测 —— 写 1.25 会被解析器的 `int()` 截成 1，
      断言就变成假失败（`times` / `frame` / `buffer` 都踩过）。
    - ⚠️ **守卫必须能真的失败**：写完之后把修复临时撤掉跑一遍确认它变红
      （实测撤掉 `move` 的 `at=` 支持 → 「1 个字段里有问题」）。
      一个从不失败的守卫等于没有守卫。

62. ⚠️ **两个被这个守卫抓出来的真 bug**（都在编辑器里存在很久了）：
    - **`move alice at=center` 被静默丢掉。** 解析器只把 `tokens[2]` 当位置槽位，
      `at=` 是 kv、**从来没被读过**；而编辑器的「移到」下拉写的正是 `at=`。
      症状是「在编辑器里改了位置，游戏里纹丝不动」，一声不吭。
      修法是让解析器也认 `at=`（`show` 一直两种都认，这里对齐）。
    - **位置参数的枚举下拉选「（默认）」会写出 `<null>`。**
      `_enum_field` 给每个枚举都加了「（默认）」项，选中就 `_field_write(null)`；
      而 `_fmt_value(null)` 走 `str(null)` → `"<null>"` → 写出
      `unlock <null> cg_classroom` 这种解析器认不出的东西。
      修法：**位置参数不给「（默认）」项**（位置参数没有「缺省」可言），
      并且 `_field_write` 对位置参数把 `null` 当「删掉这个词」处理。

63. **下拉里的「合成项」：`custom`**（立绘位置的「自定义」）。
    用户要求「位置多一个自定义选项，选中自定义之后才显示 xy 的参数」。
    实现上有两个坑：

    - **「自定义」不是脚本里的值。** 它只是下拉里多出来的一项，选中它意味着
      「不用槽位，改用 x= / y= 坐标」—— 写回剧本的是**坐标**，而不是「自定义」三个字
      （写进去解析器不认，位置会静默丢掉）。所以：
      · 选它 → 写 `custom.sets` 里的参数，再**删掉本字段**（`at=`）
      · 选普通值 → 删掉 `custom.clears` 里的参数（坐标）
      不清坐标的后果是「选了 left 还停在 960,1130」—— 坐标会盖过槽位。
    - **判据跟着规格走，不写死字段名。** 「是不是自定义模式」= 行里有没有
      `custom.sets` 列出的参数。规格改了（比如以后加 `z=`）这里不用动。
    - ⚠️ **写回顺序：先写坐标、再删 `at=`。** 反过来的话会短暂产出
      `move alice`（既没有 at 也没有坐标），而解析器要求 `move` 至少三个词 ——
      中间态虽然不会落盘，但批量撤销栈里会多一份坏快照。
    - ⚠️ **`show` 切自定义后 `at` 会缺省成 `center`**（解析器的默认值），
      所以测试不能断言「`at` 为空」—— 要先写一个别的槽位再删，断言它**没留下来**。

64. **行控件要能被按名字找到**（`ctl.set_meta("field_key", …)`）。
    `_directive_row` 给每个字段控件盖一个 `field_key` meta。
    起因：行里的控件个数**会随条件显示变化**（`audio_fx` 的参数、
    立绘位置切「自定义」后的 x / y），测试按位置找控件必然脆。
    有了 meta，`pos_custom_test` 才能写出「找到位置下拉 → 点『自定义』→
    断言行里冒出 x / y」这种走真实控件的断言。

65. ⚠️ **主题里写着的键必须真的有效，否则就是界面骗人。**
    用户问「如何更改对白字体、界面字体」，一查发现两个键**改了没有任何效果**：
    - **`apply_label` / `apply_rich_text` / `apply_check_button` 的默认字体键是空串**
      = 压根不挂字体。于是 `fonts.body` 只对按钮生效（`apply_button` 里写死了
      `font("body")`），其它 60 处调用全都不受影响。
      修法：新增 `DEFAULT_FONT_KEY := "body"` 并把它设为这几个函数的默认值 ——
      `fonts.body` 空的时候 `font()` 返回 null、不挂 override，行为与以前完全一致。
    - **`apply_font` 一律写 `font` 主题项，而 `RichTextLabel` 用的是 `normal_font`**
      （它没有 `font` 这一项）。`has_theme_font_override("font")` 还是 `true`，
      看代码会以为改上了，实际渲染用默认字体 —— **对白正文就是 RichTextLabel**，
      所以 `fonts.dialogue` 从来没生效过。
      修法：`apply_font` 按控件类型选主题项（RichTextLabel 写
      `normal_font` / `bold_font` / `italics_font` / `bold_italics_font` / `mono_font`）。
    - `fonts.title` 同理没人用 → 标题界面的主副标题现在显式传 `"title"`。
    - 守卫写在 `smoke` 的「外观配置」一节：拿一个 `SystemFont` 的 `.tres`
      （`tools/fixtures/fonts/test_font.tres`）当替身，逐类控件断言
      「`fonts.body` 填了之后真的挂上去了」。**不需要往项目里塞真字体文件。**

66. **对白文字色要能单独配**（`dialogue.text_color` / `text_dim_color`）。
    `palette.text` 是全界面共用的，改它会连带把设置 / 存档 / 回看一起换色 ——
    而作者往往只想让对白不一样。空串 = 沿用 `palette.text`，
    所以「不动配置」的行为不变。居中旁白同理（`narration.text_color`）。
    - 「已读变暗」用**独立的键**而不是把正文色算个透明度：深色底上「变暗」和
      「变亮」都可能对，交给作者定。
    - 顺手加了两个通用小工具：`UiTheme.section_text(group, key, fallback)` /
      `section_color(...)`。**空串 = 用 fallback** —— 「没配」和「配成透明」是两回事。

67. **编辑器的预览要跟着版式走**（`preview_panel._apply_dialogue_layout`）。
    用户要求「旁白的位置同步编辑器」。做法：
    - 位置 / 字色 / 描边**直接读游戏主题的 `narration` 段** ——
      预览的 SubViewport 就是 1920×1080 设计分辨率，offset 可以原样用，
      所以作者在预览里看到的位置就是游戏里的位置。
    - 常规对话框**仍用编辑器自己的样式**（深色小框），不去复刻整套贴图 ——
      预览只是近似，这一点没有变。
    - ⚠️ **两个入口必须共用同一个函数**：跑剧本的 `_on_say` 与跟随光标的
      `_apply_follow`。各写一遍的话居中旁白只会在其中一处生效，
      作者会以为「跟随光标时版式不对」。
    - 顺带把 `_dlg_text.text = TypingTimeline.strip(text)` 换成 `build()` 一次拿全
      （display + layout），两处都不会漏。

68. **版式为什么是「文本里的标记」而不是「行的参数」。**
    用户问得很直接：「旁白居中是如何实现的，为什么不能像立绘入场那样在编辑器里面
    可以有选项地修改」。答案是：
    - **对白行在 GVS 里没有 kv 参数位** —— 它是 `角色@表情: 台词` / `narr 台词`，
      台词之后的一整行都是正文。所以「这一句怎么摆」只能挂在**文本**上，
      和 `[wait=]` / `[stop]` / `[fx=]` 走同一套内联标记。
    - 挂文本上还顺手拿到两件事：**插值 / 回看 / 存档预览 / 编辑器预览**都只要走
      既有的剥离逻辑就自动对（`strip()` 会把版式标记一起去掉）。
    - 但**「实现方式」不该决定「能不能在界面上改」** —— 立绘位置的下拉写的是
      `at=`，版式的下拉写的是 `[center]`，两者对作者是一样的：选一下就行。
      于是加了 `TypingTimeline` 的三个桥函数：
      `layout_of()` 从文本里读、`with_layout()` 写回（幂等、别名归一）、
      `strip_layout()` 去掉。
    - ⚠️ `layout_of()` **不建时间轴**（只扫 `[...]` 找标记）—— 剧本块要给几百行
      都算一次，走 `build()` 会白白分配一堆 `times`。它和 `build()` 共用
      `_tag_name` 与 `LAYOUT_ALIASES`，所以两边不会各认一套。
    - 选项清单只有一份：`TypingTimeline.LAYOUT_LABELS`（规范名 → 界面文案），
      编辑器下拉直接读它。以后加「右上角小字」这类新版式只改这一张表。
    - 写回走 `ScriptDoc.set_dialogue_text()` —— 旁白行 / 对白行 / 选项行三种前缀
      它都处理好了，不会把角色名或 `->` 标签弄坏。
    - 对白行的控件也盖了 meta（`say_field` = speaker / expr / layout / text）——
      和指令行的 `field_key` 同理：**测试按名字找控件，不按位置**。

69. **对白行的列宽：谁该吃满，谁该收窄。**
    用户的要求是「说话人、表情、版式这些块紧凑一点，让对白的文本宽一点」。
    两处改动，第二处才是关键：
    - **三个下拉的 `custom_minimum_size` 从 `W_FIELD`(118) 降到 72 / 84 / 58。**
      ⚠️ `OptionButton` 的宽度是 `max(custom_minimum_size, 内容宽度)` ——
      这里给的是**下限**，取值短的下拉会自然缩到内容宽度
      （「默认」「居中」只有 60 多像素），遇到「alice（缺立绘）」照样会长。
    - ⚠️ **行尾那个 `hfill()` 要删掉。** 台词输入框本身是 `EXPAND_FILL`，
      行尾再摆一个同样 `EXPAND_FILL` 的填充，两者会**平分**富余宽度 ——
      表现是「台词右边凭空空出一大块」，而台词只拿到一半。
      删掉之后台词吃满（实测 90px → 762px），语音列跟在它后面（表格的常规样子）。
      这个坑很隐蔽：光看代码只觉得「有个填充占位挺正常」，要看截图才发现。
    - 断言写在 `say_layout_test`：**「台词比最宽的下拉还宽一倍以上」**，
      而不是写死像素 —— 窗口大小、字体、下拉里最长的选项都会影响具体数值。

70. ⚠️ **剧本块改完，右侧预览不刷新**（用户报的）。
    根因是**两条编辑路径的收尾不一样**：
    - 源码视图：`ScriptPanel.committed` → `Editor._on_doc_committed`
      → 刷校验 + `_preview_panel.show_line_state(caret_line)`
    - 剧本块：只 `ScriptPanel.mark_dirty_from_panel()` —— 那**只置了一个
      「源码视图过期」标记**，等着切回源码页时才同步。预览因此一直显示旧内容，
      要点别的行（触发 `_on_caret_moved`）再点回来才刷新。
    修法：`TablePanel._after_edit(line_no)` 统一收尾，除了标记过期，还调
    `Editor.notify_doc_edited_from_panel(line_no)`。
    - ⚠️ 传的是**刚改的那一行**，不是源码视图的 `caret_line`：在剧本块里改第 40 行时，
      源码视图的光标可能还停在第 3 行，拿光标行去刷新会显示错的那一句。
    - 9 处提交点（台词 / 说话人 / 表情 / 版式 / 选项文本 / 选项跳转 / 插入 / 删除 /
      行尾注释）全部走这一个收尾函数 —— 各写一遍必然漏掉一两个。
    - 回归断言写在 `table_bugs_test`：断言的是**预览上真的出现了新台词**，
      不是「函数被调到了」—— 这个 bug 的特征恰恰是「什么都没发生」。
      写完之后把修复临时撤掉跑了一遍确认它会红。

71. **变量页：单击选中 + 右侧引用侧边栏**（用户要求）。
    - 原来「点一下 = 跳到第一处引用」。一行有十几处引用时根本不够用，
      而且「点一下」与「选中看详情」两个意图会打架。现在：
      **单击 = 选中**（`toggle_mode` + `ButtonGroup` 单选），跳转由侧边栏的每一条承担。
    - 用 `ButtonGroup` 而不是自己管高亮：自管的话「点同一条两次」会把选中态弄丢。
    - `_fill()` 之后要**保住选中**（过滤条件变了、剧本改了都会重建列表）；
      选中项没了就落到第一条 —— 否则右侧一直空着，看起来像坏了。
    - `rescan(files)` 加了「只扫指定文件」的钩子（与 `VarIndex.scan` 一致）：
      不加的话测试只能依赖项目里真实剧本的内容，改一句台词就红。
    - ⚠️ **`HSplitContainer.split_offset` 是相对第一个子控件最小宽度的偏移**。
      左边是 `ScrollContainer`（最小宽度 0），不设 `split_offset` 的话分隔线贴在最左边 ——
      变量清单被挤成一条缝、侧边栏占掉整个宽度。设 420 + 给左边一个最小宽度。
    - 顺带修了 `Editor._open_at_file`：它只在 `ScriptStats.script_files()`
      （**只含 `data/scripts/`**）里找。打开别处的 .gvs 时点引用跳不动，
      现在先判「是不是就是当前打开的这个文件」。

72. ⚠️ **说话人清空会把行写坏**（用户报「有些旁白改不了说话人」时顺带炸出来的）。
    `set_dialogue_speaker(no, "")` 以前照样拼 `"%s%s:%s"` → 写出 **`: 文本`**
    （说话人位空着、冒号还在）。再选回角色就成了 **`alice: : 文本`** ——
    序章里真被这么写坏过两行（`alice: : 早上好。`）。
    修法：清空说话人 = **转成旁白行** `narr 文本`；旁白行选角色 = **转成对白行**
    `alice: 文本`。两个方向都干净，而且这才符合界面上的语义
    （说话人下拉的「（旁白）」就是一个选项，不是「删掉说话人」）。
    - ⚠️ 拼回去要用**行原文的正文段**（`_say_body`），不能用 `line.text` ——
      后者剥掉了行尾注释，拿它拼会把 `alice: 文本  # 备注` 的备注弄丢。
    - ⚠️ `narr 文本` 的正文段是 `substr(空格+1)`，**不含**前导空格；
      `alice: 文本` 的是 `substr(冒号+1)`，**含**前导空格。转方向时要补 / 去，
      否则写出 `alice:文本`。
    - 根因还有一半：**旁白行（`narr`）在 GVS 里是指令不是对白行**，
      而 `set_dialogue_speaker` 只认 DIALOGUE —— 于是「旁白改不了、新建的行能改」，
      用户看到的就是「有的行行、有的行不行」。

73. ⚠️ **素材下拉不给「（未设置）」**。
    本项目的素材字段**全是必填的位置参数**（`bg <背景>` / `show <角色>` /
    `voice <语音>` …）。选「（未设置）」= 把这个词从行里删掉 → 剩下
    `voice volume=1` 这种谁都认不出的指令：**解析器不报错**（它把 `volume=1`
    当成了 id），只是语音永远播不出来，而 `volume=` 参数也一起没了。
    序章里真被这么写坏过一行（`voice <语音> volume=1` → `voice volume=1`）。
    界面不该提供一个「写出来就是坏行」的选项 —— 直接去掉，和「位置参数不给
    『（默认）』」是同一条道理（见 62）。

74. ⚠️ **测试里 `_find_line(前缀)` 匹配不到会拿到 null 控件，而报错会被吞掉。**
    写「角色台词 → 旁白 → 角色」这条往返断言时，用整句 `alice: 角色台词。`
    当前缀 —— 但同一测试前面已经给那一行加了 `[center]`，前缀匹配不上，
    `_find_line` 返回 -1，`_row_by_no.get(-1)` 是 null，`sp2.item_selected.emit(0)`
    抛 `Invalid access to property 'item_selected' on Nil`。
    **断言照常往下走、总数照常打印**，只有日志里有 SCRIPT ERROR。
    - 修法：前缀挑**不会被前序步骤改动的部分**（`alice:`），
      并且拿到控件先 `_ok(x != null)` + `if x == null: return`。
    - 这也是「跑完必须 grep SCRIPT ERROR」这条规矩的价值所在（见测试方法学）。

75. ⚠️ **淡入的立绘第一次会「滑进来」**（用户报的「入场动画是错的，重新加载一次才正常」）。
    `Stage.show_char` 里那条 `position → target` 的补间**无条件**会跑：
    - `transition=none` → 走的是另一条分支（直接 `rect.position = target`），没问题
    - 滑入类（`slide_left` …）→ 起点是 `target + offset`，本来就该动 ✔
    - **`fade` / `dissolve` 这类「不位移」的转场** → 只把 alpha 置 0，**位置没摆**。
      于是第一次 show 时节点还是刚建的（位置停在默认值），补间把它从那儿拖到目标位 ——
      看起来就是「明明写的是淡入，第一次却从左上角斜着滑进来」。
    - 第二次 show 就正常了：`_ensure_char` **复用节点**、回标题只把 `visible` 置 false，
      位置还留在目标位，补间等于没动 —— 所以表现是「重新加载一次就好了」。
    修法：`offset` 为零且**这个角色还没显示**时，先把 `rect.position` 摆到 `target` 再补间。
    - 回归断言写在 smoke 的「媒体」一节：**淡入全程位置不动** +
      **对照组（滑入）位置必须动** —— 后者是防止「把位置补间整个关掉」来蒙混过关。
    - ⚠️ 断言里别拿「脚底线」当 rect 的 y：位置是 `脚底线 - CHAR_HEIGHT`，
      实测 `y=1600` 时 rect.y 是 600。用「比默认脚底线低 300 以上」这种相对断言。

76. ⚠️ **`sel == 0` 不能当「没找到」的哨兵**（用户报的「alice 显示缺文件」）。
    `_asset_field` 原来是：
    ```
    var sel := 0
    for k in ids.size():
        if ids[k] == cur_id: sel = k
    if sel == 0 and not cur_id.is_empty():
        加一项 "%s（缺文件）"
    ```
    下标 0 是**合法值**（列表里第一个素材），和「没找到」撞在一起 ——
    于是**排序后的第一个素材永远被判成缺文件**。`alice` 正好是第一个，所以只有她中招。
    修法：用一个独立的 `found` 布尔量。
    - ⚠️ 同一个函数里「（未设置）」被去掉之后，`sel = k`（不再是 `k + 1`），
      正好把这个潜藏的 bug 暴露了出来 —— 但它在 `sel = k + 1` 的写法下**同样存在**，
      只是 `sel == 0` 恰好落不到「第一个素材」上（0 被「（未设置）」占着）。
    - 对白行的说话人下拉没这个问题（`sel = k + 1`，0 是「（旁白）」），
      所以「说话人显示 alice 正常、立绘素材显示缺文件」—— 两边表现不一致本身就是线索。

77. ⚠️ **位移补间与透明度补间必须分两个槽**（用户报的「加上立绘移动这行之后，
    立绘就无法正常入场显示了」）。
    以前 `show` / `hide` 用一个 `set_parallel(true)` 的补间同时补 **alpha** 和 **position**，
    存在 `entry["tween"]` 一个槽里；而 `move` / `hop` / `zoom` / `shake` 开工前都会
    `_kill_char_tween()` —— **把正在跑的淡入一起杀掉了**。
    实测：`show alice fade=0.3` 紧跟 `move alice center` → 1 秒后 `alpha = 0.00`，
    **立绘完全看不见**，而且不报错。
    修法：拆成 `entry["tween"]`（位移）与 `entry["alpha_tween"]`（透明度），
    位移类指令只杀前者。`_kill_char_alpha_tween()` 只有 `show` / `hide` / `clear` 会碰。
    - 顺带把 `show` 里「淡入」那条路改成**只建 alpha 补间**（位置已经摆到目标，不需要动），
      滑入 / 已在台上重新定位仍然建位移补间 —— 语义更直白。
    - `hide` 同样拆开：淡出走 alpha 补间、滑出走位移补间，`reset` 回调挂在对应的那个上。
    - 回归断言（smoke「媒体」一节）：**入场淡入被 move 打断后 alpha 仍要补到 1**，
      以及**退场淡出被 move 打断后不能卡在半透明**。
      写完之后把拆分撤掉跑了一遍，两条都变红 ✔。

78. **`move` 不会让不在台上的立绘出现** —— 这是设计，但要**说出来**。
    典型翻车场景：可重播片段（CG / 音乐鉴赏）里只写了 `move alice center`，
    而重播前会 `clear()` 清台 → 立绘不在台上 → 移动看不见，
    整段「只有台词、没有人」。
    - 引擎侧：`move_char` 对不在台上的角色 `push_warning`，别让作者对着「怎么没反应」猜。
    - 剧本侧：`cg_rooftop` 里补了 `show alice expr=normal at=center fade=0.8`，
      让片段自带出场（可重播片段必须自洽）。
    - 手册 §15 加了第 11 条坑。

79. ⚠️ **`move` 到槽位被坐标挡住**（用户报的「从左边设置移动到右边没有效果」）。
    实测复现：`show alice x=460 y=1600` 之后 `move alice right` ——
    `entry["at"]` 确实变成了 `right`，但 `_char_position_for` 里 `pos_x` 优先，
    立绘**停在原地**（rect.x 180 → 180），而且**不报错**。
    - 根因是 `show` 与 `move` 的语义不一致：`show_char` 每次**重置**坐标
      （没给的轴回 `NAN`），而 `move_char` **只覆盖、永不清** ——
      show 设的坐标一直活在 entry 里，`move` 只改 `at` 是盖不过它的。
    - 修法：`move` 给了槽位就把 `pos_x` 交还给槽位；**`pos_y` 故意保留**。
      **理由是数据模型**：`POSITION_RATIOS` 里**只有横向比率** ——
      槽位在语义上只管 X。所以「移到 right」= 横移，纵向不该跳
      （作者用 `y=1600` 放低了立绘，横着移过去时跳回默认底线会很突兀）。
      想复位纵向就显式写 `y=`。
    - `move alice right x=300`（槽位 + 坐标）→ 坐标更具体，以坐标为准
      （`opts.has("x")` 时不清）。
    - **编辑器侧不用改**：`_is_custom_mode()` 会把「行里有 x/y」的行报成「自定义」，
      x/y 输入框因此可见 —— 作者能看到并删掉那个正在起作用的坐标。
      （编辑器选「移到」下拉本身也会 `clears` 掉坐标，所以这条路径本来是干净的；
      中招的是手写 / 从源码视图改出来的 `at=left x=460` 组合。）
    - 回归断言（smoke「媒体」一节）四条：横移生效 / 纵向保持 / 只给坐标仍生效 /
      槽位 + 坐标以坐标为准。撤掉修复后第一条变红（`x 180 → 180`）✔

80. ⚠️ **预览的累积状态与运行时的状态机是两套代码，必须对齐**（用户报的
    「点击预览的预览窗没有正确显示移动后的立绘」）。
    「从此处预览」= `_restore_stage(doc.line_state(no - 1))` 摆好累积画面 +
    `start_at_line(no)` 往后跑。「跟随光标」也走 `line_state`。
    问题是 **`line_state` 是编辑器自己重新实现的一遍 `Stage` 状态机** ——
    同一个语义写了两份，改一处忘一处就出问题。这次查出四处不一致：

    | | 运行时（`Stage`） | `line_state`（旧） |
    |---|---|---|
    | `move` 的槽位 | 位置参数与 `at=` 都认 | **只认位置参数** |
    | `move` 到槽位 | 清 `pos_x`（`y` 保留） | **不清** |
    | `move` 一个不在台上的角色 | 什么都不做 | **凭空加进 `chars`** |
    | `show` 没给的坐标轴 | 回默认（`NAN`） | **沿用上一次** |

    - **第一条最要命**：编辑器「移到」下拉写出来的就是 `at=right` ——
      所以「在编辑器里改位置，预览纹丝不动」。
    - 第四条来自 `_upsert_char` **只覆盖、不删除**：`show alice x=460 y=1600`
      之后再 `show alice at=left`，预览里 alice 还停在 460
      （游戏里是对的，`Stage.show_char` 每次重置 `pos_x`/`pos_y`/`base_scale`）。
    - 第三条与 `Stage.move_char` 开头的 `if not _chars.has(id): return` 对齐 ——
      预览显示一个游戏里根本不存在的立绘，比「什么都没有」更糟。
    - 回归：`core_test` 加 7 条数据断言（headless，快）+ `preview_test` 加 2 条
      走**真实「从此处预览」**的断言（断言 `Stage` 上立绘的 x）。
      **撤掉修复后 core 红 2 条（`实得 left`）、preview 红 2 条（`x=142` 停在 left）** ✔
    - ⚠️ 教训：**同一个语义不要在两处各写一遍**。更彻底的做法是让预览直接问运行时
      （给 `Stage` 加一个「只算不画」的状态查询接口），这次选了成本低的
      「逐条对齐 + 逐条断言」—— 但 `line_state` 的**每个分支**都该有对应断言，
      否则下次加新指令（比如又加一条带位置的指令）还会漏。

### 5.20 音频效果器 / 角色静音 / 标题音乐

**（一）三条独立音轨**

`AudioManager._setup_buses()` 启动时建 `BGM` / `SE` / `Voice` 三条总线（幂等），
都汇入 `Master`。BGM 总线的 0 号位固定是频谱分析器。

分开的理由有两条：三类音量本来就该分开调；**效果器要能按轨施加** ——
「这句台词的时候音乐出故障」不该把语音一起弄坏。

⚠️ **我们加的效果器一律追加在分析器之后，清理时按对象身份找下标**，
绝不 `remove_bus_effect(idx, 0)` —— 那会把频谱分析器删掉。

**（二）效果器**

清单在 `scripts/core/audio_fx_spec.gd`（`AudioFxSpec`）—— **唯一一份**，
解析器 / `AudioManager` / 编辑器 OpSpec 三处共用。抄两份的后果是
「编辑器给了一个运行时拒绝的选项」，不报错、只是没效果。

| 效果 | 实现 |
|---|---|
| `glitch` | `AudioEffectDistortion(LOFI)` + `AudioEffectPitchShift`，参数按 90ms 时间片跳变 |
| `error` | 再加一层 `AudioEffectLowPassFilter` 扫频（500~4000Hz） |
| `distortion` | `AudioEffectDistortion(OVERDRIVE)` |
| `pitch` | `AudioEffectPitchShift`，倍数看 `pitch=` |
| `muffle` / `underwater` | 低通（700 / 380Hz），水下再加混响 |
| `radio` | 带通 1.6kHz + `ATAN` 软失真 |
| `echo` | `AudioEffectDelay`（tap1 + feedback） |
| `reverb` | `AudioEffectReverb` |
| `amplify` | `AudioEffectAmplify` |

**Godot 没有 `AudioEffectBitCrusher`**（`ClassDB.class_exists` 查过是 false），
所以「故障 / 错误」只能用 LOFI 失真 + 音高抖动拼。这也是为什么这两类需要
**时间片跳变**而不是逐帧随机 —— 逐帧随机会糊成噪音，听不出「数字故障」，
只像坏了。

⚠️ `AudioEffectDelay` **没有 `feedback` 属性**，回授要显式打开 `feedback_active`
并设 `feedback_delay_ms` / `feedback_level_db`。写成 `feedback = 0.3` 会在运行时
报「不存在的属性」而且静默失败。

**互斥**：同一音轨上我们加的效果器是互斥的，新的一次先清上一次 ——
否则「故障叠着失真」会把声音糊成一团，链也会越挂越长。
`duration > 0` 时到期自动清除（`_process` 里比对时间戳）。

**（三）两种触发方式**

```gvs
audio_fx bgm glitch duration=2.0        # 指令：在某处挂 / 清
alice: 这……这不可能[fx=glitch bus=voice]！   # 内联：在文字显示的中间触发
```

内联标签由 `TypingTimeline.build()` 编译成 `events` 表，`DialogueBox._process`
在 reveal 越过那个字符时调 `AudioManager.apply_audio_fx()`。这样「触发的时机」
和「打字机的进度」用的是同一个时间轴，变速 / 停顿 / 快进都不会错位。

**（四）角色静音**

语音 id 是 `<角色>/<台词>`，取斜杠前那一段作为角色 id。`_play_voice()` **开头**
就挡掉被静音的角色 —— 挡在这里的话，语音既不占队列位置，也不会打断正在播的另一条。
出队时再判一次（排队期间角色可能被静音了）。已静音的角色正在说时立刻 `stop_voice()`。

名单存 `user://config.json` 的 `muted_voices`（跨存档、跨周目保留）。
角色清单优先读 `data/characters.json`（导出后可靠），再用 `assets/sprites/` 目录
扫描兜底 —— 漏登记的角色照样能静音。

**（五）标题界面 BGM**

`ConfigManager` 的 `title_bgm`（空串 = 标题不放音乐）。设置面板的「标题音乐」下拉
**只列已解锁的曲目** —— 未解锁的曲子连标题都不该暴露。选项在 `present()` 时重建
（玩过一局就会变），不能在 `_build()` 时定死。

三个要点：

1. **没选曲子时要主动 `stop_bgm()`**。从游戏里退回标题时剧本那首还在响，
   不停就变成「标题放着游戏里的曲子」。
2. **离开标题时 `_stop_title_bgm()`**。剧本第一句之前标题那首还在响，不停会两首叠着。
3. **配置改了要立刻生效**：`main` 订阅 `config_changed`，若此刻正停在标题界面就换曲
   （玩家可能就停在标题界面改设置）。

---

### 5.21 剧本语言扩展：`call` 参数 / 台词插值 / `together`

**（一）`call` 带参数**

```
call 打招呼 who=alice count=2      # 具名
call 打招呼 alice 2                # 位置 → {$1} / {$2}
```

- 参数随调用帧压栈：`_call_stack` 的元素从「int（返回地址）」改成
  `{ip, params, args}`，`return` 时整帧弹掉。查找是**内层优先**，
  所以嵌套调用里的同名参数不会互相串味。
- ⚠️ **这是存档格式的改动**。`restore_state()` 必须兼容旧档：读到整数就补成
  「没有参数的帧」。不加这条兼容的话，玩家手里的旧存档一读就崩。
- 位置参数（`{$1}`）与具名参数（`{$who}`）可以混用，查找顺序是具名 → 位置 → 变量。

**（二）台词插值 `{$…}`**

| 写法 | 取值 |
|---|---|
| `{$名字}` | call 参数（内层优先）→ 剧本变量 |
| `{$1}` `{$2}` | call 的位置参数 |
| `{$affection.角色id}` | 好感度 |
| `{$flag.旗标名}` | 旗标 |

四个设计点：

1. **查不到时原样保留 `{$名字}`，不换成空串。** 静默变空是最难查的一类问题
   （作者只看到「那句台词怎么少了半句」）；留着原文一眼就能看出名字写错了。
   `ScriptAudit.interp_warnings()` 也会把「没有任何 `set` / `call` 参数写过」
   的插值名报成 warning（抽成独立函数是为了能直接测 —— `audit()` 只扫真实的
   `data/scripts/`，测试往里塞文件会破坏 `purity_test` 守着的规矩）。
2. **整数不显示 `.0`**。存档 JSON 会把整数读回 float，直接 `str()` 会让玩家
   看到「好感度 17.0」。`GvsInterp.format_value()` 统一格式化。
3. ⚠️ **插值名的正则不能限制成 `[A-Za-z0-9_]`**。剧本里的变量名 / 参数名完全
   可能是中文（`set 好感 5`、`{$好感}`），限制成 ASCII 的后果是中文插值
   **完全不生效**而且查不出原因（正则不匹配 → 原样保留 → 看起来像「没写」）。
   现在的模式是 `\{\$([^}\s]+)\}`。
4. **插值在调度器里做**（`_exec_say` / `chapter` / `ending`），不在对话框里 ——
   这样回看记录、存档预览、已读标记拿到的都是替换后的文本，
   不用各自再实现一遍。

**（三）`together` 并行组**

GVS 的演出指令本来就是「启动即返回」（Tween 在后台跑），所以「同时发生」
不需要支持。真正缺的是**「等这一组都跑完再继续」** —— 以前只能手写 `wait`，
而那个数字要跟着每个 `duration` 一起改。

- 解析：`Builder` 里加一个 `_together` 栈，块内指令进 `body` 数组
  **不进顶层 `commands`**（否则会被顺序执行一遍，表现是「同一段演出播了两次」）。
- 调度：`_exec_together()` 用 `_execute()` 逐条启动（块内都是非阻塞的，
  由解析器保证），然后取 `duration` / `fade` 的最大值进 `WAITING_TIMER`。
- ⚠️ **`duration=` 的「没写」与「写了 0」必须分开**：不写 = 用块内最长的那条，
  写 `0` = 只启动不等。解析器用 **-1 当哨兵**表示「没写」——
  两者都当 0 的话，`duration=0` 会变成「等最长的那条」，正好相反（实测踩过）。
- **块内用允许表**（`GvsParser.TOGETHER_ALLOWED`）而不是禁止表：以后新增指令时
  默认是「不能在 together 里用」，这个方向安全（顶多提示作者去改，
  不会静默产生错误语义）。写不允许的指令是**解析期错误**。
- `video wait=true` 在块内单独报错：那个等待态会被块自己的等待覆盖掉，
  表现是「写了 wait 却没等」—— 又是一类静默失效。

### 5.22 打字音 / BGM ducking / 自动播放等语音

**（一）打字音**

每 2 个可见字符响一次（`DialogueBox.TYPING_SFX_INTERVAL`），触发点是
**已显示字符数**而不是经过的时间 —— 与打字机共用同一套时间轴口径，
快进 / 变速 / 停顿都不会让音效和字的出现脱节。

素材顺序：`assets/audio/se/type.<ogg|mp3|wav>` → 内置**合成**音。
为什么必须有合成兜底：打字音是每个字都要响的高频音效，缺素材时静默无声
会让「打字手感」这个功能看起来根本没做。合成一段 28ms 的指数衰减噪声
只要几百字节（`_make_typing_stream()`，固定种子所以每次启动听起来一样）。

⚠️ 它**不走 `play_se`** —— 那条路会走 `_find_stream` 的「缺素材」分支，
每句都往控制台打一行 `[Audio] 缺少素材，已静默跳过: .../type`。

**（二）BGM ducking**

语音开播 → BGM 压低 12 dB；语音播完 / 被中断 → 恢复。

⚠️ **压的是 BGM 总线音量**（`AudioServer.set_bus_volume_db`），不是播放器的
`volume_db` —— 后者被切歌淡入淡出（`_bgm_tween`）占着，两者同时写会互相覆盖，
表现是「淡入到一半突然跳回原音量」。总线音量只被 ducking 一个人写，
而且天然叠在淡入淡出之上。

压下去要快（0.12s，不然台词听不清）、放开要慢（0.45s，不然像音量跳变）。
三个参数都在 `ConfigManager`（`duck_db` / `duck_attack` / `duck_release`）。

**（三）自动播放等语音念完**

`main._process` 的自动播放分支：到点了先问一句 `AudioManager.is_voice_active()`，
还在播就把 deadline 往后推 120ms 再来查。
**语音长度和文本长度没关系，估算不出来，只能真的问一下。**

### 5.23 设置面板的分组

设置项从 8 项涨到 16 项之后，整页铺满就找不到东西了。改成**一张有序的
`LAYOUT` 表**驱动：`"#组名"` 是分组标题，其余是行规格（`type` 决定渲染成
滑块 / 开关 / 下拉 / 语言 / 角色语音段）。

- 一个列表按顺序渲染 —— 想调顺序 / 换分组只改这一张表，不用动渲染代码，
  也**不会出现「规格表与布局表两份、改一处漏一处」**的漂移。
- 分组标题用小一号 + 强调色 + 上边距做层次，不画分隔线（一页里画太多线更乱）。
- 这是「设置面板分类」的轻量版：没有做页签，因为分组的收益已经拿到了，
  而页签要多一套「当前页」状态与切页时的焦点处理。

---

### 5.24 居中旁白 `[center]`

剧本写 `narr [center] 文本`，这一句就摆到画面正中：**不画对话框底板**，
文字直接压在画面上。

**标记为什么放在 `TypingTimeline` 里剥**：它已经有一整套 `[...]` 标记的解析，
而且**所有标记都必须剥离**（RichTextLabel 对未知标签会连方括号一起漏成正文）。
多一个 `LAYOUT_TAGS` 分支、结果里多一个 `layout` 键，比在对话框里再写一遍
正则要安全得多 —— 回看 / 存档预览走的 `strip()` 也自动跟着对了。
`layout` 是**版式**不是时间轴：它不占可见字符，`times` 的长度不受影响。

**两个容器节点没写 unique name**，所以用 `_box.get_node("VBox")` 取 ——
给它们加 unique name 要动 `main.tscn`，而这两个路径是稳定的。

**切版式做四件事**（`_apply_layout`）：

| 改什么 | 常规 | 居中 |
|---|---|---|
| 框的锚点 | 底边（`PRESET_BOTTOM_WIDE`） | 全屏（`PRESET_FULL_RECT`） |
| 框的 offset | `dialogue` 段 | `narration` 段 |
| 内容对齐 | VBox / 名牌 / 文字都靠左靠上 | 全部居中 |
| 底板样式 | `dialogue_stylebox()` | `narration_stylebox()`（默认全透明） |

- ⚠️ **常规版的 StyleBox 要先存下来**（`_normal_box_style`），切回来时原样还原 ——
  它可能是作者在编辑器里手改过的，重建一份会把手改覆盖掉。
- ⚠️ **`show_line` 里「编译 → 定版式 → 显示」的顺序不能反。** 先 `visible = true`
  会先闪一帧常规对话框再跳到画面中间。
- **没有底板，所以必须给文字描边**（浅色字 + 深色描边，字幕的做法）：
  浅背景靠描边、深背景靠字本身，两边都看得清。
  这里踩过一次：只加描边不改字色，浅色主题的**深墨色正文**压在画面上直接糊成一团
  （截图一眼看出）。所以 `narration` 段另有 `text_color`。
- **`narration` 与 `dialogue` 分成两段**：旁白的 offset 相对**全屏**锚点、
  对话框相对**底边**锚点。混用一个分组的话，「改旁白的边距」会连带把对话框也挪了。
- **名牌不隐藏**：`narr` 本来就没有说话人（走 speaker 为空那条路）；
  而 `alice: [center]……` 这种「角色台词也居中」的写法，名牌居中显示在文字上方。
- **回滚 / 读档不记版式** —— 它是「这一句的属性」，重新显示时会按文本重新判定。
- ⚠️ `get_full_text()` **故意返回原文**（带 `[center]`）：`main` 拿它当
  「这一句的身份证」去查已读记录，剥了标记就对不上了。
  断言「标记没漏到画面上」要查 `_text_label.text`，不是它。

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
  "backlog": [ { "speaker": "alice", "text": "明天，要不要一起走？" } ],
  "cycle": { "cycle": 2, "advance_pending": false }
}
```

读档顺序（`main.gd._load_slot`）：`CycleManager.from_save_dict` → `GameManager.from_dict` → `Stage.restore_state` → `runner.restore_state`。最后一步会重新执行 `ip` 指向的那条指令，于是那句对白/那个选项原样重现。

`cycle` 是**唯一**进存档的跨周目字段（只含当前周目数与挂起标记）。通关记录与
`carry` 继承数据留在 `user://cycle.json`，见 5.18。

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
│   ├── autoload/                    Config / Game / Cycle / Collection / Audio / Save
│   │                                / ReadTracker / RouteTracker / I18n
│   ├── stage/stage.gd               演出层（背景 / 立绘 / CG / 转场）
│   ├── stage/screen_fx.gd           全屏特效层（排在 UI 之上）
│   ├── ui/                          对话框 / 选项 / 回看 / 设置 / 存读 / 标题
│   │   │                            / 鉴赏 / CG 详情 / 音乐 / 锁图标 / 主题
│   │   │                            （唱片 / 频谱两个控件留档，当前未接线）
│   │   └── text_effects/            自定义文字特效（弹跳 / 错乱 / 闪烁）
│   └── minigames/                   基类 + 节奏 QTE
├── shaders/
│   ├── transition.gdshader          转场遮罩（溶解 / 擦除 / 百叶窗 / 圆形）
│   ├── screen_fx.gdshader           全屏后处理（错乱 / 扭曲 / 马赛克 / 色差 / 反色 / 模糊）
│   └── char_expr.gdshader           立绘表情交叉过渡
└── tools/
    ├── smoke.gd / smoke.tscn        headless 回归测试（827 项断言）
    ├── capture.gd / capture.tscn    自动截图工具（14 张）
    ├── cycle_demo.gd / .tscn        多周目界面验收（标题 / 记录面板 / 调试台）
    ├── button_compare.tscn          按钮样式前后对比（拼接图）
    ├── text_fx_demo.tscn            文字特效多帧演示（拼接图）
    ├── motion_demo.tscn             立绘缓动位移多帧演示（拼接图）
    ├── stage_demo.tscn              转场 / 多立绘演示（拼接图）
    └── stage_grid.tscn              立绘坐标网格预览（100px 网格 + 锚点 / 脚底线）
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
# 回归测试 · headless（827 项断言，快，适合 CI）
godot --headless --path . res://tools/smoke.tscn

# 回归测试 · 窗口模式（832 项，多覆盖「真实输入模拟」一节）
godot --path . res://tools/smoke.tscn

# 自动截图（窗口模式，14 张）
godot --path . res://tools/capture.tscn

# 多周目界面验收（造「第 2 周目 + 通关 3 次」的现场，验标题与记录面板的显示；
# headless 只跑断言，窗口模式另外出两张图）
godot --headless --path . res://tools/cycle_demo.tscn

# 立绘坐标网格预览（窗口模式，调 x= / y= / scale= 时用它，附实测坐标输出）
godot --path . res://tools/stage_grid.tscn

# 按钮样式前后对比（窗口模式，出一张拼接图）
godot --path . res://tools/button_compare.tscn

# 文字特效多帧演示（窗口模式，出一张拼接图）
godot --path . res://tools/text_fx_demo.tscn

# 立绘缓动位移多帧演示（帧间距能看出加速）
godot --path . res://tools/motion_demo.tscn
```

冒烟测试覆盖：Autoload 注册 → 剧本解析与跳转回填 → **外观配置（配色 / 字号 / 按钮预设 / 九宫格贴图通路 / 未定义预设回退 / 文字颜色覆盖 / 按钮音效挂载与触发链路）** → **文字特效与打字节奏（时间轴编译、停顿、变速、标签剥离、边界与精度、二分查表、特效注册与时间片行为）** → **演出动效（hop / zoom / shake / screen_shake / screen_flash / screen_fx 的解析与行为、缓动生效、被打断后从基准位重启、clear 复位）** → 调度器控制流（if/else、choice、call/return、flag、affection、minigame、ending）→ 存档往返（含 JSON 整数还原）→ 立绘定位 → 序章端到端跑通并断言最终好感度为 44 → 自动播放/跳过的连续性 → 标题读档 → 「继续游戏」恢复精度 → 鉴赏系统（注册表、主题、解锁语义、落盘往返、锁图标数量、曲目高亮、可视化控件）与剧情重播（片段边界、快照还原、自动存档闸门）→ **转场遮罩与滑入滑出（四种转场模式映射、滑入起点在屏幕外、滑入时 alpha 给满、剧本 type 参数解析）** → **多立绘协同（说话人亮 / 他人压暗 / 旁白全亮）** → **玩家便利（已读追踪、跳过已读语义、已读文本变暗、存档删除与覆盖确认、存档缩略图读写与清理、隐藏 UI）** → **回滚（缓冲区边界与分支截断、快照采集、回退 / 前进、退到选项处改选、滚轮输入、设置开关）** → **音频（BGM 循环开关、语音队列的入队 / 接力 / 打断 / 缺素材跳过）** → **标记不外漏（回看 / 存档预览里不得残留 `[wait]` `[speed]`）** → **剧本路径解析（语言回退、逻辑路径不变、非剧本路径放过）** → **全屏特效（种类表与 mode 一一对应、持续 / 脉冲两种语义、层必须排在 UI 之上、BackBufferCopy 恰好在前一位、未知种类被拒且不顶掉当前特效、模态面板自动压下、四个复位点、回滚能还原）** → **着色器静态检查（入口函数不得出现 return）** → **架构守卫（分层规则 + 守卫自检）** → **真实输入模拟** → **指令端到端覆盖（每条指令都真的经调度器跑一遍）**。

**关于「多周目」**：第 30 节专测周目推进时机、`carry` 继承的两阶段（标记 → 通关取值 → 新周目写回）、
`cycle` / `cleared` 条件求值，以及存档只带「当前周目」这一条不变式。
界面侧另有 `tools/cycle_demo.tscn` —— 逻辑全对但界面没接线的 bug 只有它抓得到
（它第一次跑就抓出了记录面板里 i18n 占位符写成 `%s` 的问题）。

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
