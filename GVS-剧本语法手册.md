# GVS 剧本语法手册

> GVS = **G**algame **V**isual **S**cript。行式纯文本剧本语言，写在 `data/scripts/` 下的 `.gvs` 文件里。
> 本文由 `scripts/core/gvs_parser.gd`（权威实现）+ `DESIGN.md` §4 + `README.md` 汇总而成，
> 比 `DESIGN.md` §4 更全（补全了动效 / 转场 / 全屏特效 / 视频 / 文字特效 / 多周目 / 素材约定）。
> 两者冲突时，**以解析器代码为准**。

---

## 0. 一句话模型

解析器把行式文本编译成 **扁平指令数组 + 标签索引表**。
条件块与选项块会被编译成 `branch_false` / `jump` 跳转指令，
所以运行期只有一个整数指令指针（`ip`）——**这也是存档只存一个整数就能恢复进度的原因**。

---

## 1. 文件与词法规则

| 规则 | 说明 |
|---|---|
| 位置 | `data/scripts/*.gvs`。入口固定 `prologue.gvs`（名字写死，不能改/删） |
| 编码 | UTF-8，纯文本，无 BOM 更好 |
| 换行 | 按 `\n` 切行；行首行尾空白被 `strip_edges()` 去掉，**缩进只是给人看的，不参与语义** |
| 制表符 | `\t` 会先被替换成空格 |
| 空行 | 忽略，不产生指令 |
| 注释 | `#` 开头。**只有行首、或 `#` 前面是空格/制表符时才算注释** |
| 十六进制颜色 | `screen_flash color=#ff0000` 里的 `#` **不会**被当注释（靠上一条规则保护） |
| 引号 | `"..."` 或 `'...'` 包起来的整段算一个词，内部的空格 / `#` 保留 |
| 分词 | 按空格切，**连续空格视为一个分隔符**（`split(" ", false)`） |

> ⚠️ 因为按空格分词，`key=value` 形式的参数**值里不能有空格**。
> 想带空格的文本只能放在「吃掉整行剩余部分」的指令里（`narr` / `chapter` / `ending` / `set` 的值 / 对白正文），或加引号。

### 字面量类型推断（`literal()`）

用于 `set` 的值、`flag` 的值、条件里的比较值、`minigame` 参数：

| 写法 | 类型 |
|---|---|
| `"文字"` / `'文字'` | String（去引号） |
| `true` / `false` | bool |
| `null` / `nil` | null |
| `10` | int |
| `1.5` | float |
| 其他 | String（原样） |

---

## 2. 对白与旁白（不是关键字就走这里）

一行如果**行首不是保留关键字**，就按「对白 / 旁白」解析：

| 写法 | 结果 |
|---|---|
| `角色: 文本` | 对白，说话人 = `角色` |
| `角色@表情: 文本` | 对白，**同时切表情**（等价于 `expr 角色 表情`） |
| `narr 文本` / `narration 文本` | 旁白 |
| `"文本"` / `'文本'`（整行带引号） | 旁白 |
| 其他裸行 | 旁白（speaker 为空） |

对白识别条件（必须同时满足）：
- 行里能找到 `:`，且 `:` **不在第 0 位**（`colon > 0`）；
- `:` 前面那段（前缀）**不含空格**，且**长度 ≤ 24**；
- 不满足就整行当旁白。

`@` 切分规则：前缀里 `@` 的位置 > 0 时，`@` 前是角色、`@` 后是表情。

```gvs
alice: 早上好。
alice@smile: 又是游戏。
narr 四月的风从半开的窗户灌进来。
"也可以直接写引号旁白。"
```

---

## 3. 完整指令表

### 3.1 结构与流程

| 指令 | 语法 | 说明 |
|---|---|---|
| `label` | `label <名字>` | 定义跳转目标。**同名重复 = 错误** |
| `chapter` | `chapter <标题>` | 设置当前章节名，显示在存档槽摘要上（标题 = 该行剩余全部文本，可带空格/引号） |
| `jump` / `goto` | `jump <标签>` | 无条件跳转（同文件） |
| `call` | `call <标签> [参数…]` | 调用子过程（有调用栈）。参数见 §3.8 |
| `return` | `return` | 从子过程返回（参数随帧弹掉） |
| `jump_file` | `jump_file <路径> [标签]` | 切换剧本文件（如 `res://data/scripts/chapter1.gvs chapter1_start`） |
| `if` / `elif` / `else` / `end` | `if <条件>` | 条件块，可嵌套。`elif`/`else` 无对应 `if`、或多余 `end` = 错误 |
| `together` … `end` | 见 §3.9 | 演出并行组：块内同时启动，块结束等最长的那条 |
| `choice` … `end` | 见 §4 | 选项块 |
| `minigame` | `minigame <id> [k=v ...]` | 调用小游戏，参数以字典传入 |
| `ending` | `ending <id> [标题]` | 结局，**终止剧本**。标题 = `id` 之后的全部文本 |

