import SwiftUI
import AppKit
import GitKit

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
    var onVisibleRangeChange: ((NSRange) -> Void)?
    var preserveVisibleRect: Bool = false
    var revealRange: NSRange? = nil
    var onDidReveal: (() -> Void)?
    var onExpandCollapsedFile: ((String) -> Void)?
    var hunkIsStaged: ((String) -> Bool?)?
    var showsBlame: Bool = false
    var blameByNewLine: [Int: BlameLine] = [:]
    var blameByFileID: [String: [Int: BlameLine]] = [:]
    var loadBlameCommit: ((BlameLine) async -> BlameCommitContent)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        context.coordinator.install(in: container,
                                    document: document,
                                    hunkActions: hunkActions,
                                    onSelectionChange: onSelectionChange,
                                    onExplain: onExplain,
                                    onVisibleRangeChange: onVisibleRangeChange,
                                    preserveVisibleRect: preserveVisibleRect,
                                    revealRange: revealRange,
                                    onDidReveal: onDidReveal,
                                    onExpandCollapsedFile: onExpandCollapsedFile,
                                    hunkIsStaged: hunkIsStaged,
                                    showsBlame: showsBlame,
                                    blameByNewLine: blameByNewLine,
                                    blameByFileID: blameByFileID,
                                    loadBlameCommit: loadBlameCommit)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.install(in: container,
                                    document: document,
                                    hunkActions: hunkActions,
                                    onSelectionChange: onSelectionChange,
                                    onExplain: onExplain,
                                    onVisibleRangeChange: onVisibleRangeChange,
                                    preserveVisibleRect: preserveVisibleRect,
                                    revealRange: revealRange,
                                    onDidReveal: onDidReveal,
                                    onExpandCollapsedFile: onExpandCollapsedFile,
                                    hunkIsStaged: hunkIsStaged,
                                    showsBlame: showsBlame,
                                    blameByNewLine: blameByNewLine,
                                    blameByFileID: blameByFileID,
                                    loadBlameCommit: loadBlameCommit)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var document = DiffDocument(text: NSAttributedString(), hunkHeaders: [])
        var hunkActions: HunkActions?
        var onSelectionChange: ((NSRange) -> Void)?
        var onExplain: ((String, String) -> Void)?
        var onVisibleRangeChange: ((NSRange) -> Void)?
        var preserveVisibleRect = false
        var revealRange: NSRange?
        var onDidReveal: (() -> Void)?
        var onExpandCollapsedFile: ((String) -> Void)?
        var hunkIsStaged: ((String) -> Bool?)?
        var showsBlame = false
        var blameByNewLine: [Int: BlameLine] = [:]
        var blameByFileID: [String: [Int: BlameLine]] = [:]
        var loadBlameCommit: ((BlameLine) async -> BlameCommitContent)?
        private weak var container: NSView?
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private weak var rightScrollView: NSScrollView?
        private weak var rightTextView: NSTextView?
        private var overlay: HunkOverlayView?
        private var blameOverlay: BlameOverlayView?
        private var buttonStack: NSStackView?
        private var explainButton: NSButton?
        private weak var selectionTextView: NSTextView?
        private var hoveredID: String?
        private var hoveredCollapsedID: String?
        private var lastButtonIdentity: ButtonIdentity?
        private var isSplit = false
        private var isSyncing = false
        private var lastRevealedRange: NSRange?
        private var blameHits: [(rect: NSRect, line: BlameLine)] = []
        private var blamePopover: NSPopover?
        private var blameDetailTask: Task<Void, Never>?
        private var lastBlameDocumentIdentity: String = ""

        var blameHitRects: [NSRect] { blameHits.map(\.rect) }

        private struct ButtonIdentity: Equatable {
            var hoveredID: String
            var showsStage: Bool
            var showsUnstage: Bool
            var showsDiscard: Bool
            var showsExpandCollapsed: Bool
            var isEnabled: Bool
        }

        func install(in container: NSView,
                     document: DiffDocument,
                     hunkActions: HunkActions?,
                     onSelectionChange: ((NSRange) -> Void)?,
                     onExplain: ((String, String) -> Void)?,
                     onVisibleRangeChange: ((NSRange) -> Void)?,
                     preserveVisibleRect: Bool,
                     revealRange: NSRange?,
                     onDidReveal: (() -> Void)?,
                     onExpandCollapsedFile: ((String) -> Void)?,
                     hunkIsStaged: ((String) -> Bool?)?,
                     showsBlame: Bool,
                     blameByNewLine: [Int: BlameLine],
                     blameByFileID: [String: [Int: BlameLine]],
                     loadBlameCommit: ((BlameLine) async -> BlameCommitContent)?) {
            self.container = container
            self.document = document
            self.hunkActions = hunkActions
            self.onSelectionChange = onSelectionChange
            self.onExplain = onExplain
            self.onVisibleRangeChange = onVisibleRangeChange
            self.preserveVisibleRect = preserveVisibleRect
            self.revealRange = revealRange
            self.onDidReveal = onDidReveal
            self.onExpandCollapsedFile = onExpandCollapsedFile
            self.hunkIsStaged = hunkIsStaged
            self.showsBlame = showsBlame
            self.blameByNewLine = blameByNewLine
            self.blameByFileID = blameByFileID
            self.loadBlameCommit = loadBlameCommit
            let identity = blameDocumentIdentity()
            if !showsBlame || identity != lastBlameDocumentIdentity {
                cancelBlameDetailTask()
                blamePopover?.performClose(nil)
            }
            lastBlameDocumentIdentity = identity
            let wantSplit = document.splitRight != nil
            if container.subviews.isEmpty || wantSplit != isSplit {
                rebuildHierarchy(split: wantSplit)
            }
            applyBlameInsets()
            let origin = scrollView?.documentVisibleRect.origin
            if let textView {
                replaceText(in: textView, with: document.text, preserveVisibleRect: preserveVisibleRect)
            }
            if let rightTextView, let right = document.splitRight {
                replaceText(in: rightTextView, with: right, preserveVisibleRect: preserveVisibleRect)
            }
            if let revealRange {
                if revealRange != lastRevealedRange, let textView {
                    textView.scrollRangeToVisible(revealRange)
                    lastRevealedRange = revealRange
                    onDidReveal?()
                }
            } else {
                lastRevealedRange = nil
                if preserveVisibleRect, let origin, let scrollView {
                    scrollView.contentView.scroll(to: origin)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
            relayoutOverlay()
            updateExplainButton()
            reportVisibleRange()
            DispatchQueue.main.async { [weak self] in
                self?.reportVisibleRange()
            }
        }

        private func rebuildHierarchy(split: Bool) {
            cancelBlameDetailTask()
            NotificationCenter.default.removeObserver(self)
            container?.subviews.forEach { $0.removeFromSuperview() }
            overlay = nil
            blameOverlay = nil
            buttonStack = nil
            explainButton = nil
            selectionTextView = nil
            hoveredID = nil
            hoveredCollapsedID = nil
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
                attachBlameOverlay(to: rightScroll)
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
                attachBlameOverlay(to: single)
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

        private func attachBlameOverlay(to scrollView: NSScrollView) {
            cancelBlameDetailTask()
            let overlay = BlameOverlayView()
            overlay.autoresizingMask = [.width, .height]
            overlay.frame = scrollView.bounds
            overlay.coordinator = self
            scrollView.addSubview(overlay, positioned: .above, relativeTo: nil)
            self.blameOverlay = overlay
        }

        private func applyBlameInsets() {
            let extra = showsBlame ? BlameGutterMetrics.columnWidth : 0
            let inset = NSSize(width: 10 + extra, height: 6)
            textView?.textContainerInset = inset
            rightTextView?.textContainerInset = inset
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

        private func replaceText(in textView: NSTextView,
                                 with text: NSAttributedString,
                                 preserveVisibleRect: Bool) {
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
                if !preserveVisibleRect {
                    textView.scroll(NSPoint(x: 0, y: 0))
                }
            }
        }

        @objc private func clipBoundsDidChange(_ notification: Notification) {
            if !isSyncing {
                syncVerticalScroll(from: notification)
            }
            relayoutOverlay()
            reportVisibleRange()
        }

        private func reportVisibleRange() {
            guard let onVisibleRangeChange,
                  let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let scrollView else { return }
            let visible = textView.convert(scrollView.documentVisibleRect, from: scrollView)
            var rect = visible
            rect.origin.x -= textView.textContainerOrigin.x
            rect.origin.y -= textView.textContainerOrigin.y
            let glyphRange = layoutManager.glyphRange(
                forBoundingRectWithoutAdditionalLayout: rect, in: textContainer)
            let charRange = layoutManager.characterRange(
                forGlyphRange: glyphRange, actualGlyphRange: nil)
            onVisibleRangeChange(charRange)
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
            blameDetailTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        private func cancelBlameDetailTask() {
            blameDetailTask?.cancel()
            blameDetailTask = nil
        }

        private func blameDocumentIdentity() -> String {
            let files = document.fileHeaders.map(\.id).joined(separator: ",")
            let hunks = document.hunkHeaders.map(\.id).joined(separator: ",")
            let ns = document.text.string as NSString
            let prefixLen = min(64, ns.length)
            let head = prefixLen == 0 ? "" : ns.substring(to: prefixLen)
            return "\(files)|\(hunks)|\(ns.length)|\(head)"
        }

        func mouseMoved(at pointInOverlay: NSPoint) {
            applyHover(at: pointInOverlay)
        }

        func mouseExited() {
            hoveredID = nil
            hoveredCollapsedID = nil
            hideButtonStack()
        }

        @objc func relayoutOverlay() {
            overlay?.frame = scrollView?.bounds ?? .zero
            if isSplit {
                blameOverlay?.frame = rightScrollView?.bounds ?? .zero
            } else {
                blameOverlay?.frame = scrollView?.bounds ?? .zero
            }
            rebuildBlameHits()
            updateExplainButton()
            if let hoveredCollapsedID,
               let header = document.fileHeaders.first(where: { $0.id == hoveredCollapsedID && $0.isCollapsed }),
               let headerRect = headerRectInScroll(for: header.range) {
                if mouseStillHits(headerRect) {
                    showCollapsedButton(headerRect: headerRect)
                    return
                }
                self.hoveredCollapsedID = nil
            }
            guard let hoveredID else {
                hideButtonStack()
                return
            }
            guard hunkActions != nil || hunkIsStaged != nil else {
                hideButtonStack()
                return
            }
            guard let header = document.hunkHeaders.first(where: { $0.id == hoveredID }),
                  let headerRect = headerRectInScroll(for: header.range) else {
                hideButtonStack()
                return
            }
            if !mouseStillHits(headerRect) {
                self.hoveredID = nil
                hideButtonStack()
                return
            }
            showButtons(headerRect: headerRect)
        }

        private func mouseStillHits(_ headerRect: NSRect) -> Bool {
            guard let overlay, let scrollView, let window = overlay.window else { return true }
            let pointInOverlay = overlay.convert(
                window.mouseLocationOutsideOfEventStream, from: nil)
            let pointInScroll = overlay.convert(pointInOverlay, to: scrollView)
            return headerHitRect(for: headerRect).contains(pointInScroll)
        }

        private func applyHover(at pointInOverlay: NSPoint) {
            guard let overlay, let scrollView else { return }
            let pointInScroll = overlay.convert(pointInOverlay, to: scrollView)
            if let collapsedID = collapsedFileID(at: pointInScroll),
               let header = document.fileHeaders.first(where: { $0.id == collapsedID }),
               let headerRect = headerRectInScroll(for: header.range) {
                hoveredID = nil
                hoveredCollapsedID = collapsedID
                showCollapsedButton(headerRect: headerRect)
                return
            }
            let hitID = hunkID(at: pointInScroll)
            hoveredCollapsedID = nil
            if hitID == nil {
                hoveredID = nil
                hideButtonStack()
                return
            }
            hoveredID = hitID
            guard let header = document.hunkHeaders.first(where: { $0.id == hitID }),
                  let headerRect = headerRectInScroll(for: header.range) else {
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

        @objc func expandCollapsedClicked() {
            guard let hoveredCollapsedID else { return }
            onExpandCollapsedFile?(hoveredCollapsedID)
        }

        private func collapsedFileID(at pointInScroll: NSPoint) -> String? {
            if let buttonStack, !buttonStack.isHidden,
               let overlay,
               buttonStack.frame.contains(overlay.convert(pointInScroll, from: scrollView)),
               hoveredCollapsedID != nil {
                return hoveredCollapsedID
            }
            for header in document.fileHeaders where header.isCollapsed {
                guard let rect = headerRectInScroll(for: header.range) else { continue }
                if headerHitRect(for: rect).contains(pointInScroll) {
                    return header.id
                }
            }
            return nil
        }

        private func hunkID(at pointInScroll: NSPoint) -> String? {
            if let buttonStack, !buttonStack.isHidden,
               let overlay,
               buttonStack.frame.contains(overlay.convert(pointInScroll, from: scrollView)) {
                return hoveredID
            }
            for header in document.hunkHeaders {
                guard let rect = headerRectInScroll(for: header.range) else { continue }
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

        private func headerRectInScroll(for range: NSRange) -> NSRect? {
            guard let textView,
                  let scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            return textView.convert(rect, to: scrollView)
        }

        private func resolvedHunkFlags(for id: String, actions: HunkActions) -> (stage: Bool, unstage: Bool, discard: Bool) {
            if let hunkIsStaged {
                switch hunkIsStaged(id) {
                case true: return (false, true, false)
                case false: return (true, false, true)
                case nil: return (false, false, false)
                }
            }
            return (actions.showsStage, actions.showsUnstage, actions.showsDiscard)
        }

        private func showCollapsedButton(headerRect: NSRect) {
            guard let overlay, let scrollView, let hoveredCollapsedID else { return }
            let stack = buttonStack ?? makeButtonStack()
            if buttonStack == nil {
                overlay.addSubview(stack)
                buttonStack = stack
            }
            let identity = ButtonIdentity(
                hoveredID: hoveredCollapsedID,
                showsStage: false,
                showsUnstage: false,
                showsDiscard: false,
                showsExpandCollapsed: true,
                isEnabled: true)
            if lastButtonIdentity != identity {
                rebuildCollapsedButton(in: stack)
                lastButtonIdentity = identity
            }
            place(stack, at: headerRect, in: scrollView)
        }

        private func showButtons(headerRect: NSRect) {
            guard let overlay, let scrollView, let hoveredID else { return }
            let actions = hunkActions ?? HunkActions(
                showsStage: false, showsUnstage: false, showsDiscard: false, isEnabled: false,
                onStage: { _ in }, onUnstage: { _ in }, onDiscard: { _ in })
            let flags = resolvedHunkFlags(for: hoveredID, actions: actions)
            guard flags.stage || flags.unstage || flags.discard else {
                hideButtonStack()
                return
            }
            let stack = buttonStack ?? makeButtonStack()
            if buttonStack == nil {
                overlay.addSubview(stack)
                buttonStack = stack
            }
            let identity = ButtonIdentity(
                hoveredID: hoveredID,
                showsStage: flags.stage,
                showsUnstage: flags.unstage,
                showsDiscard: flags.discard,
                showsExpandCollapsed: false,
                isEnabled: actions.isEnabled)
            if lastButtonIdentity != identity {
                let adjusted = HunkActions(
                    showsStage: flags.stage,
                    showsUnstage: flags.unstage,
                    showsDiscard: flags.discard,
                    isEnabled: actions.isEnabled,
                    onStage: actions.onStage,
                    onUnstage: actions.onUnstage,
                    onDiscard: actions.onDiscard)
                rebuildButtons(in: stack, actions: adjusted)
                lastButtonIdentity = identity
            }
            place(stack, at: headerRect, in: scrollView)
        }

        private func place(_ stack: NSStackView, at headerRect: NSRect, in scrollView: NSScrollView) {
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

        private func rebuildCollapsedButton(in stack: NSStackView) {
            stack.arrangedSubviews.forEach { view in
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            stack.addArrangedSubview(makeButton(title: "仍要查看", action: #selector(expandCollapsedClicked)))
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

        func blameHit(at pointInOverlay: NSPoint) -> BlameLine? {
            blameHits.first(where: { $0.rect.contains(pointInOverlay) })?.line
        }

        func drawBlame(in _: NSView) {
            guard showsBlame else { return }
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            for hit in blameHits {
                let name = String(hit.line.author.prefix(BlameGutterMetrics.maxAuthorChars)) as NSString
                let size = name.size(withAttributes: attrs)
                let y = hit.rect.midY - size.height / 2
                name.draw(at: NSPoint(x: hit.rect.minX + 2, y: y), withAttributes: attrs)
            }
        }

        func blameClicked(at pointInOverlay: NSPoint) {
            guard let hit = blameHits.first(where: { $0.rect.contains(pointInOverlay) }) else { return }
            blameDetailTask?.cancel()
            let line = hit.line
            let rect = hit.rect
            blameDetailTask = Task { [weak self] in
                let content: BlameCommitContent
                if let loader = self?.loadBlameCommit {
                    content = await loader(line)
                } else {
                    content = BlameCommitContent.fallback(for: line)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.showsBlame, !Task.isCancelled else { return }
                    self.showBlamePopover(content, relativeTo: rect)
                }
            }
        }

        private func rebuildBlameHits() {
            blameHits = []
            defer { blameOverlay?.needsDisplay = true }
            guard showsBlame, let overlay = blameOverlay else { return }
            let target = isSplit ? rightTextView : textView
            guard let target, let storage = target.textStorage else { return }
            let ns = storage.string as NSString
            var location = 0
            while location < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
                defer { location = NSMaxRange(lineRange) }
                guard let parsed = parseDiffBodyLine(storage, range: lineRange),
                      parsed.marker != "+",
                      parsed.marker != "-",
                      let newNumber = parsed.newLineNumber else { continue }
                guard let line = blameLine(newNumber: newNumber, at: lineRange.location) else { continue }
                guard let lineRect = lineRectInOverlay(for: lineRange, textView: target, overlay: overlay)
                else { continue }
                let column = NSRect(
                    x: lineRect.minX,
                    y: lineRect.minY,
                    width: BlameGutterMetrics.columnWidth,
                    height: max(lineRect.height, 1))
                blameHits.append((column, line))
            }
            if let overlay = blameOverlay, let window = overlay.window {
                window.invalidateCursorRects(for: overlay)
            }
        }

        private func blameLine(newNumber: Int, at location: Int) -> BlameLine? {
            if !blameByFileID.isEmpty, let fileID = fileID(containing: location) {
                return blameByFileID[fileID]?[newNumber]
            }
            return blameByNewLine[newNumber]
        }

        private func fileID(containing location: Int) -> String? {
            var current: String?
            for header in document.fileHeaders where header.range.location <= location {
                current = header.id
            }
            return current
        }

        private func parseDiffBodyLine(_ storage: NSAttributedString, range: NSRange) -> (marker: Character, newLineNumber: Int?)? {
            let ns = storage.string as NSString
            var gutter = ""
            var marker: Character?
            var isHeader = false
            storage.enumerateAttributes(in: range) { attrs, run, _ in
                let role = attrs[.siftRole] as? String
                if role == "header" {
                    isHeader = true
                } else if role == "gutter" {
                    gutter += ns.substring(with: run)
                } else if role == "code", marker == nil {
                    marker = ns.substring(with: run).first
                }
            }
            guard !isHeader, !gutter.isEmpty, let marker else { return nil }
            return (marker, DiffDocumentBuilder.newLineNumber(fromGutter: gutter))
        }

        private func lineRectInOverlay(for range: NSRange,
                                        textView: NSTextView,
                                        overlay: NSView) -> NSRect? {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x = 0
            rect.size.width = BlameGutterMetrics.columnWidth
            rect.origin.y += textView.textContainerOrigin.y
            return overlay.convert(rect, from: textView)
        }

        private func showBlamePopover(_ content: BlameCommitContent, relativeTo rect: NSRect) {
            guard showsBlame, let overlay = blameOverlay else { return }
            blamePopover?.performClose(nil)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 480, height: 380)
            popover.contentViewController = NSHostingController(
                rootView: BlamePopoverView(content: content))
            blamePopover = popover
            popover.show(relativeTo: rect, of: overlay, preferredEdge: .maxX)
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

/// 叠在 scroll view 左侧：blame 短名列，只拦截这一列的点击。
private final class BlameOverlayView: NSView {
    weak var coordinator: DiffTextView.Coordinator?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        coordinator?.drawBlame(in: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if coordinator?.blameHit(at: local) != nil {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.blameClicked(at: convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        discardCursorRects()
        guard let coordinator else { return }
        for hit in coordinator.blameHitRects {
            addCursorRect(hit, cursor: .pointingHand)
        }
    }
}

enum BlameGutterMetrics {
    static let maxAuthorChars = 8
    static var columnWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ceil(font.maximumAdvancement.width * CGFloat(maxAuthorChars)) + 8
    }
}

struct BlameCommitContent {
    let author: String
    let timeText: String
    let header: String
    let patch: String

    static func fallback(for line: BlameLine) -> BlameCommitContent {
        BlameCommitContent(
            author: line.author,
            timeText: BlameCommitContent.formatted(line.authorTime),
            header: line.summary,
            patch: "")
    }

    static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct BlamePopoverView: View {
    let content: BlameCommitContent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(content.author)
                    .font(.headline)
                Text(content.timeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !content.header.isEmpty {
                    Text(content.header)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                if !content.patch.isEmpty {
                    Divider()
                    Text(content.patch)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 480, height: 360)
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
