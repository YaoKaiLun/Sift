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

    /// 选区操作条：优先贴在选区下方、左对齐。盖在选区右侧会挡住同一行后半段代码。
    public static func selectionActionFrame(selection: NSRect,
                                            size: NSSize,
                                            in bounds: NSRect,
                                            flipped: Bool,
                                            padding: CGFloat = 6,
                                            margin: CGFloat = 8) -> NSRect {
        let maxX = bounds.maxX - size.width - margin
        let x = min(max(margin, selection.minX), max(margin, maxX))
        let belowY = flipped ? selection.maxY + padding : selection.minY - size.height - padding
        let aboveY = flipped ? selection.minY - size.height - padding : selection.maxY + padding
        let below = NSRect(x: x, y: belowY, width: size.width, height: size.height)
        let inset = bounds.insetBy(dx: 0, dy: margin)
        let y = inset.contains(below) ? belowY
            : min(max(margin, aboveY), bounds.maxY - size.height - margin)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 通栏灰条：盖住 textContainerInset 左右留白，不要只铺文字那一段。
    public static func fullBleedBar(from headerRect: NSRect, overlayBounds: NSRect) -> NSRect {
        NSRect(x: overlayBounds.minX, y: headerRect.minY,
               width: overlayBounds.width, height: headerRect.height)
    }
}