### 3.2 状态 / 变量 / 多周目

| 指令 | 语法 | 说明 |
|---|---|---|
| `set` | `set [var] <变量> <值>` | 赋值，值走类型推断。`set var hp 10` 与 `set hp 10` 等价 |
| `add` / `sub` | `add [var] <变量> <数值>` | 数值增减（`sub` = `add` 取负） |
| `flag` | `flag <名字> [true\|false]` | 置/清旗标，**不写值默认 `true`** |
| `affection` | `affection <角色> <增减值>` | 好感度增减，可负 |
| `carry` | `carry <flag\|var\|affection> <名字>` | 标记「下一周目继承它」，见 §6 |

### 3.3 画面 / 立绘

| 指令 | 语法 | 默认值 |
|---|---|---|
| `bg` | `bg <id> [type=] [fade=]` | `type=fade`，`fade=0.4` |
| `show` | `show <角色> [expr=] [at=] [type=] [fade=] [x=] [y=] [scale=]` | `expr=normal`，`at=center`，`type=fade`，`fade=0.3` |
| `hide` | `hide <角色> [type=] [fade=]` | `type=fade`，`fade=0.3` |
| `move` | `move <角色> [位置] [fade=] [ease=] [x=] [y=] [scale=]` | `fade=0.35`，`ease=out_cubic` |
| `expr` | `expr <角色> <表情> [fade=]` | `fade=0.18`（shader 交叉混合，不是硬换图） |
| `clear` | `clear` | 清空背景与全部立绘，并复位 World 位移 / 缩放 / 闪光 |
| `cg` | `cg <id> [fade=] [type=]` | `fade=0.5`，`type=fade`。**展示并计入收藏** |
| `hide_cg` | `hide_cg [fade=] [type=]` | `fade=0.4`，`type=fade`。退场遮罩反向走一遍 |

### 3.4 立绘动效

| 指令 | 语法 | 默认值 |
|---|---|---|
| `hop` | `hop <角色> [height=] [times=] [duration=]` | `height=40`，`times=2`，`duration=0.7` |
| `zoom` | `zoom <角色> <倍数> [duration=] [ease=]` | `duration=0.4`，`ease=out_back`（**以脚底为轴**缩放） |
| `shake` | `shake <角色> [strength=] [times=] [duration=]` | `strength=28`，`times=5`，`duration=0.45` |
| `anim` | `anim <角色> [speed=] [pause=] [once=] [frame=]` | `speed=1.0`，`pause=false`，`once=false`，`frame=-1` |

> `hop` 是「兴奋小跳」，**不要用 `jump`**——`jump` 已被标签跳转占用。

### 3.5 全屏 / 画面级

| 指令 | 语法 | 默认值 |
|---|---|---|
| `screen_shake` | `screen_shake [strength=] [times=] [duration=]` | `strength=36`，`times=5`，`duration=0.45`（舞台 + UI 一起震） |
| `screen_flash` | `screen_flash [color=] [duration=]` | `color=#ffffff`，`duration=0.25` |
| `screen_fx` | `screen_fx <种类\|none> [strength=] [duration=]` | `strength=1.0`，`duration=0.8`；**种类写错直接报错** |
| `bg_motion` | `bg_motion [scale=] [x=] [y=] [duration=] [ease=]` | `scale=1.0`，`x=0`，`y=0`，`duration=6.0`，`ease=in_out_cubic` |
| `weather` | `weather <none\|rain\|snow\|sakura> [intensity=]` | `intensity=1.0`；**种类写错静默降级**（不报错，注意） |

### 3.6 视频 / 音频 / 语音

| 指令 | 语法 | 默认值 |
|---|---|---|
| `video` | `video <id> [at=] [size=] [layer=] [fade=] [volume=] [speed=] [buffer=] [loop=] [wait=] [hide=]` | `at=full`，`layer=world`，`fade=0.0`，`volume=1.0`，`speed=1.0`，`buffer=120`，`loop=false`，`wait=false`，`hide=true` |
| `hide_video` | `hide_video [fade=]` | `fade=0.3` |
| `bgm` | `bgm <id\|stop> [volume=] [fade=]` | `volume=0.8`，`fade=1.0`。播放时自动解锁该曲目 |
| `se` | `se <id> [volume=]` | `volume=1.0` |
| `voice` | `voice <id> [volume=]` | `volume=1.0`。**写在台词前面** |
| `audio_fx` | `audio_fx <音轨> <效果> [duration=] [strength=] [pitch=]` | `duration=0.8`，`strength=1.0`，`pitch=1.0`。见 §7.11 |

