# Sift

面向 macOS 的 Git diff 阅读器。把多个仓库、多个 worktree 放在同一侧栏里，文件列表和 hunk 操作都对着鼠标，用来审查 AI 写出来的改动。

系统要求：[macOS 26](https://www.apple.com/macos/) 或更高。

![Sift 主界面：仓库与 worktree、改动文件列表、统一 diff](docs/images/screenshot.png)

## 特性

- **多仓库、多 worktree**：左侧按仓库分组，每个仓库下列出主工作树和其余 worktree，改动数量挂在条目上。
- **文件级审查**：中栏分已暂存 / 未暂存（未跟踪混在未暂存里，用 `?` 标记）。支持平铺和树视图，勾选框整文件暂存或取消暂存。
- **清晰的 unified diff**：右侧只读文本视图，行号、增删色、文件头条状态都按审查阅读来排。图片改动走预览，过大或生成文件默认折叠。
- **Hunk 操作**：每个可见 hunk 头上常显「暂存区块 / 放弃区块 / 取消暂存 / 解释」，不用悬停才出现。
- **连续滚动**：把当前 worktree 下全部改动拼成一篇长 diff，进入视口再展开。
- **Blame**：单文件模式下可打开作者侧槽，点一行看提交说明。
- **AI 解释**：选区或 hunk 上点「解释」，右侧滑出面板流式说明。兼容 OpenAI 的 `/chat/completions`，密钥只进钥匙串。未配置时弹出模型配置，不发请求。

明确不做：commit graph、分支管理、rebase、冲突解决、push / pull。

## 下载

到 [Releases](https://github.com/YaoKaiLun/Sift/releases) 下载最新 `Sift-<version>.dmg`。

1. 打开 DMG，**双击 `Install Sift.command`**（复制到「应用程序」并去掉隔离标记）。
2. 或把 `Sift.app` 拖进「应用程序」，再在终端执行：

```bash
xattr -cr /Applications/Sift.app
```

当前 Release 未做 Apple 公证。从浏览器下载会带 quarantine，不按上面两步处理时，系统可能提示「已损坏，无法打开」。

## 使用

1. 左侧栏头点 **+**，选一个 Git 仓库目录。同一仓库下的 worktree 会自动列出来。
2. 点 worktree，中栏出现改动文件。点文件看 diff；勾选框只改暂存状态，不切换当前文件。
3. 在 hunk 头上暂存、取消暂存或放弃该块。放弃未跟踪文件会先确认。
4. 需要说明某段改动时，点 hunk 上的「解释」，或选中若干行后点「解释这段」。
5. 左下角齿轮打开 **模型配置**（也可 `⌘,`）。填写接口地址、模型和 API Key 后保存。接口可以是 `https://api.example.com/v1`，也可以带 `/chat/completions`。
6. 栏头两个图标：连续滚动、blame（连续模式下 blame 不可用）。左下角另一个按钮切换浅色 / 深色 / 跟随系统。

## 本地开发

需要 Xcode 26+。

```bash
./Scripts/preflight.sh   # 构建、单元测试、性能门禁
```

用 Xcode 打开 `App/Sift.xcodeproj` 即可运行。

## 打包

```bash
pip install Pillow          # 首次生成图标时需要
./Scripts/build.sh          # 构建 dist/Sift.app
./Scripts/package.sh        # 打包为 dist/Sift-<version>.dmg
```

打 `v*` tag 后，GitHub Actions 会构建 DMG 并挂到对应 Release。
