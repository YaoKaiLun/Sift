# Sift 设计文档

**日期**：2026-09-12
**状态**：已确认，待转化为实施计划

---

## 1. 背景

日常工作流是在 Cursor 里让 AI 写代码，然后人工审查产出。小改动直接看 Cursor 的行内 diff；改动一大就切到 Sourcetree，因为它的 diff 视图更清晰——一个列表看全所有改动文件、点开单个文件独立查看、平铺和树视图可切、hunk 级别可以暂存或丢弃。

但 Sourcetree 有两个致命问题：

1. **慢。** 它本身是原生 Cocoa 应用，慢的原因不是语言而是架构——给每个书签仓库挂定时器轮询、列表虚拟化差、libgit2 和 shell out 混用。
2. **对多项目、多 worktree 的支持很差。** 并行跑多个 AI agent 时，每个 agent 占一个 worktree，Sourcetree 只能把它们当成互不相关的独立仓库挂上去，没有"这几个 worktree 是同一个项目的不同分身"这个概念。

与此同时，Git 操作本身已经不是痛点——解冲突、rebase 这类事情都交给 AI 处理了。所以需要的不是一个更好的 Git 客户端，而是一个**专门的代码审查阅读界面**。

### 市场调研结论

调研了 2026 年主流的 Git GUI、AI 代码解释工具和 review 类桌面应用，市场明确分为三个阵营，**中间那块是空的**：

**阵营一，快的原生 Git GUI**（Fork、Tower、Sublime Merge、Gitfox、TinyGit、TheGit）：解决了性能，但对多仓库的答案是标签页或书签——回答的是"我怎么跳到 B 仓库"，不是"把多个来源统一组织起来"。全都没有 AI 解释。worktree 最多是侧边栏里一个列表项。

**阵营二，AI 解释历史的工具**（git-why、git-explain-tui、Git Time Traveller、Entire.io、whyso）：解决了"为什么改"，但全是 CLI 或编辑器插件，没有独立的图形界面，也没有仓库管理。

**阵营三，为 agent 时代做的本地 review 应用**（diffreview、Local Code Review、GitClear Diff Digest）：diff 阅读体验好，但都假设"在一个仓库里 review 一个分支"，没有仓库列表。

**Cursor 自身的覆盖情况**（决定了哪些功能不值得做）：

- Agent Review 已经是本地版 Bugbot，跑在未提交改动上，可 commit 后自动触发或 `/agent-review` 手动触发；`/review-bugbot` 和 `/review-security` 能在推送前调真正的 Bugbot；`.cursor/agents/` 里的 subagent 可以钉死 `model:` 实现跨模型审查。**结论：跨模型交叉 review 不做，做不过它。**
- Cursor Blame 能显示某行的 AI 归属和当初那次对话的摘要，但**仅 Enterprise 版且默认关闭**。所以自建 blame 有意义，但不紧急。
- worktree 在 Agents Window 里是一等公民，但**官方文档中没有任何 worktree 列表或切换 UI**，IDE 里要去终端敲 `git worktree list`。**这个缺口是真实的。**

### 定位

Sift 的价值**不在 AI，在"读"本身**。核心是一个快的、干净的、能同时管住多仓库和多 worktree 的 diff 阅读面。AI 解释是附加的便利层，不是护城河。

---

## 2. 产品定义

### 做什么

- 多仓库 + 多 worktree 的层级化切换
- 改动文件的平铺 / 树视图
- 清晰的单文件 diff，统一视图与分栏视图可切
- hunk 级别的 stage / discard
- 选中若干行，向 AI 提问"这段改动在做什么、为什么"

### 明确不做

commit graph、分支管理、rebase、merge、冲突解决、push / pull / fetch、远端与凭证管理、跨模型交叉 review、改动总览摘要、键盘驱动的工作流。

不做键盘流是用户的明确要求（记不住快捷键）。这意味着**所有操作必须鼠标可达**：hover 出按钮、可见的复选框、明确的点击目标。可以提供快捷键作为加速，但不能有任何功能只能通过快捷键触发。

### 为什么 stage / discard 不违反"不做 Git 管理"

在审查 AI 代码这个语境下，stage 和 discard 不是版本管理操作，是**审查结论**："这段我认了" / "这段 agent 写错了，扔掉"。它们属于 review 流程，因此保留；而 rebase、push 这些属于版本管理，因此排除。

---

## 3. 界面设计