### 3.7 等待 / 收藏

| 指令 | 语法 | 说明 |
|---|---|---|
| `wait` | `wait <秒>` | 计时等待（负数钳到 0） |
| `wait_click` / `pause` | — | 等待玩家点击 |
| `unlock` | `unlock <类型> <id>` | 只解锁收藏，不改画面。类型见 §9 |

### 3.8 子过程参数与台词插值

`call` 可以带参数，两种写法可混用：

```gvs
call 打招呼 who=alice count=2      # 具名 → 子过程里写 {$who} / {$count}
call 打招呼 alice 2                # 位置 → 子过程里写 {$1} / {$2}
call 打招呼 who=alice 2            # 混用也行（先查具名，再查位置）
```

参数**作用域是局部的**：随调用帧压栈，`return` 时一并弹掉。
所以嵌套调用里的同名参数不会互相串味，也不会污染调用方的变量；
查找顺序是「内层优先」。

**台词 / 章节名 / 结局标题里可以插值**（`{$…}`）：

| 写法 | 取值 |
|---|---|
| `{$名字}` | 先查 call 参数（内层优先），再查剧本变量（`set` / `add` / `sub`） |
| `{$1}` `{$2}` | call 的**位置参数** |
| `{$affection.角色id}` | 好感度当前值 |
| `{$flag.旗标名}` | 旗标（`true` / `false`） |

```gvs
set 好感 17
call 打招呼 who=alice
narr 你好，{$who}。
alice: 我的好感度是 {$affection.alice}，变量是 {$好感}。
chapter 第 {$章数} 章
ending true_end "给 {$who} 的答案"
```

四条要注意的：

1. **查不到时原样保留 `{$名字}`，不会变成空串** —— 名字写错时你在对话框里
   直接看到 `{$好感度}` 印出来，比「那句台词少了半句」好查得多。
   `tools/audit` 也会把「没有任何 `set` / `call` 参数写过的插值名」报成 warning。
2. **整数不显示小数点**：`set n 3` 之后 `{$n}` 是 `3`，不是 `3.0`
   （存档 JSON 会把整数读回 float，这里统一格式化掉了）。
3. **变量名可以是中文**，`{$好感}` 完全合法。
4. 插值发生在**剧本调度器**里，所以回看面板、存档预览、已读标记看到的
   都是替换后的文本，不用各自再实现一遍。

### 3.9 演出并行组 `together`

GVS 的演出指令本来就是「启动即返回」（Tween 在后台跑），所以「同时发生」
不用特别支持。真正缺的是**「等这一组都跑完再继续」** —— 以前只能手写一个
`wait`，而那个数字要跟着每个 `duration` 一起改，非常脆。

```gvs
together
    bg rooftop type=dissolve fade=1.2
    show alice transition=slide_left fade=1.0
    bgm sunset fade=1.5
end
narr 转场结束后才出现的旁白。
```

- 块内指令**同时启动**，块结束**等最长的那条**跑完（上面是 1.5 秒）。
- 可选的 `duration=` 覆盖等待时长：`together duration=3`（固定等 3 秒）、
  `together duration=0`（只启动、不等）。
- **块内只允许非阻塞的演出 / 音频指令**：
  `bg` `cg` `hide_cg` `show` `hide` `move` `expr` `hop` `zoom` `shake`
  `screen_shake` `screen_flash` `screen_fx` `bg_motion` `weather` `anim`
  `video`（不能带 `wait=true`）`hide_video` `bgm` `se` `voice` `audio_fx`
  `set` `add` `sub` `flag` `affection` `carry` `unlock`。
  写别的（`narr` / `wait` / `jump` / `if` / `choice` …）是**解析期错误**，
  不会静默忽略。
- `together` 不能嵌套。
- 它是**计时等待**，点击不能跳过（和 `wait` 一样）。

---

## 4. 选项块（choice）

```gvs
choice
    "「游戏也是艺术。」" -> defend_games
    "「……我错了。」"    -> admit_fault
end
```

- `choice` 与 `end` 之间，**任何非空非注释行都被当作一个选项**（所以这里不能写别的指令）。
- 每个选项必须是 `"选项文本" -> 标签` 形式；缺 `->` = 错误。
- 选项文本可用引号也可不用；标签在解析结束时统一回填（**可以指向文件里任意位置的标签，包括后面才定义的**）。
- 块结束处会记录 `fallthrough` = `end` 的下一行下标（选项都不跳时继续往下走）。

