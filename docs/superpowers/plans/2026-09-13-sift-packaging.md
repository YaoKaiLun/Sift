# Sift Packaging and App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GitHub 能构建并打出带正式图标的 Sift.app / DMG，PR 上跑测试。

**Architecture:** 图标由 Python 生成进 Xcode asset catalog；`xcodebuild` 出 `.app`；`hdiutil` 打 DMG；两套 workflow 分别测和发版。版本解析与图标生成是可单测的纯函数。

**Tech Stack:** Xcode 26、xcodebuild、Pillow、GitHub Actions `macos-26`、hdiutil、ad-hoc codesign。

**规格：** `docs/superpowers/specs/2026-09-13-sift-packaging-design.md`

## Global Constraints

- 最低系统版本：macOS 26。runner 用 `macos-26`。
- 应用仍由 `App/Sift.xcodeproj` 组装，不改成 SPM executable。
- 沙盒保持关闭。不公证。
- 图标画布铺满方形，不自带圆角；填充 `#2F5D8A`，白色筛网。
- 注释与提交说明用中文。
- 不在 `main` 上实现。当前分支 `feat/review-ops`。

---

## File Structure

```
Scripts/
  version.py                 版本解析
  create-icons.py            生成 AppIcon PNG
  test_version.py
  test_create_icons.py
  build.sh                  xcodebuild + 签名
  package.sh                DMG + Install Sift.command
App/Sift/
  Assets.xcassets/AppIcon.appiconset/
  Sift.entitlements
.github/workflows/
  ci.yml
  release.yml
README.md
```

---

### Task 1: 版本解析

**Files:**
- Create: `Scripts/version.py`
- Test: `Scripts/test_version.py`

**Interfaces:**
- Produces: `parse_version(github_ref: str | None, git_describe: str | None, fallback: str = "1.0") -> str`

- [ ] **Step 1: 写失败的测试**

```python
import unittest
from version import parse_version

class VersionTests(unittest.TestCase):
    def test_tag_ref(self):
        self.assertEqual(parse_version("refs/tags/v1.2.3", None), "1.2.3")

    def test_non_tag_ref_falls_to_describe(self):
        self.assertEqual(parse_version("refs/heads/main", "v0.9.0"), "0.9.0")

    def test_fallback(self):
        self.assertEqual(parse_version(None, None), "1.0")

    def test_describe_without_v_prefix_rejected(self):
        self.assertEqual(parse_version(None, "abc"), "1.0")

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python3 Scripts/test_version.py`
Expected: FAIL，`ModuleNotFoundError: version`

- [ ] **Step 3: 最小实现**

```python
import re

def parse_version(github_ref, git_describe, fallback="1.0"):
    if github_ref and github_ref.startswith("refs/tags/"):
        tag = github_ref.rsplit("/", 1)[-1]
        if tag.startswith("v") and re.fullmatch(r"v\d+\.\d+(\.\d+)?", tag):
            return tag[1:]
    if git_describe and re.fullmatch(r"v\d+\.\d+(\.\d+)?", git_describe):
        return git_describe[1:]
    return fallback
```

- [ ] **Step 4: 跑测试确认通过**

Run: `python3 Scripts/test_version.py`
Expected: PASS

- [ ] **Step 5: Commit**（本会话先不提交，用户未要求 commit）

---

### Task 2: 图标生成

**Files:**
- Create: `Scripts/create-icons.py`
- Create: `App/Sift/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Test: `Scripts/test_create_icons.py`

**Interfaces:**
- Consumes: Pillow
- Produces: `ICON_SPECS`、`create_icon(size, path)`、`generate_all(output_dir)`

- [ ] **Step 1: 写 Contents.json 与失败测试**
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现生成器并写出 PNG**
- [ ] **Step 4: 跑测试确认通过**

---

### Task 3: build.sh / package.sh / entitlements / pbxproj / README / workflows

按规格实现。`build.sh` 必须在本机跑通并验证 `codesign --verify`。

- [ ] **Step 1: entitlements + ASSETCATALOG_COMPILER_APPICON_NAME**
- [ ] **Step 2: build.sh / package.sh**
- [ ] **Step 3: 本地 `./Scripts/build.sh`**
- [ ] **Step 4: workflows + README + gitignore**
- [ ] **Step 5: 本地 `python3 Scripts/test_version.py` 与 `python3 Scripts/test_create_icons.py`**
