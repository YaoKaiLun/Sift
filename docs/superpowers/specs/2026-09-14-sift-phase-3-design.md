# Sift 计划三设计文档

**日期**：2026-09-14
**状态**：已按「左栏 commit 列表」修订，待确认其余切片
**基线**：`main`（计划二审查操作 / 连续滚动 / blame / 打包已落地）
**产品规格**：本文件只补五项能力。产品定位、性能预算、视觉规范仍以 `2026-09-12-sift-design.md` 为准；冲突时以本文件为准。

---

## 1. 范围

五个可独立交付的切片，按依赖顺序做。每一刀结束应用都能用，性能门禁数字不放宽。

| 切片 | 做什么 | 不做 |
|------|--------|------|
| **A. 分栏线命中** | 文件列表有内容时，改动栏与 diff 栏之间的分隔线全程可 hover、可拖 | 改栏宽范围、改成 `NSSplitView`、改视觉宽度参与布局 |
| **B. 键盘切文件** | 上下方向键在中栏可见文件间切换；Shift+上下做范围多选 | 全面键盘工作流、自定义快捷键、hjkl、只靠键盘完成暂存 |
| **C. 过滤文件** | 可配置 glob 规则；开关一键从中栏（及连续滚动）隐藏命中文件 | 替换生成文件折叠、按路径目录深度过滤、正则 |
| **D. 未推送提交** | 左栏 worktree 下列未推送 commit（可展开收起）；中栏仍是该 commit 的文件 + message；右栏是 diff | push / pull / fetch、完整 commit graph、设上游、累计「全部未推送」视图 |
| **E. 检查更新** | 对照 GitHub Release 检查新版本，下载后提示重启替换 | Sparkle、Apple 公证、增量补丁、自动在后台静默替换且不提示 |

仍明确不做：commit graph、分支管理、rebase、冲突解决、push / pull / fetch。键盘是加速，所有新能力仍须鼠标可达。

### 方案选择（已拍板）

**更新**
1. Sparkle + appcast：成熟，但引入第三方依赖、EdDSA 密钥和额外发版产物；与「零依赖、现有 GitHub Release DMG」冲突。
2. **采用：自研 GitHub Releases 检查 + 下载 DMG + 重启替换。** 与现有 `release.yml` 对齐，UI 模仿 Cursor 的「更新 / 已就绪点击重启」。
3. 只弹浏览器打开 Release 页：实现最便宜，但不是「类似 Cursor」的应用内升级。

**未推送交互**
1. 中栏图标切换工作区 / 累计未推送：互斥模式，工作区会被切走，commit 边界看不见。已否决。
2. 中栏改成 commit 列表：单位对了，但占用了「文件」栏，和三栏分工冲突。
3. **采用：commit 挂在左栏对应 worktree（分支）下面，可展开收起；点某条后中栏仍是文件并展示 message，右栏是该文件相对该 commit 的 diff。** 三栏职责不变。不做「全部未推送」累计视图——要看合计就逐条点，或回到工作区。

**分栏命中**
1. 改用 `NSSplitView`：命中可靠，但会打乱自绘三栏与栏头对齐。
2. **采用：热区放到窗口 overlay，pane `.clipped()`。** 视觉与栏宽语义不变。
3. 让 11pt 参与 HStack 布局：热区稳，但拖动时内容会跟着 11pt 空缝抖。

---

## 2. 全局约束（沿用计划一 / 二）

- 最低 macOS 26。**零第三方依赖**（不引入 Sparkle、Sparkle 的 EdDSA 工具链、tree-sitter）。
- 主线程永不调用 git。网络请求（检查更新、下载 DMG）同样离开主线程。
- 永不轮询 git / FSEvents。更新检查只在启动与用户点「检查更新」时发生，不挂定时器。
- 切换文件 / 仓库 / worktree / 中栏数据源时，在途的**读**任务立即取消。
- 所有操作鼠标可达。快捷键只做加速。
- 字体、配色、动效规则不变。
- `./Scripts/preflight.sh` 必须继续通过，阈值不放宽。
- 注释、提交说明、用户可见文案用中文，与仓库现有风格一致。

---

## 3. 切片 A：分栏线在有文件的区域无法拉伸

### 3.1 现象

中栏（改动文件）与右栏（diff）之间的分隔线：文件行覆盖到的上半段无法 hover / 拖动；文件列表下方的空白处可以。部分机器上更明显。侧栏与中栏之间的那条线有同样风险。