---

## 5. 条件表达式

```
if <条件>
```

| 条件写法 | 含义 |
|---|---|
| `flag <名>` | 旗标为真 |
| `not flag <名>` | 旗标为假 |
| `<名>`（裸标识符） | 等价 `flag <名>` |
| `affection <角色> <比较符> <值>` | 好感度比较 |
| `var <变量> <比较符> <值>` | 变量比较 |
| `cycle <比较符> <周目数>` | 当前周目数比较（多周目，1 起） |
| `cleared <结局id>` | 该结局通关过没有（跨周目记录） |
| `clear <结局id>` | `cleared` 的别名 |
| 以上任意一条加 `not` 前缀 | 取反 |

比较符：`==` `!=` `>` `<` `>=` `<=`。
**两侧都能解析成数字时按数值比较，否则按字符串比较。**

```gvs
if affection alice >= 10
    alice@smile: ……不过，你今天倒是挺老实的。
elif affection alice >= 0
    alice@normal: 算了。
else
    alice@angry: 哼。
end

if flag rhythm_qte_cleared
    ...
end

if not flag talked_to_alice
    ...
end

if var stance == "yield"
    ...
end

if cycle >= 2
    ...
end

if cleared true_end
    ...
end
```

---

## 6. 多周目（NG+）

**两个可用条件**：`cycle <cmp> <n>`、`cleared <结局id>`（可加 `not`）。

**`carry` —— 标记「下一周目继承什么」**：

```gvs
carry flag <旗标名>        # 下一周目保留这个旗标
carry var <变量名>         # 下一周目保留这个变量
carry affection <角色id>   # 下一周目保留这个角色的好感度
```

语义要点：
- `carry` **只是打标记**，取值发生在**抵达结局那一刻**（`CycleManager.record_ending`）。
  所以把它写在剧本哪一行都不影响结果 —— 继承的永远是「这一周目结束时」的值。
- 周目数 `cycle` 从 1 起；`record_ending()` 只置「待推进」，真正的 `cycle += 1` 发生在**下一次开新游戏**（`begin_new_run`）。
- 通关记录 / 继承数据落盘 `user://cycle.json`，**与存档分离**；但「当前周目」会随存档走。
- 本周目一个 `carry` 都没声明时，**保留上一周目的继承数据**（不视为清空）。

> ⚠️ 重播片段里不要写多周目台词。`chapter1.gvs` 里 `if cleared true_end` 那两行刻意放在
> `cg_true_end_end` **之后**，否则鉴赏重播这段 CG 时会莫名多出一句二周目台词。

---

## 7. 演出细节规格

### 7.1 站位槽位（`at=`）

| 槽位 | 比例 | 说明 |
|---|---|---|
| `left` | 0.22 | 左 |
| `center` | 0.50 | 中（默认） |
| `right` | 0.78 | 右 |
| `off_left` | -0.15 | 屏幕外左侧「离场槽」 |
| `off_right` | 1.15 | 屏幕外右侧「离场槽」 |

设计分辨率 **1920×1080**；立绘框 `CHAR_WIDTH=560`，默认脚底线 `y=1130`。

### 7.2 绝对坐标（`show` / `move` 可选键）

| 键 | 含义 |
|---|---|
| `x` | 立绘**框中心**的设计像素 X |
| `y` | 立绘**脚底**的设计像素 Y（调小 = 人往上站/显高显远） |
| `scale` | **基准缩放**（角色设定，进存档），与 `zoom` 的动画倍率相乘 |

- 三个都可选：**不写就回到 `at=` 预设与默认底线 1130**，旧剧本不受影响。
- 「没写的轴回到默认」而不是沿用上一次 —— `show alice x=500` 之后再 `show alice at=left`，位置是干净的预设位。
- `move alice x=960 y=1130` 时 `at` 留空 = 只覆盖坐标、不动预设槽。
- 调坐标用 `tools/stage_grid.tscn`（100px 网格 + 坐标刻度 + 预设锚点线）。

### 7.3 转场（`type=`，用于 `bg` / `cg` / `hide_cg`）

| `type` | 效果 |
|---|---|
| `fade` | 交叉淡入（默认） |
| `dissolve` | 噪声阈值逐块显现 |
| `wipe` | 从左到右扫过 |
| `blinds` | 百叶窗，叶片从下往上展开 |
| `circle` | 从画面中心扩散 |
| `none` | 直接切换 |

退场时遮罩**反向走一遍**（`hide_cg type=blinds` 也出图案）。

### 7.4 立绘入场 / 出场（`type=`，用于 `show` / `hide`）

