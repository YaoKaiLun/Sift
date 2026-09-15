# Sift

[![CI](https://github.com/YaoKaiLun/Sift/actions/workflows/ci.yml/badge.svg)](https://github.com/YaoKaiLun/Sift/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/YaoKaiLun/Sift)](https://github.com/YaoKaiLun/Sift/releases/latest)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)](https://www.apple.com/macos/)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Sift 是面向 macOS 的开源 Git diff 阅读器。它把多个仓库及其 worktree 放在同一侧栏中，集中展示文件改动、未推送提交和可操作的 hunk，适合审查 AI 生成或人工编写的代码变更。

系统要求：macOS 15（Sequoia）或更高版本。

![Sift 主界面：仓库与 worktree、改动文件列表、统一 diff](docs/images/screenshot.png)

## 核心能力

- **多仓库与多 worktree**：在一个窗口中切换多个仓库、主工作树和关联 worktree。
- **文件级审查**：区分已暂存、未暂存和未跟踪文件；支持平铺视图、树视图、整文件暂存和取消暂存。
- **Hunk 操作**：直接暂存、取消暂存或放弃单个 hunk，无需切换到终端。
- **统一与连续 diff**：阅读带行号和语法高亮的 unified diff，或连续浏览当前 worktree 的全部改动。
- **文件过滤**：使用 glob 规则隐藏图片、测试文件及其他不需要审查的内容。
- **未推送提交**：按提交查看当前分支领先上游的变更，同时保留文件级浏览方式。
- **图片与大文件处理**：预览图片改动，默认折叠生成文件和体积过大的文件。
- **Blame**：在单文件模式中查看行作者和提交信息。
- **AI 解释**：将选区或 hunk 发送到兼容 OpenAI `/chat/completions` 的服务，流式返回代码说明。
- **应用内更新**：检查 GitHub Release，下载新版本并在确认后重启安装。

Sift 专注于改动审查，不提供提交图、分支管理、rebase、冲突解决、push 或 pull。

## 安装

从 [GitHub Releases](https://github.com/YaoKaiLun/Sift/releases/latest) 下载最新的 `Sift-<version>.dmg`。

### 使用安装脚本

打开 DMG，双击 `Install Sift.command`。脚本会：

1. 将 `Sift.app` 复制到 `/Applications`；
2. 移除浏览器下载产生的 quarantine 属性；
3. 启动 Sift。

如果 `/Applications/Sift.app` 已存在，脚本会先替换旧版本。

### 手动安装

也可以将 `Sift.app` 拖入「应用程序」，然后执行：

```bash
xattr -cr /Applications/Sift.app
open /Applications/Sift.app
```

> [!IMPORTANT]
> 当前 Release 使用 ad hoc 签名，尚未使用 Apple Developer ID 签名和公证。macOS Gatekeeper 可能提示应用已损坏或无法验证开发者。请只从本仓库的 GitHub Releases 下载，并在确认来源后移除 quarantine 属性。

## 快速开始

1. 点击左侧栏头的「+」，选择一个 Git 仓库。同一仓库下的 worktree 会自动列出。
2. 选择 worktree，在中栏查看已暂存、未暂存和未跟踪文件。
3. 点击文件，在右栏阅读 diff；点击文件前的勾选框可暂存或取消暂存整个文件。
4. 在 hunk 标题栏中暂存、取消暂存或放弃该 hunk。放弃未跟踪文件前会要求确认。
5. 使用上下方向键切换可见文件；按住 `Shift` 可扩展文件选择范围。

中栏漏斗按钮用于配置文件过滤。点「应用过滤」后开始隐藏匹配项；按钮处于选中状态时，再点一次可取消过滤。

右栏支持单文件 / 连续浏览、统一 / 分栏 diff 和 blame。连续浏览模式下不提供 blame。

## AI 与隐私

AI 解释默认关闭。首次使用「解释」时，需要在「模型配置」中填写接口地址、模型和 API Key：

- 接口需兼容 OpenAI `/chat/completions`；
- API Key 保存在 macOS 钥匙串中；
- 未完成配置时不会发送网络请求；
- 只有主动点击「解释」或「解释这段」时，相关代码和上下文才会发送到所配置的服务。

数据处理方式取决于所配置的模型服务。使用前应确认该服务的隐私政策和代码数据处理规则。

## 本地开发

开发环境需要 Xcode 26 或更高版本，以及 Swift 6.2 或更高版本。

```bash
git clone https://github.com/YaoKaiLun/Sift.git
cd Sift
./Scripts/preflight.sh
```

`preflight.sh` 会依次执行构建、单元测试和大型仓库性能测试。也可以用 Xcode 打开 `App/Sift.xcodeproj`，选择 `Sift` scheme 后运行。

命令行构建并启动 Debug 版本：

```bash
xcodebuild \
  -project App/Sift.xcodeproj \
  -scheme Sift \
  -configuration Debug \
  -derivedDataPath /tmp/SiftBuild \
  -destination 'platform=macOS' \
  build
open /tmp/SiftBuild/Build/Products/Debug/Sift.app
```

## 打包

首次生成应用图标需要安装 Pillow：

```bash
python3 -m pip install Pillow
./Scripts/build.sh
./Scripts/package.sh
```

- `build.sh` 构建使用 ad hoc 签名的 `dist/Sift.app`；
- `package.sh` 生成 `dist/Sift-<version>.dmg`；
- 推送 `v*` tag 后，GitHub Actions 会构建 DMG 并添加到对应的 Release。

## 贡献

欢迎通过 [GitHub Issues](https://github.com/YaoKaiLun/Sift/issues) 报告问题或提出功能建议。

提交代码前请运行：

```bash
./Scripts/preflight.sh
```

Pull Request 应说明改动目的、验证方式和可见的界面变化。涉及较大功能或交互调整时，建议先创建 Issue 讨论范围。

## 许可证

Sift 基于 [MIT License](LICENSE) 发布。
