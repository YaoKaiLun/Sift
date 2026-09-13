#!/usr/bin/env python3
import os

from PIL import Image, ImageDraw

FILL = (47, 93, 138, 255)
WHITE = (255, 255, 255, 255)

ICON_SPECS = [
    (16, "icon_16.png"),
    (32, "icon_16@2x.png"),
    (32, "icon_32.png"),
    (64, "icon_32@2x.png"),
    (128, "icon_128.png"),
    (256, "icon_128@2x.png"),
    (256, "icon_256.png"),
    (512, "icon_256@2x.png"),
    (512, "icon_512.png"),
    (1024, "icon_512@2x.png"),
]


def _xy(size, x, y):
    s = size / 512.0
    return (x * s, y * s)


def create_icon(size, output_path):
    img = Image.new("RGBA", (size, size), FILL)
    draw = ImageDraw.Draw(img)
    s = size / 512.0
    mesh = max(1, round(7 * s))

    def p(x, y):
        return _xy(size, x, y)

    # 圆口细嘴：宽平底梯形会被看成购物篮，收成漏斗筛。
    outer = [p(118, 170), p(394, 170), p(282, 350), p(230, 350)]
    inner = [p(142, 188), p(376, 188), p(274, 334), p(238, 334)]
    draw.polygon(outer, fill=WHITE)
    draw.polygon(inner, fill=FILL)

    draw.ellipse((88 * s, 84 * s, 424 * s, 198 * s), fill=WHITE)
    draw.ellipse((122 * s, 112 * s, 390 * s, 170 * s), fill=FILL)

    draw.ellipse((224 * s, 336 * s, 288 * s, 372 * s), fill=WHITE)
    draw.ellipse((238 * s, 346 * s, 274 * s, 362 * s), fill=FILL)

    if size >= 32:
        for t in (0.3, 0.5, 0.7):
            x0 = 142 * s + (376 - 142) * s * t
            x1 = 238 * s + (274 - 238) * s * t
            draw.line([(x0, 192 * s), (x1, 330 * s)], fill=WHITE, width=mesh)
        for ty in (0.3, 0.55, 0.8):
            y = 188 * s + (334 - 188) * s * ty
            left = 142 * s + (238 - 142) * s * ty
            right = 376 * s + (274 - 376) * s * ty
            draw.line([(left, y), (right, y)], fill=WHITE, width=mesh)

    radius = max(1, round(11 * s))
    for cy in (400, 432, 464):
        x, y = p(256, cy)
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=WHITE)

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    img.save(output_path, "PNG")


def generate_all(output_dir):
    os.makedirs(output_dir, exist_ok=True)
    for size, name in ICON_SPECS:
        create_icon(size, os.path.join(output_dir, name))


def default_output_dir():
    return os.path.join(
        os.path.dirname(__file__),
        "..",
        "App",
        "Sift",
        "Assets.xcassets",
        "AppIcon.appiconset",
    )


if __name__ == "__main__":
    generate_all(default_output_dir())
    print("App icons written to", os.path.abspath(default_output_dir()))