| `type` | 效果 |
|---|---|
| `fade` | 淡入淡出（默认） |
| `slide_left` | 从屏幕左侧外滑入 |
| `slide_right` | 从屏幕右侧外滑入 |
| `slide_up` | 从画面下方滑入 |
| `none` | 直接出现 / 消失 |

> 滑入时 alpha 直接给满，不做「边滑边淡入」。`hide` 用 `slide_*` 即「朝该方向滑出」。

### 7.5 缓动（`ease=`，用于 `move` / `zoom` / `bg_motion`）

`linear` / `in_quad` / `out_quad` / `in_cubic` / `out_cubic`（默认）/ `in_out_cubic` /
`in_quart` / `out_quart` / `out_back` / `out_elastic` / `out_bounce`。

未识别的名字回退到 `out_cubic`。

### 7.6 全屏特效 `screen_fx` 种类

`glitch` / `wave` / `swirl` / `pixelate` / `chromatic` / `invert` / `blur` / `none`（关闭）。

- `strength` 默认 1，建议 0.5~1.5；`2` 以上基本是花屏。
- `duration` 默认 0.8（脉冲）；**写 `0` = 持续**，直到 `screen_fx none` / 下一条 `screen_fx` / 读档 / 回标题。
- **连 UI 一起变形**（这一层在对话框与 HUD 之上）；任何模态面板一打开特效自动收起。
- ⚠️ 种类写错**直接报错**（不像 weather 静默降级）——防止「写了却演不出来」。

### 7.7 天气 `weather` 种类

`none` / `rain` / `snow` / `sakura`；`intensity` 默认 1.0。程序化生成，无需素材。

### 7.8 视频 `video`

- `at`：`full`（默认，铺满）/ `center`（按 `size` 居中）/ `x,y`（左上角坐标）。
- `size`：`宽,高`（如 `size=640,360`）。
- `layer`：`world`（默认，对话框之下）/ `ui`（盖住对话框与 HUD）/ `top`（最上层）。**写错报错**。
- `wait=true` 时调度器停在这里等播完（可点击跳过）。
- `buffer` 默认 **120ms**（Godot 默认 500ms 会让过场先黑一下）。
- **素材必须是 Ogg Theora `.ogv`**（内置只认这一种，无 alpha）。转换：
  `ffmpeg -i in.mp4 -c:v libtheora -q:v 7 -c:a libvorbis -q:a 5 out.ogv`
- 素材缺失不会卡死，`wait=true` 也照样放行。

### 7.9 动态立绘（帧序列）

不需要指令：把 `assets/sprites/<角色>/<表情>/` 建成帧序列目录（`00.png` / `01.png` …，
可选 `anim.json`：`{"fps": 12, "loop": true}`），`show <角色> expr=<表情>` 就会动。
帧数上限 **256**（`AnimatedTexture` 限制）。用 `anim` 指令控制播放：

```gvs
anim alice speed=0.5      # 慢放
anim alice pause=true     # 定格在当前帧
anim alice once           # 只播一遍，停在最后一帧
anim alice frame=3        # 跳到第 3 帧（0 基）
anim alice                # 恢复常速循环
```

> Godot **没有动图解码器**：GIF 不认，APNG 只取第一帧，动画 WebP 连第一帧都解不出。
> 动态图唯一可靠路线就是帧序列。

### 7.10 语音 `voice`

```gvs
voice alice_001          # 写在台词「前面」，会被认领成这一句的语音
alice: 早上好。
```

- 播完**点对话框上的名字牌可重播**这一句。
- 同一句里连写多条 `voice` → **依次排队播完**。
- 玩家推进到下一句 → 上一条立刻中断、队列清空（防声画错位）。
- 无素材静默跳过，不报错。
- **玩家可以在设置里按角色静音**（设置面板 → 角色语音）。语音 id 是
  `<角色>/<台词>`，取斜杠前那一段作为角色 id；静音后该角色所有语音都不播
  （包括点名字牌重播），但台词照常显示。列表存 `user://config.json`，跨存档保留。

### 7.11 音频效果器 `audio_fx`

给 BGM / 音效 / 语音**三条音轨分别**挂效果器。三条音轨是分开的独立总线，
所以「让音乐出故障」不会把语音一起弄坏。

```gvs
audio_fx <音轨> <效果> [duration=] [strength=] [pitch=]
audio_fx <音轨> off
```

| 音轨 | 说明 |
|---|---|
| `bgm` | 背景音乐（`music` 是别名） |
| `se` | 音效（`sfx` 是别名） |
| `voice` | 语音（`vo` 是别名） |
| `all` | 三条一起 |
| `master` | 总输出（会把 UI 音效也带上，慎用） |