截图标注的「不可 hover 拉伸」对应文件行所在高度，「可 hover 拉伸」对应中栏空白。

### 3.2 根因

`SplitDivider` 布局宽度是 1pt，11pt 热区画在 overlay 里、不参与布局。SwiftUI 命中测试先按**父视图布局框**走：1pt 父框之外的热区，会被左右两个 pane 的布局框抢走。

`FileListPane` 的 `ScrollView` / `LazyVStack` / `.rowSurface`（`contentShape(Rectangle())` + `maxWidth: .infinity`）在有行的高度上吃掉命中；空白处没有行，命中才漏回 1pt 线本身。`.frame(width:)` **默认不裁剪**，行还可以溢到隔壁 1pt 上。不同系统版本对 overlay 溢出命中的处理不一致，所以「部分机器」才复现。

### 3.3 做法

不改成 `NSSplitView`（会动窗口 chrome 与栏头对齐）。也不让热区参与布局（两边内容会抖）。

1. **裁剪**：`SourceSidebar`、`FileListPane`、`DiffPane` 在 `ContentView` 里 `.clipped()`，行不得画到、点到隔壁。
2. **热区提到父级 overlay**：`HStack` 上盖一层与窗口等高的 overlay。填充用 `Color.clear.allowsHitTesting(false)`，只在两条分界处放 11pt 宽的 `SplitDivider`。overlay 盖在所有 pane 之上，命中不再被文件行截走。
3. **视觉仍是 1pt**：11pt 容器里居中画 1pt 线，hover / 拖动时 overlay 加粗到 3pt，行为与现在一致。
4. `SplitDivider` 的 `width` binding 语义不变：拖的是**左侧 pane 宽度**。

提取纯函数便于测试：

```swift
enum SplitOverlayLayout {
    /// 返回两条 11pt 热区的 minX。侧栏隐藏时第一条为 nil。
    static func hitMinXs(showsSidebar: Bool, sidebarWidth: CGFloat,
                         fileListWidth: CGFloat, hitWidth: CGFloat = 11) -> (CGFloat?, CGFloat)
}
```

热区以分界线为中心：`boundaryX - hitWidth/2`。

### 3.4 成功标准

- 中栏有一屏文件时，分隔线全高可出现拉伸光标并拖动。
- 拖动结束仍写入 `sidebarWidth` / `fileListWidth`。
- 栏宽范围不变：侧栏 180...340，文件列表 240...520。
- 光标 push/pop 仍配对，不会卡在拉伸样式。

---

## 4. 切片 B：键盘上下键切换文件

原设计「不做键盘驱动工作流」，但允许快捷键作加速。本切片只加这一组加速，鼠标点文件仍然是完整路径。

### 4.1 行为

对**当前中栏可见文件行**（已应用过滤、已展开的树节点；不含分组标题、目录行）：

| 按键 | 动作 |
|------|------|
| ↓ | 选中下一份文件并打开 diff（与单击相同，替换多选） |
| ↑ | 选中上一份 |
| Shift+↓ / Shift+↑ | 按现有 `selectFileRange` 从锚点扩到目标 |
| 无选中时 ↓ | 选第一份 |
| 无选中时 ↑ | 选最后一份 |
| 已在端点 | 停住，不循环 |

连续滚动模式下仍只做「选中 + `continuousRevealID` 滚到该文件头」，与单击一致。

### 4.2 焦点与拦截

窗口级监听方向键，但**下列情况不拦截**（把事件交给系统）：

- 模型配置弹窗里的 `TextField` / `SecureField`
- AI 解释面板底部输入框
- 过滤规则编辑框
- 任何 `NSTextField`；以及除 `DiffTextView` 之外的 `NSTextView`

`DiffTextView` 是只读审查面：方向键**不**移动插入点，改去切文件。滚动仍用滚轮、触控板、`Page Up` / `Page Down`。

实现落在 `FileListPane`（知道可见 `orderedFileIDs`）+ 一个 `NSEvent` local monitor，由 `ContentView` 在 appear/disappear 时安装/拆除。不把方向键写进 `.commands`（系统会显示成菜单项，且与文本框冲突更难控）。

### 4.3 成功标准

- 中栏有 3 个可见文件时，↓↓ 能依次打开第 2、第 3 个。
- 焦点在「接口地址」输入框时，↓ 不切文件。
- 点选文件的鼠标路径完全不变。