### 3.1 布局

三栏结构。

**左栏：来源列表**

手动添加的仓库，每个仓库下面挂它自己的 worktree，通过 `git worktree list --porcelain` 发现，主工作树排第一。每一项右侧一个角标显示改动文件数（staged + unstaged + untracked）。

这一栏是 Sift 相对所有现有产品最大的结构性区别：**worktree 不是独立仓库，是某个项目的分身，视觉上必须体现这个从属关系**。缩进层级、角标、以及每个 worktree 显示它所在的分支名。

**中栏：改动文件**

- 平铺 / 树视图切换
- Staged / Unstaged / Untracked 分组
- 每个文件：状态标记（M/A/D/R）、路径、`+N −M` 行数
- 每个文件前一个复选框，控制该文件整体暂存 / 取消暂存
- 单击选中，右栏切换到该文件

**右栏：diff**

- 默认单文件视图
- 统一视图 / 分栏视图可切
- 每个 hunk 头部，hover 时出现 `Stage hunk` / `Discard hunk`
- 选中若干行后浮出"解释这段"，点击从右侧滑出 AI 面板
- 生成文件与超大文件默认折叠为占位条

**同一文件同时出现在 Staged 和 Unstaged 时**

Git 允许一个文件既有已暂存的改动又有未暂存的改动。此时该文件在两个分组中各出现一次，从哪个分组选中就显示哪一份 diff——Staged 分组显示 `git diff --cached -- <file>`，Unstaged 分组显示 `git diff -- <file>`。hunk 上的操作按钮随之变化：Staged 分组下是 `Unstage hunk`，Unstaged 分组下是 `Stage hunk` / `Discard hunk`。

**未跟踪文件**

未跟踪文件没有 diff，整个文件按"全部新增"渲染，同样受生成文件与大文件折叠规则约束。对未跟踪文件执行 discard 等于**删除文件**，因此必须弹确认框；已跟踪文件的 discard 是可以从 git 恢复的，不弹框。这是 v1 中唯一的确认对话框。

**AI 面板**

从右侧滑出，挤压 diff 区域（已确认可接受，换取后续扩展空间）。流式输出。提问上下文包含：文件路径、选中行的前后文、该文件当前的完整 diff。支持在同一选区上继续追问，形成一个作用域限定在该选区的对话。切换选区开新对话。

### 3.2 视觉规范

"简约又不失精致、现代化、符合 Apple 设计要求"落成可执行的细则：

- **字体**：SF Pro（界面）、SF Mono（代码）。不引入第三方字体。
- **材质**：侧边栏使用系统 vibrancy 材质，跟随 macOS 26 当前的材质系统，而非自绘背景色。
- **窗口装饰**：标准 NSToolbar 与系统窗口 chrome，不做自定义标题栏。
- **配色**：全部基于系统语义色（`NSColor.labelColor`、`controlAccentColor` 等），不自建色板。diff 的增删色需要自定义，但必须分别为浅色和深色模式调校，并通过"增强对比度"设置的检查。
- **深色模式**：不是浅色的反色，两套分别调。
- **无障碍**：尊重"减弱动态效果"（关闭面板滑出动画，改为直接显示）与"增强对比度"。
- **动效**：只用于表达状态转换（面板滑出、折叠展开），不做装饰性动画。时长不超过 200ms。
- **精致的落点**：间距的节奏感、字重的层次、hover 与选中态的细腻过渡。不靠渐变和阴影堆砌。

---

## 4. 性能预算

**性能是本项目的最高优先级。** 下列指标是硬约束，写进 CI，超阈值则构建失败。

| 场景 | 目标 |
|---|---|
| 冷启动到可交互 | < 300ms |
| 切换仓库 / worktree 到文件列表可见 | < 150ms（1000 个改动文件） |
| 点击文件到 diff 可见 | < 100ms（2000 行以内文件） |
| 滚动 | ProMotion 120Hz 下不掉帧 |
| 空闲 CPU | 恒定 0% |
| 挂载 5 个仓库时常驻内存 | < 150MB |

### 保证这些指标的架构规则