| 效果 | 听感 | 实现 |
|---|---|---|
| `glitch` | 数字故障、断续跳变 | LOFI 失真 + 音高抖动（90ms 时间片跳变） |
| `error` | 损坏 / 错误音 | LOFI 失真 + 音高乱跳 + 低通扫频 |
| `distortion` | 过载失真 | OVERDRIVE |
| `pitch` | 移调（变尖 / 变沉） | PitchShift，倍数看 `pitch=` |
| `muffle` | 闷住（隔墙 / 捂住嘴） | 低通 700Hz |
| `underwater` | 水下 | 低通 380Hz + 混响 |
| `radio` | 无线电 / 对讲机 | 带通 + 软失真 |
| `echo` | 回声 / 延迟 | 延迟 180ms + 回授 |
| `reverb` | 混响（大厅 / 教堂） | Reverb |
| `amplify` | 增益（强调 / 耳鸣） | 音量 +3dB×强度 |
| `none` / `off` / `clear` | 清除该音轨上挂的效果 | — |

- `duration=0` 表示**持续到显式清除**（`audio_fx <音轨> off`）；不写默认 0.8 秒后自动清除。
- **同一音轨上效果器是互斥的**：新的一次会先清掉上一次，链不会越挂越长。
- 音轨名或效果名拼错是**解析期错误**（`tools/audit` 会让 CI 非零退出），不会静默无声。
- 想在**台词显示的中间**触发，用内联标签 `[fx=…]`，见 §8.3。
- 回标题 / 读档会清掉全部效果器，不会把「故障」带到下一幕。

```gvs
bgm tension
audio_fx bgm glitch duration=2.0
alice: 屏幕上跳出一行乱码……
audio_fx bgm off
audio_fx voice pitch pitch=0.7 duration=1.5
```

---

## 8. 文字特效与打字节奏（写在台词正文里）

### 8.1 可用特效标记

| 标记 | 效果 | 常用参数 | 来源 |
|---|---|---|---|
| `[shake]` | 抖动 | `rate` `level` | Godot 内置 |
| `[wave]` | 波浪 | `rate` `level` | Godot 内置 |
| `[rainbow]` | 彩虹变色 | `freq` `sat` `val` | Godot 内置 |
| `[pulse]` | 脉冲变色 | `freq` `color` | Godot 内置 |
| `[fade]` | 淡入淡出 | `speed` `min_alpha` | Godot 内置 |
| `[tornado]` | 旋风 | `radius` `freq` | Godot 内置 |
| `[flip]` | 翻转 | `h` `v` | Godot 内置 |
| `[bounce]` | 弹跳 | `speed` `height` | 项目自定义 |
| `[glitch]` | 错乱/故障 | `rate` `strength` `tint` | 项目自定义 |
| `[blink]` | 闪烁 | `speed` `min_alpha` | 项目自定义 |
| `[color=#ff0000]` | 固定颜色 | — | BBCode |
| `[bgcolor=#333333]` | 背景色 | — | BBCode |

### 8.2 打字节奏标记（**不占可见字符**）

| 标记 | 作用 |
|---|---|
| `[wait=0.5]` | 在此处停顿 0.5 秒后**自动**继续 |
| `[pause=0.3]` | 同上（别名，另有 `delay`） |
| `[speed=3]...[/speed]` | 这一段按 3 倍速逐字显示 |
| `[stop]` | 在此处**停下等点击**，点了才接着显示（别名 `[click]`） |
| `[fx=glitch]` | 在此处触发一次音频效果器，见 §8.3 |

- 基准速度 = 设置里的「文字速度」（默认 45 字/秒），`[speed=N]` 是相对倍数。
- 单字等待有 **0.35 秒上限**（`[speed=0.001]` 也不会把节奏拖死）。
- 节奏标记只在对话框里生效；**回看面板 / 存档预览显示的是剥掉标记后的文本**。
- 特效标记与节奏标记可混用且对齐正确。

**点击推进的落点**：玩家点击时**不是**直接显示全文，而是快进到**下一个停顿点**
（`[wait]` 或 `[stop]`），后面没有停顿点了才补完整句。想回到「一点就显示全文」的老手感，
在设置里关掉「点击先跳到下一个停顿」。跳过 / 自动播放仍是一次给全（不会卡在停顿上）。

```gvs
alice@angry: [shake rate=14 level=5]你们两个！[/shake]
narr [bounce height=13]弹跳[/bounce] · [blink]闪烁[/blink] · [glitch strength=5]错乱[/glitch] · [rainbow]变色[/rainbow]
alice: 这一句[speed=3]三倍速冲过去[/speed]，然后[wait=0.9]停顿一下，再恢复正常速度。
alice: 那个……[stop]（点了才继续）
```