---

## 5. 切片 C：过滤文件

与「生成文件折叠」不同：折叠仍出现在中栏，只是右栏先占位；过滤是**从中栏列表里拿掉**，连续滚动也不收录。

### 5.1 规则

- 每一条是文件名 glob（`fnmatch`，与 `GeneratedFileDetector` 相同：`*` / `?`，只匹配路径最后一段）。
- 以 `/` 结尾的规则按路径段精确匹配目录名（同样复用 detector 的语义），例如 `fixtures/`。
- 不支持完整正则，避免设置页变成脚本编辑器。

缺省规则（用户可改、可清空）：

```
*.png
*.jpg
*.jpeg
*.gif
*.webp
*.svg
*.ico
*Test.swift
*_test.go
*.test.ts
*.test.tsx
*.spec.ts
*.spec.tsx
*.snap
```

命中判定抽成纯函数 `FileFilter.matches(path:patterns:)`，放 `DiffEngine`，与 `GeneratedFileDetector` 并列。不要让 detector 兼职隐藏——折叠和隐藏是两种产品行为。

### 5.2 交互

中栏栏头、平铺/树切换左侧加：

- `PlainIconButton`：图标 `line.3.horizontal.decrease`，`isSelected` 绑定 `hidesFilteredFiles`。选中时隐藏命中文件。help：「隐藏已过滤的文件」。
- 旁边一个 `PlainIconMenu`（图标 `slider.horizontal.3`）：「编辑过滤规则…」，弹出 popover。

Popover（不是再占全局设置）：

- 多行文本，一行一条 glob。
- 底部「恢复默认」+ 说明「只匹配文件名；`foo/` 匹配路径中的目录段」。
- 失焦或点空白即保存（与栏宽拖完 persist 一样即时写盘）。

开关与规则都持久化。旧 `state.json` 缺字段时：规则用缺省列表，开关 `false`（不隐藏，避免升级后文件突然失踪）。

### 5.3 列表与计数

- 过滤在构建 `rows` **之前**进行。树视图先滤再 `FileTreeBuilder.build`，不要留下空目录。
- 分组标题的数字是**可见**文件数。
- 若当前隐藏了至少 1 个，栏头 subtitle 或分组旁用 tertiary 文案「已隐藏 N」。N 是当前中栏数据源下命中规则的文件数（工作区 = staged+unstaged 条目数之差；选中某 commit 时 = 该 commit 文件列表过滤前后之差）。
- 过滤后列表为空但原始列表非空：空状态「过滤后没有文件」，描述「关闭过滤或改规则后即可看到」。
- 连续滚动的 `continuousPlan` 必须用同一份可见列表，否则中栏与右栏会不一致。
- 当前选中文件被滤掉：清空选中（与文件从 git status 消失相同）。

### 5.4 成功标准

- 打开开关后 `photo.png` 从中栏消失，`src/App.ts` 仍在。
- 关掉开关立即回来，不必重选 worktree。
- 改规则即时生效。
- 生成文件折叠规则不受影响。

---

## 6. 切片 D：未推送提交的代码变更

Sift 仍然不做 push。本切片只**读**某个 worktree 上已经 commit、还没送到上游的提交。Sift 侧栏里「分支」就是 worktree 行（`displayName` 优先分支名），没有单独的分支节点，因此 commit 列表挂在**对应 worktree 下面**。

三栏分工不变：

| 栏 | 工作区（点 worktree 行） | 点某条未推送 commit |
|----|--------------------------|---------------------|
| 左 | 仓库 → worktree →（可展开）commit | 该 commit 行选中 |
| 中 | 已暂存 / 未暂存文件 | **该 commit 改过的文件** + **完整 message** |
| 右 | 工作区 / index diff | 该文件在该 commit 里的 diff |

不做累计「全部未推送」文件视图，也不做中栏图标切换数据源。

### 6.1 左栏

选中某 worktree 后，后台拉 `@{upstream}..HEAD` 的 commit 列表（只算当前选中的 worktree，与现有改动数策略相同）。

