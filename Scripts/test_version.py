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

    def test_two_component_tag(self):
        self.assertEqual(parse_version("refs/tags/v1.0", None), "1.0")


if __name__ == "__main__":
    unittest.main()