### 8.3 内联音频效果器 `[fx=…]`

在台词**显示的中间**给某条音轨挂一次效果器。写在要触发的那个字**之后**。

```
[fx=<效果> bus=<音轨> dur=<秒> strength=<强度> pitch=<移调>]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `<效果>` | `glitch` | 见 §7.11 的效果器表；`off` 表示清除 |
| `bus=` | `bgm` | `bgm` / `se` / `voice` / `all` / `master` |
| `dur=` | `0.6` | 秒；`0` = 持续到显式 `[fx=off]` |
| `strength=` | `1.0` | 强度倍数 |
| `pitch=` | `1.0` | 仅 `pitch` 效果用；>1 变尖、<1 变沉 |

```gvs
alice: 这……这不可能[fx=glitch bus=voice dur=0.5]！
narr 广播里传来一阵[fx=radio bus=bgm dur=1.2]失真的声音。
alice: 你……你是谁[fx=pitch bus=voice dur=0.6 pitch=1.8]？
```

---

## 9. 收藏 / 解锁 / 可重播片段

- `cg <id>` 展示 CG 时**自动解锁**；`bgm <id>` 播放时**自动解锁**该曲目；
  `video <id>` 播放时**自动解锁**该段影片。
- `unlock <类型> <id>` 只解锁、不改画面。类型：`cg` / `music` / `video`
  （结局由 `ending` 自动记录）。注册表分别在 `data/collection/cg.json` /
  `music.json` / `video.json`。
- **可重播片段**用成对标签界定，并在 `data/collection/cg.json` 的 `replay` 里引用：

```json
{
  "id": "cg_classroom",
  "title": "教室·清晨",
  "image": "res://assets/cg/cg_classroom.png",
  "replay": {
    "file": "res://data/scripts/prologue.gvs",
    "label": "cg_classroom",
    "end_label": "cg_classroom_end"
  }
}
```

```gvs
label cg_classroom
cg cg_classroom fade=0.9
narr ……
label cg_classroom_end
hide_cg fade=0.6
```

- 重播只跑 `[label, end_label)`，在终点处停下，**不会真的触发 `ending` 与 `unlock`**。
- 片段里 `call` 子过程也安全（靠调用栈守卫，不会把「跳进子过程」误判成「已播完」）。
- 重播起止标签在静态校验里算「入口」，不会被当成死代码。

---

## 10. 小游戏

```gvs
minigame rhythm_qte rounds=5 need=3 speed=1.5
if flag rhythm_qte_cleared
    ...
