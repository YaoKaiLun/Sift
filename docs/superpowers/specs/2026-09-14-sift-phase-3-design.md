# Sift 计划三设计文档

**日期**：2026-09-14
**状态**：待确认
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
| **D. 未推送提交** | 查看当前分支 / worktree 已提交但未 push 的累计 diff | push / pull / fetch、commit graph、逐 commit 浏览、设上游 |
| **E. 检查更新** | 对照 GitHub Release 检查新版本，下载后提示重启替换 | Sparkle、Apple 公证、增量补丁、自动在后台静默替换且不提示 |

仍明确不做：commit graph、分支管理、rebase、冲突解决、push / pull / fetch。键盘是加速，所有新能力仍须鼠标可达。

### 方案选择（已拍板）

**更新**
1. Sparkle + appcast：成熟，但引入第三方依赖、EdDSA 密钥和额外发版产物；与「零依赖、现有 GitHub Release DMG」冲突。
2. **采用：自研 GitHub Releases 检查 + 下载 DMG + 重启替换。** 与现有 `release.yml` 对齐，UI 模仿 Cursor 的「更新 / 已就绪点击重启」。
3. 只弹浏览器打开 Release 页：实现最便宜，但不是「类似 Cursor」的应用内升级。

**未推送 diff 范围**
1. **采用：两点 `@{upstream}..HEAD`。** 正好是「已提交未 push」的累计树差异。
2. 三点 `@{upstream}...HEAD`：适合 PR 相对 merge-base，上游若已前进会混入别人的提交。
3. 逐 commit 列表再点开：接近 commit graph，超出阅读器定位。

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
- 若当前隐藏了至少 1 个，栏头 subtitle 或分组旁用 tertiary 文案「已隐藏 N」。N 是本 worktree 当前数据源下命中规则的文件数（工作区 = staged+unstaged 去重路径；未推送 = 未推送列表）。
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

Sift 仍然不做 push。本切片只**读**「已经 commit、还没送到上游」的累计 diff，方便审查准备推上去的内容。对象是**当前选中的 worktree**（主工作树或附属 worktree 都按该目录的 `HEAD` / `@{upstream}`）。

### 6.1 数据源

中栏栏头标题旁增加数据源切换，样式与平铺/树同一套 `PlainIconToggle`：

| 图标 | 模式 | 含义 |
|------|------|------|
| `doc.text` | 工作区 | 现有 staged / unstaged / untracked |
| `arrow.up.circle` | 未推送 | `@{upstream}..HEAD` 的累计 diff |

偏好 `fileListSource: workingTree | unpushed`，写入 `state.json`，默认 `workingTree`。

未推送模式：

1. `git rev-parse --abbrev-ref --symbolic-full-name @{upstream}`  
   - 非零退出 → 无上游。空状态标题「没有上游分支」，描述「当前分支没有设置上游，无法计算未推送的提交。」不猜 `origin/main`。
2. `git rev-list --count @{upstream}..HEAD` → 领先提交数。
3. 领先 0 → 空状态「没有未推送的提交」。
4. 否则：
   - `git diff --name-status -z @{upstream}..HEAD`
   - `git diff --numstat -z @{upstream}..HEAD`
   - 单文件：`git diff --no-color -U3 @{upstream}..HEAD -- <path>`

两点记法（`A..B`）是「上游尖端到 HEAD」的树差异，等于这些未推送 commit 合在一起的内容。不用三点记法（那是 merge-base，适合 PR，但本地领先且上游也前进时会多算别人的提交）。

`name-status -z` 记录形状：

- 普通：`M\0path\0` / `A\0path\0` / `D\0path\0` / `T\0path\0` / `Cscore\0path\0`
- 重命名：`R100\0oldPath\0newPath\0`（分数可有可无）

解析为现有 `FileStatus`：`indexStatus` = 该变化种类，`worktreeStatus` = `.unmodified`，`originalPath` 仅重命名/复制时有。这样中栏徽章、树构建、图片 blob 映射都能复用。

### 6.2 界面

- 中栏**单一分组**「未推送」，计数为可见文件数；栏头 subtitle 为分支显示名 + 「领先 N 个提交」。
- **没有复选框**。点击行只选中并打开 diff。
- 右栏 **hunk 的暂存 / 取消暂存 / 丢弃全部隐藏**。解释、分栏、连续滚动、复制去行号仍可用。
- Blame：仍对 HEAD 做（这些改动已经在 HEAD 里）。未推送里的纯新增文件没有 blame，与未跟踪相同。
- 连续滚动：用未推送文件列表做 plan；占位头的 +/− 来自这次 numstat。
- 过滤规则（切片 C）同样作用于未推送列表。