- **无上游或领先 0**：不画任何 commit 行，不出现展开箭头。不猜 `origin/main`。
- **领先 ≥ 1**：worktree 行出现披露箭头；右侧在改动数旁边用 tertiary 标 `↑N`（N = 未推送 commit 数），折叠时也能看出有东西。
- **默认折叠。** 点箭头只展开/收起，**不改变**当前选中的 worktree / commit / 中栏。点 worktree 行其余区域：选中该工作区（`selectedCommit = nil`），中栏回到 staged/unstaged。
- 展开态只存在本会话，不写 `state.json`（与仓库折叠同一策略）。
- 展开后，worktree 下方缩进列出 commit，**新的在上**（`git log` 默认顺序）：

```
  ▼ feat/xxx                 15  ↑3
      a1b2c3d  接入 tracing-llm
      d4e5f6a  补测试
      09ab800  调整 package.json
```

每行：7 位短 SHA（等宽、tertiary）+ subject 第一行（primary，单行、中间截断）。高度与 worktree 行相同（`Theme.sidebarRowHeight`）。选中态与 worktree 行同一套 `rowSurface`。
- 点某条 commit：选中它所属的 worktree（若尚未选中）+ 该 SHA；中栏换成该 commit 的文件；右栏打开第一个文件的 diff（或保持同路径若新列表里还有）。
- 点另一 worktree 的 commit：先切 worktree，再选 commit。

### 6.2 中栏与右栏

选中 commit 时：

- 栏头标题仍是「改动」，subtitle 为短 SHA（7 位）。
- 栏头下方、文件列表上方放 **CommitMessageBlock**：subject 用 `Theme.headerFont`；若 `body` 非空，下面用 `Theme.secondaryFont` 显示全文。块最大高度约 7 行，超出内部滚动，避免挤掉文件列表。这是看完整 message 的地方；左栏只展示 subject。
- 文件列表**单一分组**，没有已暂存/未暂存，**没有复选框**。过滤（切片 C）、平铺/树、键盘上下键仍作用于这份可见文件。
- 右栏是该文件在 `parent..commit` 上的 diff（普通提交的第一父；根提交用 `git show`）。**hunk 暂存 / 取消暂存 / 丢弃全部隐藏**。解释、分栏、连续滚动、复制去行号仍可用。
- Blame：对该 commit 的父侧做 `git blame <parent> -- path`；纯新增文件无 blame。
- 连续滚动：plan 来自该 commit 的可见文件；id 形如 `c:<sha>:<path>`。

点回 worktree 行：取消 commit 选中，中栏立刻回到工作区文件，message 块卸掉。

### 6.3 Git 命令

范围仍是两点 `@{upstream}..HEAD`（未推送的提交集合）。单条 diff 是该 commit 相对其第一父，**不是**整段累计。

1. `git rev-parse --abbrev-ref --symbolic-full-name @{upstream}` — 非零则无上游，commit 列表为空。
2. `git log --format=%H%x1f%s%x1f%b%x1f%an%x1f%aI%x1e @{upstream}..HEAD` — 字段分隔 `0x1f`，记录分隔 `0x1e`。body 可含换行。
3. 选中 commit 后：
   - `git diff-tree --no-commit-id --name-status -z -r <sha>`（根提交加 `--root`）
   - `git diff-tree --no-commit-id --numstat -z -r <sha>`
   - 单文件：`git diff --no-color -U3 <sha>^ <sha> -- <path>`；无父时 `git show --format= --no-color -U3 <sha> -- <path>`

`name-status -z` 记录形状（`NameStatusParser`）：

- 普通：`M\0path\0` / `A\0path\0` / `D\0path\0` / `T\0path\0`
- 重命名：`R100\0oldPath\0newPath\0`

解析为现有 `FileStatus`：`indexStatus` = 该变化种类，`worktreeStatus` = `.unmodified`。

FSEvents 已监视 worktree 根（含 `.git`）。本地 commit / amend / reset 会刷新列表；若当前选中的 SHA 消失，退回该 worktree 的工作区视图。不 fetch，远端前进不会出现在列表里。

`DiffCacheKey` 必须带上侧，避免和工作区 diff 串味：

```swift
enum DiffSide: Hashable, Sendable {
    case workingTree(staged: Bool)
    case commit(sha: String)
}
```

图片：`BlobSource` 增加 `revision(String)`。commit 旧侧 = 父 SHA（或无），新侧 = 该 commit SHA。

### 6.4 GitKit API

