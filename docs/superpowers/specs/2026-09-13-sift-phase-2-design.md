# Sift 计划二设计文档

**日期**：2026-09-13
**状态**：已确认，转化为实施计划
**基线**：`feat/review-ops`（含计划一核心阅读器与 UI 打磨）
**产品规格**：本文件只补计划一未落地的能力。产品定位、性能预算、视觉规范仍以 `2026-09-12-sift-design.md` 为准；冲突时以本文件为准（计划一落地后的拍板）。

---

## 1. 范围

四个可独立交付的切片，按依赖顺序做。每一刀结束应用都能用，性能门禁数字不放宽。

| 切片 | 做什么 | 不做 |
|------|--------|------|
| **A. 审查操作** | 文件级勾选暂存/取消暂存；hunk 级 Stage / Unstage / Discard；未跟踪文件丢弃需确认 | rebase、commit、push、冲突解决 |
| **B. 读 diff** | 统一/分栏切换、正则语法高亮、复制时去掉行号 | tree-sitter、第三方主题 |
| **C. AI 解释** | 选中行 → 右侧滑出面板；OpenAI 兼容流式；Keychain 存 key；设置页三项 | agent 循环、tool calling、跨模型 review |
| **D. 浏览模式** | 连续滚动、blame 侧槽（默认关）、三栏宽度持久化 | 在 blame 上再加「解释这段历史」 |

仍明确不做：commit graph、分支管理、远端与凭证（AI key 除外）、键盘驱动工作流。

---

## 2. 全局约束（沿用计划一）

- 最低 macOS 26。零第三方依赖。
- 主线程永不调用 git。写操作与读操作一样走 `GitRunner`，后台执行。
- 永不轮询。FSEvents 100ms 抖动窗口保留。
- 切换文件 / 仓库 / worktree 时，在途的 **读** 任务立即取消。写操作不取消：一次只允许一个在途写；写进行中再点按钮直接忽略。
- 语法高亮只改属性，不重建 text storage，不重置滚动位置。
- 所有操作鼠标可达。
- 字体：SF Pro / SF Mono。配色走系统语义色；diff 增删色沿用现有 Asset。
- 减弱动态效果：AI 面板改为直接显示，不滑出。动效 ≤ 200ms。

---

## 3. 切片 A：审查操作

### 3.1 文件级

中栏每个文件行最左侧加复选框，与状态字母并列、独立热区。点复选框只改暂存状态，不改变当前选中文件。点行的其余区域仍是选中并打开 diff。

| 分组 | 复选框 | 点击动作 |
|------|--------|---------|
| 已暂存 | 勾上 | `git restore --staged -- <path>` |
| 未暂存 | 空 | `git add -- <path>` |
| 未跟踪 | 空 | `git add -- <path>` |

重命名文件按 git 给出的当前路径操作。二进制、权限-only、空 diff 同样走文件级，没有 hunk 按钮。

### 3.2 hunk 级

只对 `DiffContent.textual` 且至少有一个 hunk 的文件显示。hunk 头部 hover 时出现按钮（不做键盘流，必须看见才能点）：

| 当前分组 | 按钮 |
|---------|------|
| 未暂存 | `暂存此块`、`丢弃此块` |
| 已暂存 | `取消暂存此块` |

未跟踪文件按「整文件新增」渲染，**只提供文件级操作**，不挂 hunk 按钮。对未跟踪文件执行丢弃等于删除文件，必须弹确认：标题「删除未跟踪文件？」正文含路径，说明此操作无法从 git 恢复。确认后删除该路径。已跟踪文件的 discard 不弹框。这是全应用唯一的确认对话框。

折叠中的生成文件：中栏复选框仍可用；右栏没有 hunk 按钮，直到用户点「仍要查看」。

### 3.3 patch 构造

`Hunk.patchText` 已存在并经 `git apply --check` 验证。本切片补一层 `PatchBuilder`（纯函数，放 `GitKit`）：

- 输入：`FileDiff`（或 path / originalPath / 是否新文件/删除）、一个 `Hunk`。
- 输出：完整 unified patch，含 `diff --git`、`---`、`+++` 与该 hunk 的 `patchText`。
- 新文件：`--- /dev/null`、`+++ b/<path>`。
- 删除文件：`--- a/<path>`、`+++ /dev/null`。
- 重命名：`a/<originalPath>`、`b/<path>`。

执行：

- 暂存 hunk：`git apply --cached` 喂构造出的 patch。
- 取消暂存 hunk：同一 patch，`git apply --cached -R`。
- 丢弃未暂存 hunk：`git apply -R`（工作区）。

`git apply` 必须在仓库根目录执行，stdin 传入 patch。非零退出把 stderr 写进现有 `errorMessage` 弹窗，不静默吞。

### 3.4 写成功之后

