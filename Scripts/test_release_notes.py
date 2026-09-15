import unittest

from release_notes import generate_release_notes


class ReleaseNotesTests(unittest.TestCase):
    def test_groups_user_facing_commits_and_strips_prefixes(self):
        notes = generate_release_notes(
            [
                "feat: 新增文件过滤",
                "improve(SiftUI): 提高分栏拖动稳定性",
                "fix(GitKit)!: 修复提交详情卡顿",
                "docs: 更新 README",
                "test: 增加性能门禁",
                "Merge pull request #1 from example/branch",
            ]
        )

        self.assertEqual(
            notes,
            "## 新增功能\n\n"
            "- 新增文件过滤\n\n"
            "## 体验改进\n\n"
            "- 提高分栏拖动稳定性\n\n"
            "## 问题修复\n\n"
            "- 修复提交详情卡顿\n",
        )

    def test_omits_empty_sections(self):
        self.assertEqual(
            generate_release_notes(["fix: 修复启动失败"]),
            "## 问题修复\n\n- 修复启动失败\n",
        )

    def test_returns_empty_content_without_user_facing_commits(self):
        self.assertEqual(
            generate_release_notes(["chore: 更新依赖", "ci: 调整构建环境"]),
            "",
        )


if __name__ == "__main__":
    unittest.main()