```swift
public struct CommitInfo: Sendable, Equatable, Identifiable {
    public var sha: String
    public var subject: String
    public var body: String          // 不含 subject；无正文为空串
    public var authorName: String
    public var authorDate: Date
    public var id: String { sha }
}

extension GitRepository {
    /// 无上游时返回 nil（不抛错）。领先 0 时返回空数组。
    public func unpushedCommits() async throws -> [CommitInfo]?
    public func commitFiles(sha: String) async throws -> (
        files: [FileStatus], lineStats: [String: LineStats])
    public func diff(path: String, from parent: String?, to sha: String) async throws -> FileDiff
}
```

父 SHA：`git rev-parse <sha>^` 失败则 `parent == nil`。主线程不调用 git。

### 6.5 成功标准

- 有上游且领先 2 个 commit：选中该 worktree 后行上出现 `↑2`；展开能看到两条 subject；默认折叠。
- 点其中改了 `a.txt` 的那条：中栏出现 `a.txt` 和完整 message，右栏是这一笔的 diff，不是工作区未提交内容。
- 点 worktree 行：中栏回到已暂存/未暂存，message 块消失。
- 无上游：worktree 行与现在一样，没有箭头、没有空分组。
- 选中 commit 时看不到暂存按钮。

---

## 7. 切片 E：检查更新（类似 Cursor）

对照物：Cursor 状态栏「Update」按钮，以及下载完成后的条「Update to x.y.z is ready — click to restart」。

不引入 Sparkle：应用已通过 GitHub Release 发 `Sift-<version>.dmg`，且当前不做公证；Sparkle 还要 appcast、EdDSA 密钥，违反零依赖。信任 HTTPS 上的 GitHub Release 资产即可。

### 7.1 检查

- 仓库：`https://api.github.com/repos/YaoKaiLun/Sift/releases/latest`（与 README / 现有 Release 工作流一致）。
- `Accept: application/vnd.github+json`，`User-Agent: Sift/<marketingVersion>`。
- 解析 `tag_name`（去掉可选前缀 `v`）与 `assets[].name == Sift-*.dmg` 的 `browser_download_url`。
- 当前版本：`Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")`。比较规则：点分数字，缺段当 0；`1.2` < `1.2.1` < `1.10`。预发布后缀（`-beta`）视为**低于**同号正式版，本应用的 tag 目前都是正式 `v*`。
- 仅当远端 **严格大于** 本地时视为有更新。
- 时机：Release 配置在 `applicationDidFinishLaunching` 之后异步检查一次；Sift 菜单「检查更新…」。Debug / 从 Xcode DerivedData 跑的包**自动检查关闭**（避免把开发包换成 Release），菜单仍可用并走同一套假数据可测路径。
- 失败（网络、非 JSON、无 DMG）：菜单触发时用现有 `errorMessage` 弹窗「无法检查更新」；启动时的自动检查失败静默忽略。
- 已是最新：仅菜单触发时弹「已是最新版本（x.y.z）」。

不把 GitHub token 写进应用。公开仓库匿名限额足够启动+手动。

### 7.2 下载与替换

状态机：

```
idle → checking → available(version, dmgURL)
                → downloading(progress)
                → ready(stagedAppURL)
                → restarting
                → idle / failed
```

- 用户点侧栏「更新」或菜单「下载更新」：后台下载 DMG 到 `~/Library/Caches/Sift/updates/`。
- 下载完：`hdiutil attach -nobrowse -readonly`，把卷内 `Sift.app` `ditto` 到 Caches 下的 `Sift-next.app`，`hdiutil detach`。不在这一步覆盖正在运行的 bundle。
- UI 切到 Cursor 同款条：**「x.y.z 已就绪 — 点击重启」**，侧栏按钮文案改为「重启」。点任一处：
  1. 把一段 `/bin/bash` 脚本写到临时文件：等本进程 PID 退出 → `ditto` 覆盖 `Bundle.main.bundleURL` → `xattr -cr` → `open` 新 bundle → 删脚本。
  2. 启动该脚本，然后 `NSApp.terminate`。
- 只覆盖自己的 `.app`。若 `bundleURL` 不在用户可写位置（理论上非 /Applications 也可能），失败则 `errorMessage`：「无法安装更新，请到 GitHub Release 手动下载」。
- 进行中的下载在再次检查到同一版本时不重来；用户可在菜单选「取消下载」。

### 7.3 界面

