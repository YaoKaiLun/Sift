import SwiftUI
import AppKit

/// hunk 头悬停时出现的暂存 / 取消暂存 / 丢弃操作。未跟踪、二进制、空、折叠不传。
struct HunkActions {
    var showsStage: Bool
    var showsUnstage: Bool
    var showsDiscard: Bool
    var isEnabled: Bool
    var onStage: (String) -> Void
    var onUnstage: (String) -> Void
    var onDiscard: (String) -> Void
}

/// NSTextView 的 SwiftUI 封装。
///
/// 为什么不用 SwiftUI 的 Text：SwiftUI 没有能处理上万行文档的文本视图。
/// NSTextView 给的是二十年优化过的文本布局、原生选中、无障碍和滚动惯性。
///
/// 关键性能约定：更新文档时用 `replaceCharacters` 整体替换，
/// 并且**绝不**在滚动过程中改动 text storage。计划二的语法高亮必须走
/// attribute-only 的覆盖路径，不能重建文档，否则滚动位置会跳。
struct DiffTextView: NSViewRepresentable {
    let document: DiffDocument
    var hunkActions: HunkActions?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

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
        // 左边距和栏头标题对齐（Theme.horizontalPadding）。
        textView.textContainerInset = NSSize(width: 10, height: 6)
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