end
```

- `minigame <id>` 的 id 来自 `scripts/core/minigame_registry.gd` 的 `REGISTRY`（现只有 `rhythm_qte`）。
- 参数以字典原样传给小游戏场景。
- 小游戏 `finish({"success": true, ...})` 后，**成功会点亮旗标 `<id>_cleared`**，供剧本判定。

---

## 11. 结局与章节

```gvs
ending good "并肩的归途"
ending bad "说不出口的话"
```

- `ending <id> [标题]`：**终止剧本**；标题 = `id` 之后整行剩余文本。
- 抵达结局时会：置旗标 `ending_<id>`、记入通关记录（`CycleManager`）、按 `carry` 标记快照继承数据。
- ⚠️ 不要在 `ending` 后面写 `title=xxx` 之类的 `k=v` —— 解析器会把它们**原样并进标题文本**。
- `chapter <标题>` 设置章节名，显示在存档槽；章节解锁靠 `chapters.json` 里的 `unlock_flag`，
  必须由剧本 `flag` 置位（如 `flag __chapter1_unlocked`），否则该章在章节选择里永远是灰的
  （静态校验会检查「声明了 unlock_flag 却没人设置」）。

---

## 12. 素材与命名约定

```
assets/
├── bg/<id>.png                    背景，1920×1080
├── cg/<id>.png                    CG 事件图，1920×1080
├── sprites/<角色>.png             立绘整图
├── sprites/<角色>/<表情>.png      立绘差分（优先级更高）
├── sprites/<角色>/<表情>/00.png   帧序列（动态立绘，可选 anim.json）
├── video/<id>.ogv                 过场视频（只认 Ogg Theora）
├── ui/<名字>.png                  UI 素材
├── fonts/<名字>.ttf|otf
├── audio/bgm/<id>.ogg|mp3|wav
├── audio/se/<id>.ogg|mp3|wav
└── audio/voice/<角色>/<台词>.ogg|mp3|wav   ← 语音是两级目录，id = <角色>/<台词>
```

- **找不到真实素材会自动生成占位图**（色相由 id 哈希派生，同一 id 颜色稳定），代码零改动。
- 新增角色会**自动复制一张 `normal.png` 占位** —— `normal` 是默认表情，缺了会掉进火柴人占位。
- 多语言：`data/scripts/en/<同名>.gvs` 即英文版，对外统一用逻辑路径。
- `data/characters.json` 是**角色名册**（id + 显示名），设置面板的「角色语音静音」
  按它列角色；漏登记的角色仍会被 `assets/sprites/` 目录扫描兜底列出。

---

## 13. 默认值速查表

| 指令 | 默认 |
|---|---|
| `bg` | `type=fade` `fade=0.4` |
| `show` | `expr=normal` `at=center` `type=fade` `fade=0.3` |
| `hide` | `type=fade` `fade=0.3` |
| `move` | `fade=0.35` `ease=out_cubic` |
| `expr` | `fade=0.18` |
| `hop` | `height=40` `times=2` `duration=0.7` |
| `zoom` | `duration=0.4` `ease=out_back` |
| `shake` | `strength=28` `times=5` `duration=0.45` |
| `screen_shake` | `strength=36` `times=5` `duration=0.45` |
| `screen_flash` | `color=#ffffff` `duration=0.25` |
| `screen_fx` | `strength=1.0` `duration=0.8` |
| `bg_motion` | `scale=1.0` `x=0` `y=0` `duration=6.0` `ease=in_out_cubic` |
| `weather` | `intensity=1.0` |
| `anim` | `speed=1.0` `pause=false` `once=false` `frame=-1` |
| `video` | `at=full` `layer=world` `fade=0.0` `volume=1.0` `speed=1.0` `buffer=120` `loop=false` `wait=false` `hide=true` |
| `hide_video` | `fade=0.3` |
| `cg` | `fade=0.5` `type=fade` |
| `hide_cg` | `fade=0.4` `type=fade` |
| `bgm` | `volume=0.8` `fade=1.0` |
| `se` / `voice` | `volume=1.0` |
| `audio_fx` | `duration=0.8` `strength=1.0` `pitch=1.0` |
| `together` | `duration=-1`（= 不写，用块内最长的那条；写 `0` = 只启动不等） |
| `flag` | `value=true` |

内联标记默认值：`[wait]` / `[pause]` 无默认（必须写秒数）；`[stop]` 无参数；
`[fx=…]` 的 `bus=bgm` `dur=0.6` `strength=1.0` `pitch=1.0`。

---

## 14. 静态校验（`ScriptAudit`）会查什么

跑 `tools/audit`（可作 CI）时，剧本层面的错误 / 警告包括：

- 解析错误（未闭合的 `if` / `choice` / `together`、`elif`/`else` 无 `if`、多余 `end`、缺参数、`screen_fx` 未知种类、`audio_fx` 未知音轨 / 未知效果器、`video` 未知图层、`carry` 未知类型、`together` 里写了阻塞指令……）
- 悬空跳转（`jump`/`call`/选项指向不存在的标签）
- 未使用的标签（入口 `start`、CG/音乐 `replay` 起止标签、章节入口标签除外）
- 重复结局 id、章节 `unlock_flag` 无人设置
- **台词插值 `{$名字}` 没有任何 `set` / `call` 参数写过它**（否则玩家会看到原样的 `{$名字}`）
- 素材缺失清单（`bg` / `cg` / 立绘 / 音频 / 视频）

---

## 15. 常见坑

1. **`#` 注释只在行首或空格后才生效** —— 但颜色值 `#ff0000` 前通常没有空格，安全；若你写 `x=1#注释` 则不会截断。
2. **`k=v` 的值不能有空格**（按空格分词）。带空格文本用引号或走「吃整行」的指令。
3. **`hop` 不是 `jump`**；`jump` 是标签跳转。
4. **`weather` 种类写错静默降级成 none，`screen_fx` / `video layer` 写错直接报错** —— 别指望 weather 报错。
5. **`ending` 后面别写 `k=v`**，会被并进标题。
6. **重播片段里别放多周目 / 状态类台词**，否则鉴赏重播会污染体验（虽不真触发 `ending`）。
7. **`voice` 写在台词前**，写在后面就成了下一句的语音。
8. **`choice` 块内除了 `->` 选项不能写别的**（空行与注释除外）。
9. **`show` 没写的轴回到默认**（不沿用上一次），改坐标别指望「半沿用」。
10. **`scale`（角色基准，进存档）与 `zoom`（临时倍率）是两回事**，0.5 基准再 `zoom 2.0` = 屏幕 1.0。