- **Sift 菜单**（`.appInfo` 之后）：「检查更新…」。关于窗口不做。
- **侧栏页脚**：`appearance` 与齿轮之间，仅当状态为 `available` / `downloading` / `ready` 时出现：
  - available：胶囊按钮「更新」，help 含目标版本。
  - downloading：按钮禁用，标题「下载中…」。
  - ready：按钮「重启」。
- **就绪条**：窗口底部或侧栏上方一条，文案「x.y.z 已就绪 — 点击重启」，点击 = 重启安装。不要用系统通知。
- 齿轮仍只开模型配置，不把更新塞进设置弹窗。

### 7.4 模块

新建 `UpdateKit`（只依赖 Foundation；`hdiutil` / `open` 用 `Process` 在后台线程）：

- `Version`：解析与比较
- `GitHubLatestRelease`：解码 JSON
- `UpdateChecker`：protocol + `GitHubUpdateChecker`
- `UpdateInstaller`：下载、挂载、暂存、写出重启脚本

`SiftApp` 持有 `@State UpdateController`（`@Observable`，可放 `SiftUI` 或 App 壳），注入 `ContentView`。不要把 HTTP 塞进 `RepoStore`。

测试用假 `URLProtocol` / 注入的 `ReleaseFetching`，不打真 GitHub。Installer 的「选 DMG 资产」「版本比较」「重启脚本含 PID 与目标路径」纯函数测。挂载 DMG 不进 CI。

### 7.5 成功标准

- 本地 `1.0`、Release `v1.1` 且有 `Sift-1.1.dmg`：启动后侧栏出现「更新」。
- 点更新后（测试注入已下载的 staged app）出现就绪条，文案含 `1.1`。
- 本地已是最新：自动检查无 UI；菜单提示已是最新。
- Debug 启动不打 GitHub。

---

## 8. 模块与依赖

```
GitKit          + NameStatusParser、CommitLogParser、unpushedCommits、commitFiles、diff(from:to:)、BlobSource.revision
DiffEngine      + FileFilter；DiffCacheKey 改用 DiffSide
RepoStore       + 过滤偏好、selectedCommit、unpushedCommits、可见文件列表
UpdateKit       新建，零 UI
SiftUI          分栏 overlay、键盘、过滤开关、侧栏 commit 行、CommitMessageBlock、更新按钮与就绪条
App/Sift        菜单「检查更新」，启动时踢一脚检查
```

依赖方向不变。`UpdateKit` 只被 App / SiftUI 用，不依赖 GitKit。

---

## 9. 持久化字段增量

`PersistedState` 现有字段保持；新增（全部有缺省，旧 `state.json` 能读）：

- `hidesFilteredFiles: Bool = false`
- `fileFilterPatterns: [String] = FileFilter.defaultPatterns`

选中的 commit、侧栏展开态不持久化。更新状态不持久化（每次启动重新检查）。API 与 git 凭证仍不进此文件。

---

## 10. 测试

- **GitKit**：`NameStatusParser` 对着手工 `-z` 字节；`unpushedCommits` 用 clone+再 commit 的 fixture，断言 SHA/subject、无 upstream 返回 nil；`commitFiles` 只含该次提交的路径。
- **DiffEngine**：`FileFilter` glob / 目录段 / 大小写；`DiffCache` 工作区与 `commit(sha)` 同路径互不命中。
- **RepoStore**：隐藏过滤后 `visibleFileStatuses` 不含命中路径；`select(commit:)` 后门栏文件来自该 SHA 而非 `git status`。
- **UpdateKit**：版本比较表；JSON fixture 抽出 dmg URL；低于/等于/高于。
- **SiftUI**：`SplitOverlayLayout` 热区坐标。键盘与 SwiftUI 不写 UI 自动化。
- 性能门禁不放宽。commit 列表只在选中 worktree 时拉 `git log`；单文件 diff 仍懒算。

---

## 11. 成功标准（整包）

1. 中栏堆满文件时两条分隔线全高可拖。
2. 上下键能在可见文件间切换，输入框内不误触发。
3. 可配置后缀/glob，一键隐藏图片和测试文件，再一键恢复。
4. 能在左栏展开当前 worktree 的未推送 commit，点一条后在中栏看到 message 与文件、右栏看到该次 diff，且不能从该视图 stage。
5. Release 构建能发现 GitHub 上的更新版本，下载后用一条「已就绪 — 点击重启」完成替换。
6. `./Scripts/preflight.sh` 通过。
