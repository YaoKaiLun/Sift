# Sift GitHub 打包与 App Icon 设计文档

**日期**：2026-09-13
**状态**：已确认，转化为实施计划
**对照**：OpenSwitch（`/Users/kailun/Documents/code/OpenSwitch`）的 release 流程

---

## 1. 范围

补齐两件事，使 GitHub 能打出可安装的 Mac 应用，Dock / Finder 使用正式图标。

| 做 | 不做 |
|----|------|
| App Icon 全套尺寸 + Xcode asset catalog | Apple 公证、Developer ID 证书 |
| `xcodebuild` 产出 `Sift.app`，ad-hoc 签名 | 把应用改成 SPM executable |
| DMG + `Install Sift.command`（去隔离属性） | 沙盒化、改最低系统版本 |
| GitHub Actions：PR/push 跑测试；tag 发 Release | 改产品功能、性能门禁数字 |

最低系统仍是 macOS 26。GitHub runner 用 `macos-26`。

---

## 2. 现况

- 无 `.github/workflows/`。
- `App/Sift/Assets.xcassets` 只有 AccentColor，没有 `AppIcon.appiconset`。
- `Package.swift` 只有库；真正的 `.app` 由 `App/Sift.xcodeproj` 组装。
- 本地已有 `Scripts/preflight.sh`（`swift build` + 单测 + 性能门禁）。
- 工程已是 ad-hoc 签名（`CODE_SIGN_IDENTITY = "-"`），沙盒关闭（要读用户选的任意 git 仓库）。

OpenSwitch 用 `swift build` 再手工拼 bundle。Sift 不能照抄那一步，必须 `xcodebuild`。其余（图标脚本、DMG、Install.command、tag 发版）按 OpenSwitch 搬。

---

## 3. 图标

- 源：`Scripts/create-icons.py`（Pillow）。CI 与本地 `build.sh` 在 PNG 缺失时生成。
- 产物：`App/Sift/Assets.xcassets/AppIcon.appiconset/`，mac idiom，尺寸与 OpenSwitch 相同：16/32/128/256/512 的 1x 与 2x。
- **画布铺满方形，不自带圆角**。Xcode 编译进 `.app` 后由系统加 macOS 遮罩。
- 图形：实心钢蓝 `#2F5D8A`，白色漏斗筛（椭圆圆口、网格、细嘴）+ 底部一串往下漏的点。不用宽平底梯形，避免被看成购物篮。不渐变、不投影。
- PNG 提交进仓库，这样直接打开 Xcode 也有图标。脚本仍是可重复生成的真源。
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。

---

## 4. 本地打包

`Scripts/build.sh`：

1. 解析版本：`GITHUB_REF` 为 `refs/tags/vX.Y.Z` 时用 `X.Y.Z`；否则 `git describe --tags --abbrev=0` 若匹配 `v*` 则去 `v`；再否则 `1.0`。
2. 缺图标则跑 `create-icons.py`。
3. `xcodebuild -project App/Sift.xcodeproj -scheme Sift -configuration Release -destination 'platform=macOS'`，`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 注入，DerivedData 放到仓库内 `.build/DerivedData`。
4. 把 `Sift.app` 拷到 `dist/Sift.app`。
5. 用 `iconutil` 把 PNG 编成完整 `AppIcon.icns`（含 1024），覆盖 Xcode 默认那份只有 256 的 stub。
6. `codesign --force --sign - --options runtime` 签可执行文件和 bundle，再 `codesign --verify --deep --strict`。

`Scripts/package.sh`：调用 `build.sh`，在临时目录放入 `Sift.app`、`/Applications` 软链、`Install Sift.command`（复制到 `/Applications` 后 `xattr -cr` 并 `open`），`hdiutil` 打 `dist/Sift-<version>.dmg`。

`.gitignore` 增加 `dist/`、`*.dmg`。不忽略 icon PNG。

沙盒保持关闭。不引入 `get-task-allow` 之外的新权限。Release 签名带 hardened runtime，与 OpenSwitch 一致；未公证应用仍靠安装脚本去掉 quarantine。

---

## 5. GitHub Actions

**CI**（`.github/workflows/ci.yml`）

- 触发：`push`、`pull_request`。
- `runs-on: macos-26`。
- 跑 `./Scripts/preflight.sh`。
- 再跑 `./Scripts/build.sh`，确认 `dist/Sift.app` 存在。不上传 DMG。

**Release**（`.github/workflows/release.yml`）

- 触发：`v*` tag、`workflow_dispatch`。
- `permissions.contents: write`。
- `pip install Pillow` → `create-icons.py` → `package.sh`。
- `actions/upload-artifact` 上传 `dist/Sift-*.dmg`。
- 仅在 tag 上用 `softprops/action-gh-release` 创建 Release 并挂上 DMG。

Action 版本与 OpenSwitch 对齐：`actions/checkout@v6`、`actions/setup-python@v6`、`actions/upload-artifact@v7`、`softprops/action-gh-release@v3`。

---

## 6. README

仓库目前没有 README。新增一份，只写：产品一句话、系统要求、本地 `preflight` / `build` / `package`、从 Release DMG 安装（优先双击 `Install Sift.command`）。不扩写成产品文档。

---

## 7. 测试

- `Scripts/test_create_icons.py`：各尺寸 PNG 边长正确、不是全透明、Contents.json 列出的文件都能生成。
- `Scripts/test_version.py`：tag / `git describe` / 回落的版本解析。
- 打包脚本本身不写 UI 自动化。本地跑一次 `build.sh`，确认 `dist/Sift.app` 能签过、`Info.plist` 含图标键。

---

## 8. 成功标准

1. `./Scripts/package.sh` 在本机产出 `dist/Sift-<version>.dmg`。
2. 打开 `.app`，Dock 与 Finder 显示筛网图标，不是占位图。
3. 推 `v*` tag 后 GitHub Release 挂上 DMG。
4. PR 上 CI 跑 preflight + 应用构建。
