import SwiftUI
import AppKit

/// NSTextView 的 SwiftUI 封装。
///
/// 为什么不用 SwiftUI 的 Text：SwiftUI 没有能处理上万行文档的文本视图。
/// NSTextView 给的是二十年优化过的文本布局、原生选中、无障碍和滚动惯性。
///
/// 关键性能约定：更新文档时用 `replaceCharacters` 整体替换，
/// 并且**绝不**在滚动过程中改动 text storage。计划二的语法高亮必须走
/// attribute-only 的覆盖路径，不能重建文档，否则滚动位置会跳。
struct DiffTextView: NSViewRepresentable {
    let document: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // 不换行：宽度设为无限，靠横向滚动。
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        // 内容没变就什么都不做，避免 SwiftUI 每次重绘都重建文档。
        guard storage.string != document.string else { return }
        storage.beginEditing()
        storage.setAttributedString(document)
        storage.endEditing()
        textView.scroll(NSPoint(x: 0, y: 0))
    }
}