1. **主线程上永不调用 git。** `GitRunner` 内置 dispatch 断言，debug 构建下违反直接崩溃。
2. **永不轮询。** 仅依赖 FSEvents，100ms 合并抖动窗口。这是 Sourcetree 最大的原罪。
3. **diff 懒算。** `git status --porcelain=v2 -z` 获取文件列表很便宜；`git diff -- <file>` 仅在用户点开该文件时执行。
4. **LRU 缓存。** 已计算的 diff 缓存，上限 50 个文件或 50MB，先到者为准。
5. **切换即取消。** 切换文件、仓库或 worktree 时，旧选区所有在途的 git 调用与高亮任务立即取消。
6. **重新着色只改属性，永不触发重排版。** 语法高亮以 attribute-only 的方式覆盖到已有 text storage 上，文档布局不变，滚动位置不跳。
7. **生成文件不解析。** 识别规则见下，命中的文件折叠为占位条，不读内容、不算 diff、不做高亮，点击后才加载。

### 生成文件识别规则

按顺序判定，任一命中即视为生成文件：

1. `.gitattributes` 中标记了 `linguist-generated`
2. 路径匹配内置规则：`*.lock`、`*-lock.json`、`*.min.*`、`*.map`、`dist/`、`build/`、`node_modules/`、`vendor/`、`*.pb.go`、`*_generated.*`
3. 文件超过 3000 行或 500KB

内置规则列表可在设置中编辑。

---

## 5. 技术架构

### 5.1 技术选型

**Swift + AppKit / SwiftUI，最低 macOS 26。**

关于为何不用 Rust：语言不是这个应用的瓶颈。时间花在四处——跑 git（git 自身耗时，任何语言都是等子进程）、解析 diff 输出（几 MB 文本，两种语言都是毫秒级）、语法高亮（tree-sitter 是 C，两边都能调）、渲染与滚动（UI 框架的事）。可优化的部分里没有一处受益于 Rust。

更关键的是 Rust 在 macOS 上没有可接受的原生 UI 方案：Tauri 等于绕回 WebView；egui / iced 不像 Mac 应用、文本渲染差、缺原生选中与无障碍；objc2 / cacao 是通过 unsafe FFI 手写 AppKit；GPUI 是 Zed 的内部框架，文档稀疏。而 Swift 直接就是 AppKit——NSTextView 被优化了二十年，文本选中、无障碍、滚动惯性、Retina 渲染全部白送。对一个核心体验就是"读文本"的应用，这些是刚需。

Sourcetree 本身就是原生 Cocoa 应用却依然慢，这个事实说明决定性能的是架构而非语言。

若将来 profile 出具体热点（如超大 diff 的 myers 计算、上万文件的树构建），可单独用 Rust 通过 C ABI 挂入。但那是有性能数据之后的优化，不是起手式。

### 5.2 模块切分

六个模块，各自单一职责，仅通过明确接口通信。

**`GitKit`** —— 子进程调用与输出解析。完全不感知 UI，解析部分全为纯函数。

- `GitRunner`：异步子进程执行，可取消，带超时，主线程断言
- `StatusParser`：解析 `git status --porcelain=v2 -z`
- `DiffParser`：解析 `git diff` 的统一 diff 格式与 `--numstat`
- `WorktreeLister`：解析 `git worktree list --porcelain`
- `StageOperations`：`git apply --cached` 实现 hunk 级暂存，`git checkout --` / `git apply -R` 实现丢弃

这是最容易出 bug 也最容易测的模块。git 输出有大量边角情况——重命名、子模块、文件名中的特殊字符与换行、`-z` 分隔、二进制文件、模式变更。全部对着 fixture 仓库测。

**`RepoStore`** —— 应用状态与持久化。

- 已添加仓库列表、发现的 worktree、当前选中
- FSEvents 监听与失效传播
- 持久化到 `~/Library/Application Support/Sift/state.json`

**`DiffEngine`** —— 把 `GitKit` 的解析结果转为可渲染模型。

- Hunk 模型与行映射
- 生成文件识别
- 按文件懒加载与 LRU 缓存

**`Highlighter`** —— tree-sitter 封装。主线程外执行，可取消，只返回属性区间，不接触文本内容。过期的高亮任务提前退出。

**`AIClient`** —— AI 调用抽象。

- `protocol ExplainProvider`：接收上下文，返回流式文本
- v1 唯一实现 `OpenAICompatibleProvider`：SSE 流式，配置 base URL + API key + 模型名
- API key 存 Keychain，不落磁盘明文