1. 使该路径两侧（staged + unstaged）的 `DiffCache` 失效。需要给 `DiffEngine` / `DiffCache` 增加按 `worktree + path` 失效的方法；现有 `invalidate(worktreePath:)` 会清掉整个 worktree，粒度太粗，写一个文件不应丢掉别的缓存。
2. 立刻 `refreshFileList()`。不等 FSEvents 的 100ms。
3. 若当前选中文件仍在对应分组，重新 `select(file:staged:)` 加载新 diff；若该侧已消失，清空选中。
4. 不保留滚动位置。

### 3.5 测试

对着 `FixtureRepo`：

- 单文件部分 hunk 暂存：status 变成两侧都有该文件；再 unstage 回去。
- 同一文件先有 staged 再有 unstaged 时，从正确一侧 apply。
- 丢弃未暂存 hunk 后工作区该段回到 HEAD。
- 未跟踪文件 `git add` 后进入已暂存。
- 未跟踪删除走独立方法（测试直接调删除，不测 SwiftUI 确认框）。
- 二进制文件没有 patch，只测文件级 `add` / `restore --staged`。
- apply 失败（故意喂坏 patch）抛 `GitError.nonZeroExit`。

UI 本身不写自动化测试。

---

## 4. 切片 B：读 diff

### 4.1 分栏视图

`DiffDocumentBuilder.build` 增加 `layout: DiffLayout` 参数，`.unified` | `.split`。统一视图保持现有「一个长文档」模型。

分栏产出两份文档：

- 左：删除行 + 上下文；旧行号一列。
- 右：新增行 + 上下文；新行号一列。
- 两侧 hunk 头文字相同、行数对齐（一侧缺行时插入等高空白行），才能纵向对上。
- 两个 `NSTextView` 共用纵向滚动（同步 `documentVisibleRect.origin.y`）；横向各自滚。
- hunk hover 按钮只挂左边（或一条跨两栏的覆盖层），同一 hunk 不得出现两套 Stage。

默认仍是统一视图。Diff 栏头用与「平铺/树」同类的 `PlainIconToggle` 切换。偏好写入 `state.json` 的 `usesSplitDiff: Bool`，默认 `false`。

### 4.2 语法高亮

新建 `Highlighter` 模块，**不引入 tree-sitter**（零依赖约束压过原架构图里的 tree-sitter）。

- 主线程外执行，可取消。只返回 `[(NSRange, NSColor)]`，不持有文本副本以外的状态。
- 语言按文件扩展名：`.swift`、`.js` / `.mjs` / `.cjs`、`.ts` / `.tsx`、`.py`、`.go`、`.json`、`.jsonc`、`.sh` / `.bash` / `.zsh`、`.md`。认不出则跳过，保留 diff 底色。
- `Highlighter` 只返回 `[(Range<Int>, TokenKind)]`（`keyword` / `string` / `comment` / `number` / `type`），不依赖 AppKit。输入是**去掉 gutter 之后的代码文本**。`SiftUI` 把 token 色映射到系统色并盖回代码列。
- 行号宽度不是常数：超过 9999 行时 `pad` 会变宽。因此 gutter 必须打上自定义 `NSAttributedString.Key`（例如 `.siftRole = gutter`），高亮和复制都按属性跳过，禁止写死「10 个字符」。
- `+/-` 标记与行文本一起着色。
- 高亮是第三遍：先 `DiffDocumentBuilder` 铺好 diff 底色、gutter 与 role 属性，再把 token 色盖到 foreground。过期任务丢弃结果。
- 切换文件取消在途高亮。`DiffTextView` 已有 attribute-only 更新路径，高亮必须走它。

颜色用系统语义色（`systemBlue`、`systemPurple`、`systemOrange`、`systemGreen`、`systemPink`、`secondaryLabelColor`），浅色/深色各自成立，不自建色板。

### 4.3 复制去行号

`NSTextView` 的 copy 拦截：按 `.siftRole == gutter` 丢掉行号列，保留 `+/-` 标记和正文。hunk 头整行保留。分栏里的空白对齐行不进剪贴板。

---

## 5. 切片 C：AI 解释

### 5.1 交互

在 diff 文本里选中至少一行后，选区附近浮出「解释这段」。点击后从右侧滑出 AI 面板，挤压 diff 区域（已确认可接受）。未配置（base URL、API key、模型名任一为空）时不发请求，直接打开设置。

面板内容：

- 流式输出 Markdown 纯文本（按等宽/常规文本渲染即可，不做完整 Markdown 预览器）。
- 底部输入框可对**同一选区**追问。
- 切换选区、切换文件、切换 worktree：丢弃当前对话，新开一轮。
- 进行中的流在切换时取消。

### 5.2 请求上下文

每次请求带：

1. 文件路径
2. 选中行（去掉 gutter 后的文本）以及选区前后各 8 行上下文
3. 该文件当前完整 diff（`FileDiff` 的 textual 还原，或当前 `git diff` 文本；以已经加载的 `FileDiff` 为准，不再发一次 git）
4. 同一选区的此前问答（追问时）

### 5.3 协议与存储

新建 `AIClient` 模块。