FSEvents 已监视 worktree 根目录（含 `.git`）。本地 commit、amend、reset 会刷新；**远端变化不会出现**（本切片不 fetch）。用户刚 commit 完切到未推送即可看到。

切换数据源：取消在途读任务、清空选中与 diff、按新数据源拉列表。`DiffCache` 的 key 必须带上数据源（或 `fromRev`），避免工作区 diff 与未推送 diff 串味。现有 key 是 `(worktree, path, staged)`；未推送用 `staged` 不够。改为：

```swift
enum DiffSide: Hashable, Sendable {
    case workingTree(staged: Bool)
    case unpushed          // @{u}..HEAD
}
```

`DiffCacheKey` 用 `DiffSide` 替换 `staged: Bool`。工作区调用点包一层 `.workingTree(staged:)`。

图片：`BlobSource` 增加 `revision(String)`。未推送旧侧 = 上游名，新侧 = `"HEAD"`；新增无旧侧，删除无新侧。

### 6.3 GitKit API

```swift
public struct UnpushedSummary: Sendable, Equatable {
    public var upstream: String           // 例如 origin/main
    public var aheadCount: Int
    public var files: [FileStatus]
    public var lineStats: [String: LineStats]
}

extension GitRepository {
    /// 无上游时返回 nil（不抛错）。
    public func unpushedSummary() async throws -> UnpushedSummary?
    public func diffUnpushed(path: String, upstream: String) async throws -> FileDiff
}
```

`unpushedSummary` 内部三次 git（rev-parse / rev-list / name-status+numstat 可并行后两项）。主线程不调用。

### 6.4 成功标准

- 有上游且领先 2 个 commit、改了 `a.txt`：未推送列表出现 `a.txt`，打开后是相对上游的累计 diff，不是工作区脏内容。
- 无上游：空状态，不崩溃、不发 `git diff`。
- 工作区脏文件不出现在未推送列表（除非也已提交）。
- 未推送模式下看不到暂存按钮。

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
GitKit          + NameStatusParser、unpushedSummary、diffUnpushed、BlobSource.revision
DiffEngine      + FileFilter；DiffCacheKey 改用 DiffSide
RepoStore       + fileListSource、过滤偏好、unpushed 状态、可见文件列表
UpdateKit       新建，零 UI
SiftUI          分栏 overlay、键盘、过滤开关、未推送切换、更新按钮与就绪条
App/Sift        菜单「检查更新」，启动时踢一脚检查
```

依赖方向不变。`UpdateKit` 只被 App / SiftUI 用，不依赖 GitKit。

---

## 9. 持久化字段增量

`PersistedState` 现有字段保持；新增（全部有缺省，旧 `state.json` 能读）：

- `fileListSource: FileListSource = .workingTree`（raw value `workingTree` / `unpushed`）
- `hidesFilteredFiles: Bool = false`
- `fileFilterPatterns: [String] = FileFilter.defaultPatterns`

更新状态不持久化（每次启动重新检查）。API 与 git 凭证仍不进此文件。

---

## 10. 测试

- **GitKit**：`NameStatusParser` 对着手工 `-z` 字节；`unpushedSummary` 用 `FixtureRepo` 建裸远端、设 upstream、再 commit，断言文件列表与领先数；无 upstream 返回 nil。
- **DiffEngine**：`FileFilter` glob / 目录段 / 大小写；`DiffCache` 工作区与未推送同路径互不命中。
- **RepoStore**：隐藏过滤后 `visibleFileStatuses` 不含命中路径；切到未推送时 `fileStatuses` 来自 unpushed 而非 status。
- **UpdateKit**：版本比较表；JSON fixture 抽出 dmg URL；低于/等于/高于。
- **SiftUI**：`SplitOverlayLayout` 热区坐标。键盘与 SwiftUI 不写 UI 自动化。
- 性能门禁不放宽。未推送列表与 status 一样只跑 name-status/numstat，单文件 diff 仍懒算。

---

## 11. 成功标准（整包）

1. 中栏堆满文件时两条分隔线全高可拖。
2. 上下键能在可见文件间切换，输入框内不误触发。
3. 可配置后缀/glob，一键隐藏图片和测试文件，再一键恢复。
4. 能阅读当前 worktree 相对上游未推送 commit 的文件 diff，且不能从该视图 stage。
5. Release 构建能发现 GitHub 上的更新版本，下载后用一条「已就绪 — 点击重启」完成替换。
6. `./Scripts/preflight.sh` 通过。
