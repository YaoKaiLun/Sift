import json
import os
import tempfile
import unittest
from pathlib import Path

from create_icons import ICON_SPECS, generate_all

CONTENTS = Path(__file__).resolve().parent.parent / "App/Sift/Assets.xcassets/AppIcon.appiconset/Contents.json"


class IconTests(unittest.TestCase):
    def test_contents_json_lists_every_spec(self):
        data = json.loads(CONTENTS.read_text())
        filenames = {item["filename"] for item in data["images"]}
        self.assertEqual(filenames, {name for _, name in ICON_SPECS})

    def test_generated_pngs_have_expected_size_and_pixels(self):
        from PIL import Image

        with tempfile.TemporaryDirectory() as tmp:
            generate_all(tmp)
            for size, name in ICON_SPECS:
                path = os.path.join(tmp, name)
                self.assertTrue(os.path.isfile(path), name)
                img = Image.open(path)
                self.assertEqual(img.size, (size, size), name)
                extrema = img.convert("RGBA").getextrema()
                alpha_max = extrema[3][1]
                self.assertGreater(alpha_max, 0, name)
                # 实心底：角落在筛网之外，应是钢蓝
                corner = img.convert("RGBA").getpixel((max(0, size // 8), max(0, size // 8)))
                self.assertEqual(corner[:3], (47, 93, 138), name)
                self.assertEqual(corner[3], 255, name)


if __name__ == "__main__":
    unittest.main()
