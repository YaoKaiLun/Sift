# Sift 图片 diff 预览设计文档

**日期**：2026-09-13
**状态**：已确认，待转化为实施计划
**基线**：计划二已落地的单文件 diff / 连续滚动 / 文件级暂存
**产品规格**：本文件只补图片预览。定位、性能预算、视觉规范仍以 `2026-09-12-sift-design.md` 为准；冲突时以本文件为准。

---

## 1. 范围

单文件右栏：可解码的光栅图按 SourceTree 方式预览（改过的左右对比，新增只看新、删除只看旧）。中栏文件级暂存不变。

明确不做：

- 连续滚动里嵌图片（仍用「二进制文件」文字占位，`.image` 与 `.binary` 同一文案）
- SVG、滑动对比、洋葱皮、像素差、缩放滑杆、GIF 动画
- 把非图片二进制当图预览，或把任意二进制字节渲成文本 diff

---

## 2. 硬约束：二进制不当文本、不当图

除「扩展名命中且该侧字节能被系统解码成图」之外，二进制内容只表现为「二进制文件」。

具体：

- 未跟踪的 `.bin`、含 NUL 的无扩展名文件、git 报 `Binary files` 的非图片：`DiffContent.binary`，**禁止**走现在的 UTF-8「整文件新增」路径。
- 扩展名是图片但解码失败、两侧都读不到、或按下面规则放弃预览：同样 `.binary`，右栏空状态「二进制文件」。**禁止**把 PNG/JPEG 字节填进 hunk 文本。
- 图片扩展名的路径**永远不要**变成 `DiffContent.textual`，即使 `git diff` 偶尔给出文本 hunk。
- 连续滚动不预览，只写「二进制文件」。不在 `NSTextView` 里贴图，也不 dump 字节。

---

## 3. 认图规则

路径最后一段扩展名（大小写不敏感）属于下列集合，才进入图片预览通道：

`png`、`jpg`、`jpeg`、`gif`、`webp`、`heic`、`heif`、`tiff`、`tif`、`bmp`

不认 SVG。不按 MIME、不按 magic bytes 认图。扩展名不在集合内的，即使内容是 PNG，也当普通二进制。

图片扩展名跳过 `GeneratedFileDetector` 的 500KB / 行数折叠（截图很容易超过 500KB）。`dist/` 等路径规则仍然折叠。单侧原始字节超过 **20MB** 时该侧不读入内存。

---

## 4. 数据模型

`DiffContent` 增加：

```swift
case image(ImageDiff)

public struct ImageDiff: Sendable, Equatable {
    public let old: ImageSide?
    public let new: ImageSide?
}

public enum ImageSide: Sendable, Equatable {
    case bytes(Data)
    case tooLarge(byteCount: Int)
}
```

- 两侧都是 `nil`：不要用 `.image`，回落 `.binary`。
- 某一侧缺失（新增无旧、删除无新）用 `nil`，不是空 `Data`。
- 某一侧存在但超过 20MB：`.tooLarge`，另一侧仍可 `.bytes`。
- GitKit / DiffEngine 只存字节，不解码、不依赖 AppKit。解码在 SiftUI。
- `LoadedDiff.estimatedBytes`：`.image` 按两侧 `Data.count` 之和计（`tooLarge` 计 128 字节），以便 LRU 把大图挤出去。`.binary` 维持小常数。

`FileDiff.hunks` / `estimatedByteCount` 对 `.image` 仍视为空（与 `.binary` 相同）。图片没有 hunk 按钮。

---

## 5. 旧 / 新字节从哪来

`GitRepository` 增加只读 blob API，全部离开主线程：

| 方法 | 实现 | 缺失时 |
|------|------|--------|
| 工作区文件 | `Data(contentsOf:)` | 返回 `nil`（删除） |
| index | `git show :path`（与 blame 一样，revision 语法，不要把 `--` 插在 spec 前面） | 非零退出 → `nil` |
| HEAD | `git show HEAD:path` | 非零退出 → `nil` |

读之前先拿体积（工作区用 `attributesOfItem`；blob 用 `git cat-file -s`）。超过 20MB 不读内容，记 `.tooLarge`。

按当前选中的 staged 侧决定旧/新：

| 场景 | 旧 | 新 |
|------|----|----|
| 未跟踪 | 无 | 工作区 |
| 已暂存新增 | 无 | index |
| 未暂存删除 | index | 无 |
| 已暂存删除 | HEAD | 无 |
| 未暂存修改 | index | 工作区 |
| 已暂存修改 | HEAD | index |
| 未暂存重命名 | index 的 `originalPath` | 工作区的 `path` |
| 已暂存重命名 | HEAD 的 `originalPath` | index 的 `path` |