选择 OpenAI 兼容协议而非 pi-ai 的理由：pi-ai 是 TypeScript 包，引入它需要在应用内打包 Node 进程，体积从约 15MB 涨到 60MB 以上，多一个子进程与一层 IPC，直接违背"原生、小、秒开"这个选型前提。而本应用对 AI 层的需求极薄——单次、非 agentic、约 2k token 的解释请求，不需要 tool calling、agent 循环或会话中途换模型，pi-ai 的价值（广度与 agent 能力）一项都用不上。OpenAI Chat Completions 协议被 OpenAI、xAI、Groq、Cerebras、OpenRouter 以及几乎所有自建网关支持，一个 SSE 客户端即可接入上百个模型；想用 Claude 可走 OpenRouter。

通过 protocol 抽象，将来若需要 pi-ai sidecar 或 shell out 到本机 `claude` CLI，只需新增实现，上层不动。

**`SiftUI`** —— 界面层。

SwiftUI 搭外壳（侧边栏、文件列表、工具栏、设置），**diff 视图用 AppKit 的 NSTextView 包进 SwiftUI**。这是 UI 层唯一一处刻意降级到 AppKit，也是最关键的一处：SwiftUI 的文本渲染在超长文档上撑不住，而 NSTextView 提供成熟的文本布局、原生选中与无障碍。

### 5.3 工程结构

```
Sift/
  Package.swift              本地 SwiftPM 包，容纳全部逻辑模块
  Sources/
    GitKit/
    RepoStore/
    DiffEngine/
    Highlighter/
    AIClient/
    SiftUI/
  Tests/
    GitKitTests/
    DiffEngineTests/
    PerformanceTests/
  App/
    Sift.xcodeproj           应用壳，依赖上述本地包
  Scripts/
    make-fixtures.sh         生成测试用 git 仓库
  docs/
```

逻辑全部放在 SwiftPM 包里，Xcode 工程只作为应用壳。这样绝大部分代码可以脱离 Xcode 用 `swift test` 跑，CI 简单，迭代也快。

### 5.4 关于"连续滚动查看所有文件"

用户要求支持这个模式。它不在 v1，但**文本层必须现在就按能支持它的方式设计**——即按"一个长文档"的模型建立 text storage 与渲染路径。否则 v1 用最省事的单文件方式实现后，加连续模式要推倒重来。

连续模式的实现方式：不过滤、所有文件拼成一个文档，每个文件初始为一个从 `--numstat` 拿到的廉价占位头，进入视口时才展开真实内容。这样既满足连续阅读，又不违反懒算原则。

---

## 6. 测试策略

**`GitKit` parser 全覆盖。** 对着 `Scripts/make-fixtures.sh` 在临时目录生成的 git 仓库测试，覆盖重命名、子模块、特殊文件名、二进制文件、模式变更、`-z` 分隔等边角情况。这里是 bug 的主要来源。

**性能测试进 CI，阈值写死，超了挂构建。** 既然性能是最高优先级，就需要有机制在无人注意时守着，否则三个月后它会慢慢变成第二个 Sourcetree。用 XCTest 的 measure block，针对第 4 节的每一项指标写一个测试，配一个大型 fixture 仓库。

**UI 测试不做，手动验证。** 投入产出比不合适。

---

## 7. 范围划分

### v1

- 左栏：仓库 + worktree 层级列表，改动数角标
- 中栏：改动文件列表，平铺 / 树视图切换，Staged / Unstaged / Untracked 分组，文件级复选框
- 右栏：单文件 diff，统一 / 分栏视图切换，hunk 级 Stage / Discard
- 选中行 → AI 解释面板（右侧滑出，流式）
- 生成文件折叠
- 第 4 节全部性能指标达标
- 第 3.2 节全部视觉规范落实

### v2

- blame 侧槽：显示每行最后修改的 commit，点击查看该 commit 的作者、时间、message 与完整 diff。常规实现，不调 AI。
- 连续滚动查看所有文件
- 视需要再考虑：在 blame 基础上加"解释这段历史"的 AI 入口

blame 放 v2 的理由：它服务的是"考古旧代码"，与 v1 核心的"审查新改动"是两个不同场景，放进 v1 会显著扩大范围。

---

## 8. 成功标准

1. 用户在审查大改动时不再需要切到 Sourcetree
2. 并行跑多个 agent 时，切换 worktree 查看各自产出是顺畅的、无需离开应用
3. 第 4 节的每一项性能指标在真实的大型仓库上达标
4. 应用感觉上"像一个精心制作的 Mac 应用"，而非一个工具
