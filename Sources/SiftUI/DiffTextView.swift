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
    var onSelectionChange: ((NSRange) -> Void)?
    var onExplain: ((String, String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        context.coordinator.install(in: container,
                                    document: document,
                                    hunkActions: hunkActions,
                                    onSelectionChange: onSelectionChange,
                                    onExplain: onExplain)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.install(in: container,
                                    document: document,
                                    hunkActions: hunkActions,
                                    onSelectionChange: onSelectionChange,
                                    onExplain: onExplain)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var document = DiffDocument(text: NSAttributedString(), hunkHeaders: [])
        var hunkActions: HunkActions?
        var onSelectionChange: ((NSRange) -> Void)?
        var onExplain: ((String, String) -> Void)?
        private weak var container: NSView?
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private weak var rightScrollView: NSScrollView?
        private weak var rightTextView: NSTextView?
        private var overlay: HunkOverlayView?
        private var buttonStack: NSStackView?
        private var explainButton: NSButton?
        private weak var selectionTextView: NSTextView?
        private var hoveredID: String?
        private var lastButtonIdentity: ButtonIdentity?
        private var isSplit = false
        private var isSyncing = false

        private struct ButtonIdentity: Equatable {
            var hoveredID: String
            var showsStage: Bool
            var showsUnstage: Bool
            var showsDiscard: Bool
            var isEnabled: Bool
        }

        func install(in container: NSView,
                     document: DiffDocument,
                     hunkActions: HunkActions?,
                     onSelectionChange: ((NSRange) -> Void)?,
                     onExplain: ((String, String) -> Void)?) {
            self.container = container
            self.document = document
            self.hunkActions = hunkActions
            self.onSelectionChange = onSelectionChange
            self.onExplain = onExplain
            let wantSplit = document.splitRight != nil
            if container.subviews.isEmpty || wantSplit != isSplit {
                rebuildHierarchy(split: wantSplit)
            }
            if let textView {
                replaceText(in: textView, with: document.text)
            }
            if let rightTextView, let right = document.splitRight {
                replaceText(in: rightTextView, with: right)
            }
            relayoutOverlay()
            updateExplainButton()
        }

        private func rebuildHierarchy(split: Bool) {
            NotificationCenter.default.removeObserver(self)
            container?.subviews.forEach { $0.removeFromSuperview() }
            overlay = nil
            buttonStack = nil
            explainButton = nil
            selectionTextView = nil
            hoveredID = nil
            lastButtonIdentity = nil
            scrollView = nil
            textView = nil
            rightScrollView = nil
            rightTextView = nil
            isSplit = split
            guard let container else { return }

            if split {
                let (leftScroll, leftText) = makeScrollView()
                let (rightScroll, rightText) = makeScrollView()
                scrollView = leftScroll
                textView = leftText
                rightScrollView = rightScroll
                rightTextView = rightText

                let splitView = NSSplitView()
                splitView.isVertical = true
                splitView.dividerStyle = .thin
                splitView.frame = container.bounds
                splitView.autoresizingMask = [.width, .height]
                splitView.addSubview(leftScroll)
                splitView.addSubview(rightScroll)
                container.addSubview(splitView)

                attachOverlay(to: leftScroll)
                observeScroll(leftScroll)
                observeScroll(rightScroll)
            } else {
                let (single, text) = makeScrollView()
                scrollView = single
                textView = text
                single.frame = container.bounds
                single.autoresizingMask = [.width, .height]
                container.addSubview(single)
                attachOverlay(to: single)
                observeScroll(single)
            }
        }

        private func makeScrollView() -> (NSScrollView, DiffCopyTextView) {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .textBackgroundColor

            let textView = DiffCopyTextView(frame: .zero)
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width]
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.allowsUndo = false
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            // 左边距和栏头标题对齐（Theme.horizontalPadding）。
            textView.textContainerInset = NSSize(width: 10, height: 6)
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.delegate = self
            // 不换行：宽度设为无限，靠横向滚动。
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)

            scrollView.documentView = textView
            return (scrollView, textView)
        }

        private func attachOverlay(to scrollView: NSScrollView) {
            let overlay = HunkOverlayView()
            overlay.autoresizingMask = [.width, .height]
            overlay.frame = scrollView.bounds
            overlay.coordinator = self
            scrollView.addSubview(overlay, positioned: .above, relativeTo: nil)
            self.overlay = overlay
        }

        private func observeScroll(_ scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipBoundsDidChange(_:)),
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

        private func replaceText(in textView: NSTextView, with text: NSAttributedString) {
            guard let storage = textView.textStorage else { return }
            if storage.string == text.string {
                if !storage.isEqual(to: text) {
                    // attribute-only：同一段字符、新属性（含语法高亮第三遍）。不 replaceCharacters，滚动不跳。
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
        }

        @objc private func clipBoundsDidChange(_ notification: Notification) {
            if !isSyncing {
                syncVerticalScroll(from: notification)
            }
            relayoutOverlay()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            selectionTextView = textView
            onSelectionChange?(textView.selectedRange())
            updateExplainButton()
        }

        private func syncVerticalScroll(from notification: Notification) {
            guard isSplit,
                  let clip = notification.object as? NSClipView,
                  let left = scrollView,
                  let right = rightScrollView else { return }
            isSyncing = true
            defer { isSyncing = false }
            let y = clip.documentVisibleRect.origin.y
            if clip === left.contentView {
                var origin = right.documentVisibleRect.origin
                origin.y = y
                right.contentView.scroll(to: origin)
                right.reflectScrolledClipView(right.contentView)
            } else if clip === right.contentView {
                var origin = left.documentVisibleRect.origin
                origin.y = y
                left.contentView.scroll(to: origin)
                left.reflectScrolledClipView(left.contentView)
            }
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
            updateExplainButton()
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

        @objc func explainClicked() {
            guard let textView = selectionTextView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            let selected = DiffDocumentBuilder.copyableString(from: storage, range: range)
            let surroundingRange = DiffDocumentBuilder.surroundingRange(
                of: range, in: storage.string)
            let surrounding = DiffDocumentBuilder.copyableString(from: storage, range: surroundingRange)
            onExplain?(selected, surrounding)
        }

        private func updateExplainButton() {
            guard let overlay,
                  let textView = selectionTextView ?? self.textView,
                  textView.selectedRange().length > 0,
                  let rect = selectionRectInOverlay(range: textView.selectedRange(), textView: textView)
            else {
                explainButton?.isHidden = true
                return
            }
            let button = explainButton ?? makeExplainButton()
            if explainButton == nil {
                overlay.addSubview(button)
                explainButton = button
            }
            button.isHidden = false
            button.sizeToFit()
            let size = button.fittingSize
            let padding: CGFloat = 4
            var x = min(rect.maxX + padding, overlay.bounds.width - size.width - 8)
            x = max(8, x)
            let y: CGFloat
            if overlay.isFlipped {
                y = min(rect.maxY + padding, max(8, overlay.bounds.height - size.height - 8))
            } else {
                y = max(8, rect.minY - size.height - padding)
            }
            button.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        }

        private func makeExplainButton() -> NSButton {
            let button = NSButton(title: "解释这段", target: self, action: #selector(explainClicked))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            button.setButtonType(.momentaryPushIn)
            return button
        }

        private func selectionRectInOverlay(range: NSRange, textView: NSTextView) -> NSRect? {
            guard let overlay,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            return overlay.convert(rect, from: textView)
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

/// 复制时丢掉 gutter 行号，保留 +/- 与正文。
private final class DiffCopyTextView: NSTextView {
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return false }
        let copied = DiffDocumentBuilder.copyableString(from: storage, range: selectedRange())
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(copied, forType: .string)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        writeSelection(to: pboard, type: .string)
    }
}