`DiffEngine.load`：

1. 路径规则折叠：照旧，图片也折叠。
2. 否则若是图片扩展名：按上表取两侧，得到 `.image` 或（两侧皆空）`.binary`。**不要**先 `git diff` 再猜。未跟踪图片禁止 `fileContents` → String。
3. 否则若未跟踪：先读前 8KB，含 NUL → `.binary`；否则维持现有整文件新增文本。500KB 折叠规则只作用于这条文本路径。
4. 否则：现有 `repository.diff`。若结果是 `.textual` 但扩展名是图片，改走步骤 2。若结果是 `.binary` 且扩展名是图片，改走步骤 2。非图片 `.binary` 保持 `.binary`。

切换文件 / worktree 时，在途的 blob 读取与其它读任务一样取消。

---

## 6. 右栏 UI

`DiffPane` 在 `loadedDiff == .ready` 且 `content == .image` 时渲染 `ImageDiffView`，**不**走 `DiffDocumentBuilder` / `DiffTextView`。`.binary` 维持现在的「二进制文件」空状态。

`ImageDiffView`：

- **两侧都有**（含一侧 `.tooLarge`）：左右两列，左旧右新。列宽各一半。图按列宽等比缩小、不裁切；比栏高则该列纵向滚动。
- **只有一侧**：该侧居中，不留空列。
- `.bytes`：`NSImage(data:)` 成功则显示；失败则该侧视为无效。两侧都无效时整栏回落「二进制文件」。
- `.tooLarge`：该侧文字「图片过大，无法预览」，写出体积。
- 每张成功解码的图下方一行：`宽 × 高 · 体积`（体积用 KB/MB，整数）。
- 透明通道：浅色棋盘格；深色模式用系统背景上的深浅格。
- GIF：第一帧静图。
- 栏头仍是文件名 + 目录。图片没有行，blame 按钮与连续滚动一样禁用。解释面板对图片无选区，不出现「解释这段」。
- 无 hunk 按钮。整文件暂存 / 取消暂存 / 丢弃只通过中栏。

解码失败、读失败、非图片二进制：文案统一为「二进制文件」，不要「无法显示图片」之类第二套文案（过大除外，因为用户明确知道那是图，只是太大）。

---

## 7. 连续滚动

`DiffDocumentBuilder.appendReadyDiff`：`.image` 与 `.binary` 都追加「二进制文件\n」。不把 `Data` 嵌进 attributed string。连续模式仍会 `DiffEngine.load`，因此大图会进 `DiffCache`；靠现有 50MB LRU 淘汰，不为连续模式再做一套延迟加载。

---

## 8. 测试

对着 `FixtureRepo`，不测 SwiftUI。

| 用例 | 期望 |
|------|------|
| 未跟踪最小合法 PNG | `.image`，`old == nil`，`new == .bytes`，且 `new` 不是把 PNG 当 UTF-8 拆出来的 hunk |
| 已跟踪 PNG 工作区修改（unstaged） | `.image`，旧 = 提交/index 侧字节，新 = 工作区字节 |
| 已跟踪 PNG `git add` 后看 staged | 旧 = HEAD，新 = index |
| 删除已跟踪 PNG（unstaged） | 只有旧 |
| 未跟踪 `.bin`（含 NUL） | `.binary`，零 hunk |
| git 报 Binary 的非图片 | `.binary` |
| 扩展名 `.png`、内容是随机二进制 | 引擎可给出 `.image` 字节；UI 解码失败回落「二进制文件」（引擎层不断言解码）。另测：该路径不得出现 `.textual` |
| 单侧 > 20MB 的假大文件（可用稀疏/截断夹具或把上限注入为很小的测试值） | 该侧 `.tooLarge`，不把 20MB 读进 `Data` |
| 普通 `.txt` 未跟踪 | 仍为整文件新增 `.textual`（回归） |

`GitRepository` 单测：index / HEAD / 工作区三侧读取；缺失路径返回 `nil`；`tooLarge` 阈值可在测试里注入（生产默认 20MB）。

UI 不写自动化测试。

---

## 9. 模块边界

| 模块 | 职责 |
|------|------|
| GitKit | `ImageDiff` / `ImageSide` / `DiffContent.image`；blob 读取；8KB NUL 判断公开给 DiffEngine 或保持内部并提供 `fileData` |
| DiffEngine | 认扩展名、选旧/新侧、20MB、未跟踪二进制短路、缓存体积 |
| SiftUI | `ImageDiffView`；解码与棋盘格；`.binary` 空状态；连续滚动占位 |
| RepoStore | 不改选中/暂存流程；`loadedDiff` 已能承载新 case |

零第三方依赖。最低 macOS 26。