- `protocol ExplainProvider`：输入上下文 + 历史，返回 `AsyncThrowingStream<String, Error>`。
- 唯一实现 `OpenAICompatibleProvider`：`POST {baseURL}/chat/completions`，`stream: true`，解析 SSE `data:` 行里的 `choices[0].delta.content`。
- 设置三项，**全部默认空**：base URL、API key、模型名。不预填任何服务商。
- API key 存 Keychain（`kSecClassGenericPassword`，service `app.sift.explain`，account `api-key`），不落 `state.json`。base URL 与模型名可以进 `state.json`。
- 设置入口：标准 macOS Settings 窗口（`Settings` scene），三项文本框；key 用 `SecureField`。侧边栏外观切换保留，不搬进设置。

错误（网络、4xx/5xx、超时）显示在面板内，不占用全局 `errorMessage` 弹窗。

### 5.4 测试

- SSE 解析：多 chunk、`[DONE]`、缺字段、非 JSON 行跳过。
- 未配置时 provider 不发网络请求（用假 URLSession 断言）。
- Keychain 读写在测试里用可注入的 `KeychainStore` protocol，默认实现打真实 Keychain；测试注入内存假实现。

---

## 6. 切片 D：浏览模式

### 6.1 连续滚动

Diff 栏头再一个 `PlainIconToggle`：单文件 / 连续。默认单文件。偏好 `usesContinuousDiff: Bool`，默认 `false`。

连续模式：

- 当前 worktree 当前分组规则下的**全部**改动文件拼成一篇文档（已暂存、未暂存、未跟踪按中栏同样顺序）。
- 每个文件先用 `--numstat` 的廉价占位头（路径 + `+N −M`），进入视口后才 `DiffEngine.load` 并展开。
- 折叠规则仍生效：生成文件先占位，点「仍要查看」再展开。
- 切回单文件：只渲染当前选中文件，取消连续模式里在途的展开任务。
- 中栏点击文件：连续模式下滚到该文件头；单文件模式仍是替换文档。

文本层继续按「一个长文档」设计，不引入第二个渲染引擎。

### 6.2 Blame

默认关。Diff 栏头一个可见开关。打开后：

- 对当前文件（连续模式则对进入视口的文件）在后台跑 blame，可取消。
  - 未暂存：工作区版本，`git blame -p -- <path>`。
  - 已暂存：index 版本，`git show :path` 的内容喂给 `git blame -p --contents - -- <path>`。
- 行号左侧多一列短名（作者名截到 8 字符）。点一行弹出 popover：作者、时间、完整 commit message、该 commit 的完整 diff（`git show --format=medium <sha>` 取 header，`git show --format= <sha>` 取 patch）。超大 / 生成文件的 commit diff 走与主视图相同的折叠规则。
- 未跟踪文件、纯新增行没有 blame，侧槽留空。
- 切文件、关开关、切 worktree：取消在途 blame。
- 不调 AI。

Blame 解析为纯函数 `BlameParser`，对着 fixture 仓库测：改过的行、未改的行、二进制跳过。

### 6.3 栏宽持久化

`PersistedState` 增加 `sidebarWidth`、`fileListWidth`（`CGFloat`/`Double`）。`ContentView` 的两个 `@State` 改为从 `RepoStore` 读写，拖动结束时 persist。缺省仍是现在的 220 / 300。范围不变：侧栏 180...340，文件列表 240...520。

---

## 7. 模块与依赖

```
GitKit          + PatchBuilder, StageOperations, BlameParser, GitRepository 写方法
DiffEngine      + 按路径失效缓存；连续模式用的占位头模型可放这里
Highlighter     新模块，只依赖 Foundation；TokenKind → 颜色的映射在 SiftUI
AIClient        新模块，零 UI
RepoStore       写操作、偏好、设置字段、选区对话状态
SiftUI          复选框、hunk overlay、分栏、面板、设置、blame 槽
```

依赖方向不变：GitKit ← DiffEngine ← RepoStore ← SiftUI；Highlighter 与 AIClient 只被 SiftUI / RepoStore 使用，互不引用。

`Package.swift` 增加 `Highlighter`、`AIClient` 两个 library 与对应 test target。

---

## 8. 持久化字段增量

`PersistedState` 现有：`repositoryBookmarks`、`selectedWorktreePath`、`usesTreeView`、`appearance`。

新增（全部有缺省，旧 `state.json` 能读）：

- `usesSplitDiff: Bool = false`
- `usesContinuousDiff: Bool = false`
- `showsBlame: Bool = false`
- `sidebarWidth: Double = 220`
- `fileListWidth: Double = 300`
- `explainBaseURL: String = ""`
- `explainModel: String = ""`

API key 不在此列。

---

## 9. 成功标准

1. 用户可以只靠鼠标完成「看完一块 → 暂存或丢掉」而不切到 Sourcetree。
2. 分栏与高亮不造成滚动跳变；复制出去的文本没有行号。
3. 填好三项设置后，选中几行能流式看到解释，换选区是新对话。
4. 连续滚动打开一个有几十个改动文件的 worktree 时，未进入视口的文件不跑 `git diff`。
5. `./Scripts/preflight.sh` 仍通过，阈值不放宽。
