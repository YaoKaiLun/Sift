import AppKit

/// hunk 操作钮和文件头条相对 NSTextView 的几何。
///
/// overlay 必须和 scroll view 做兄弟（不要当 NSScrollView 的子视图），
/// 坐标一律 `overlay.convert(_:from: textView)`，这样 flipped 文本视图
/// 不会把顶部 hunk 头映射到窗口底部。
@MainActor
public enum DiffOverlayGeometry {
    public static func headerRect(characterRange: NSRange,
                                   textView: NSTextView,
                                   overlay: NSView) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        if NSMaxRange(characterRange) > layoutManager.firstUnlaidCharacterIndex() {
            layoutManager.ensureLayout(forCharacterRange: characterRange)
        }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard rect.height > 0.5 else { return nil }
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return overlay.convert(rect, from: textView)
    }

    public static func actionRowFrame(headerRect: NSRect,
                                       size: NSSize,
                                       overlayBounds: NSRect,
                                       padding: CGFloat = 8) -> NSRect {
        let x = max(padding, overlayBounds.maxX - size.width - padding)
        let y = headerRect.midY - size.height / 2
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 通栏灰条：盖住 textContainerInset 左右留白，不要只铺文字那一段。
    public static func fullBleedBar(from headerRect: NSRect, overlayBounds: NSRect) -> NSRect {
        NSRect(x: overlayBounds.minX, y: headerRect.minY,
               width: overlayBounds.width, height: headerRect.height)
    }
}