        context.coordinator.attach(scrollView: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        let text = document.text
        context.coordinator.document = document
        context.coordinator.hunkActions = hunkActions

        if storage.string == text.string {
            if !storage.isEqual(to: text) {
                // attribute-only：不重置滚动位置
                storage.beginEditing()
                text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
                    storage.setAttributes(attrs, range: range)
                }
                storage.endEditing()
            }
        } else {
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
            storage.endEditing()
            textView.scroll(NSPoint(x: 0, y: 0))
        }
        context.coordinator.relayoutOverlay()
    }

    @MainActor
    final class Coordinator: NSObject {
        var document = DiffDocument(text: NSAttributedString(), hunkHeaders: [])
        var hunkActions: HunkActions?
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private var overlay: HunkOverlayView?
        private var buttonStack: NSStackView?
        private var hoveredID: String?
        private var lastButtonIdentity: ButtonIdentity?

        private struct ButtonIdentity: Equatable {
            var hoveredID: String
            var showsStage: Bool
            var showsUnstage: Bool
            var showsDiscard: Bool
            var isEnabled: Bool
        }

        func attach(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView

            let overlay = HunkOverlayView()
            overlay.autoresizingMask = [.width, .height]
            overlay.frame = scrollView.bounds
            overlay.coordinator = self
            scrollView.addSubview(overlay, positioned: .above, relativeTo: nil)
            self.overlay = overlay

            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(relayoutOverlay),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(relayoutOverlay),
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func mouseMoved(at pointInOverlay: NSPoint) {
            applyHover(at: pointInOverlay)
        }

        func mouseExited() {
            hoveredID = nil
            hideButtonStack()
        }

        @objc func relayoutOverlay() {
            overlay?.frame = scrollView?.bounds ?? .zero
            guard let hoveredID, hunkActions != nil else {
                hideButtonStack()
                return
            }
            guard let header = document.hunkHeaders.first(where: { $0.id == hoveredID }),
                  let headerRect = headerRectInScroll(for: header) else {
                hideButtonStack()
                return
            }
            if let overlay, let scrollView, let window = overlay.window {
                let pointInOverlay = overlay.convert(
                    window.mouseLocationOutsideOfEventStream, from: nil)
                let pointInScroll = overlay.convert(pointInOverlay, to: scrollView)
                if !headerHitRect(for: headerRect).contains(pointInScroll) {
                    self.hoveredID = nil
                    hideButtonStack()
                    return
                }
            }
            showButtons(headerRect: headerRect)
        }

        private func applyHover(at pointInOverlay: NSPoint) {
            guard let overlay, let scrollView else { return }
            let pointInScroll = overlay.convert(pointInOverlay, to: scrollView)
            let hitID = hunkID(at: pointInScroll)
            if hitID == nil {
                hoveredID = nil
                hideButtonStack()
                return
            }
            hoveredID = hitID
            guard let header = document.hunkHeaders.first(where: { $0.id == hitID }),
                  let headerRect = headerRectInScroll(for: header) else {
                hideButtonStack()
                return
            }
            showButtons(headerRect: headerRect)
        }

        private func hideButtonStack() {
            buttonStack?.isHidden = true
        }

        @objc func stageClicked() {
            guard let hoveredID else { return }
            hunkActions?.onStage(hoveredID)
        }

        @objc func unstageClicked() {
            guard let hoveredID else { return }
            hunkActions?.onUnstage(hoveredID)
        }

        @objc func discardClicked() {
            guard let hoveredID else { return }
            hunkActions?.onDiscard(hoveredID)
        }

        private func hunkID(at pointInScroll: NSPoint) -> String? {
            if let buttonStack, !buttonStack.isHidden,
               let overlay,
               buttonStack.frame.contains(overlay.convert(pointInScroll, from: scrollView)) {
                return hoveredID
            }
            for header in document.hunkHeaders {
                guard let rect = headerRectInScroll(for: header) else { continue }
                if headerHitRect(for: rect).contains(pointInScroll) {
                    return header.id
                }
            }
            return nil
        }

        private func headerHitRect(for headerRect: NSRect) -> NSRect {
            NSRect(
                x: 0,
                y: headerRect.minY,
                width: scrollView?.bounds.width ?? headerRect.width,
                height: max(headerRect.height, Theme.codeLineHeight))
        }

        private func headerRectInScroll(for header: DiffHunkHeader) -> NSRect? {
            guard let textView,
                  let scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: header.range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            return textView.convert(rect, to: scrollView)
        }

        private func showButtons(headerRect: NSRect) {
            guard let overlay, let actions = hunkActions, let scrollView, let hoveredID else { return }
            let stack = buttonStack ?? makeButtonStack()
            if buttonStack == nil {
                overlay.addSubview(stack)
                buttonStack = stack
            }
            let identity = ButtonIdentity(
                hoveredID: hoveredID,
                showsStage: actions.showsStage,
                showsUnstage: actions.showsUnstage,
                showsDiscard: actions.showsDiscard,
                isEnabled: actions.isEnabled)
            if lastButtonIdentity != identity {
                rebuildButtons(in: stack, actions: actions)
                lastButtonIdentity = identity
            }
            stack.isHidden = false
            stack.layoutSubtreeIfNeeded()
            let size = stack.fittingSize
            let x = max(8, scrollView.bounds.width - size.width - 8)
            let y = headerRect.midY - size.height / 2
            stack.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        }

        private func makeButtonStack() -> NSStackView {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 4
            stack.edgeInsets = NSEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)
            stack.wantsLayer = true
            stack.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
            stack.layer?.cornerRadius = 4
            return stack
        }

        private func rebuildButtons(in stack: NSStackView, actions: HunkActions) {
            stack.arrangedSubviews.forEach { view in
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            if actions.showsStage {
                stack.addArrangedSubview(makeButton(title: "暂存此块", action: #selector(stageClicked)))
            }
            if actions.showsUnstage {
                stack.addArrangedSubview(makeButton(title: "取消暂存此块", action: #selector(unstageClicked)))
            }
            if actions.showsDiscard {
                stack.addArrangedSubview(makeButton(title: "丢弃此块", action: #selector(discardClicked)))
            }
            for case let button as NSButton in stack.arrangedSubviews {
                button.isEnabled = actions.isEnabled
            }
        }

        private func makeButton(title: String, action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            button.setButtonType(.momentaryPushIn)
            return button
        }
    }
}

/// 叠在 scroll view 上：只拦截按钮点击，其余事件穿透给 NSTextView。
private final class HunkOverlayView: NSView {
    weak var coordinator: DiffTextView.Coordinator?

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.mouseMoved(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.mouseExited()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for subview in subviews where !subview.isHidden && subview.frame.contains(local) {
            if let hit = subview.hitTest(local) {
                return hit
            }
        }
        return nil
    }
}
