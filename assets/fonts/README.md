# 字体放这里

把 `.ttf` / `.otf` / `.woff2` 丢进这个目录，然后在 `data/ui/ui_theme.json` 里填路径：

```json
"fonts": {
  "body":     "res://assets/fonts/你的正文体.ttf",
  "title":    "res://assets/fonts/你的标题体.otf",
  "dialogue": "res://assets/fonts/你的对白体.ttf"
}
```

| 键 | 管什么 |
|---|---|
| `body` | **界面 / 系统字体** —— 所有 Label、按钮、开关、下拉、回看、存档、设置…（不显式指定字体键的都走它） |
| `title` | 标题界面的主标题与副标题 |
| `dialogue` | 对话框里的**对白正文**与说话人名牌（调试控制台也用它） |

- **留空 = 用 Godot 内置字体**（它不带 CJK 字形，中文靠引擎的系统字体回退渲染）。
  想完全掌控字形就三个键都填上。
- 字号在同一个文件的 `font_sizes` 段（`dialogue` / `speaker` / `backlog` / `button` /
  `label` / `small` / `title` / `subtitle` / `heading`），**不需要改代码**。
- 路径写 `res://` 开头。文件不存在 / 载入失败会 `push_warning` 并**回退到默认字体**，
  不会崩、也不会变成空白。

## 只想改一个地方

个别控件可以自己 `add_theme_font_override(...)` 覆盖（见 `scripts/ui/ui_theme.gd`
的 `apply_font`）。要新增一类字体键，在 `fonts` 段加一个键、调用处传键名即可。

⚠️ 给 `RichTextLabel` 挂字体要写 **`normal_font`**（它没有 `font` 这个主题项）——
写错了不报错、只是不生效。`UiTheme.apply_font` 已经处理了这一层。
